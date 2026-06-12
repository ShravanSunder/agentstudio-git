import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("libgit2 repository session", .serialized)
struct LibGit2RepositorySessionTests {
    @Test("repository session exposes value paths without leaking repository pointer")
    func repositorySessionExposesValuePathsWithoutLeakingRepositoryPointer() throws {
        let fixture = try LibGit2RepositoryFixture.makeRepository()
        defer { fixture.remove() }
        let session = LibGit2RepositorySession()

        let paths = try session.repositoryPaths(at: fixture.repositoryPath)

        #expect(paths.gitDirectory.lastPathComponent == ".git")
        #expect(paths.workDirectory == fixture.repositoryPath.standardizedFileURL)
        #expect(paths.commonDirectory == paths.gitDirectory)
    }

    @Test("repository session exposes bare repository paths")
    func repositorySessionExposesBareRepositoryPaths() throws {
        let fixture = try LibGit2RepositoryFixture.makeBareRepository()
        defer { fixture.remove() }
        let session = LibGit2RepositorySession()

        let paths = try session.repositoryPaths(at: fixture.repositoryPath)

        #expect(paths.gitDirectory == fixture.repositoryPath.standardizedFileURL)
        #expect(paths.workDirectory == nil)
        #expect(paths.commonDirectory == fixture.repositoryPath.standardizedFileURL)
    }

    @Test("repository session maps open failure to typed libgit2 failure")
    func repositorySessionMapsOpenFailureToTypedLibGit2Failure() {
        let session = LibGit2RepositorySession()
        let missingPath = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-missing-\(UUID().uuidString)")

        do {
            _ = try session.repositoryPaths(at: missingPath)
            Issue.record("repository open unexpectedly succeeded")
        } catch let error as GitDataPlaneError {
            guard case .libgit2Failure(let code, let klass, let message) = error else {
                Issue.record("expected libgit2 failure, got \(error)")
                return
            }
            #expect(code < 0)
            #expect(klass >= 0)
            #expect(!message.isEmpty)
        } catch {
            Issue.record("expected GitDataPlaneError, got \(error)")
        }
    }

    @Test("repository session fails and frees repository when required path accessor is nil")
    func repositorySessionFailsAndFreesRepositoryWhenRequiredPathAccessorIsNil() throws {
        let fixture = try LibGit2RepositoryFixture.makeRepository()
        defer { fixture.remove() }
        let freeCounter = LockedCounter()
        let session = LibGit2RepositorySession(
            runtime: .shared,
            onRepositoryFreed: freeCounter.increment,
            pathAccessors: LibGit2RepositoryPathAccessors(
                gitDirectory: { _ in nil },
                workDirectory: { _ in nil },
                commonDirectory: { _ in nil }
            )
        )

        do {
            _ = try session.repositoryPaths(at: fixture.repositoryPath)
            Issue.record("repository paths unexpectedly succeeded")
        } catch let error as GitDataPlaneError {
            guard case .libgit2Failure(let code, let klass, let message) = error else {
                Issue.record("expected libgit2 failure, got \(error)")
                return
            }
            #expect(code == -1)
            #expect(klass == 0)
            #expect(message.contains("git directory"))
            #expect(freeCounter.value == 1)
        } catch {
            Issue.record("expected GitDataPlaneError, got \(error)")
        }
    }
}

private struct LibGit2RepositoryFixture {
    let root: URL
    let repositoryPath: URL

    static func makeRepository() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-libgit2-session-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        let fixture = Self(root: root, repositoryPath: repositoryPath)
        try fixture.git("init")
        return fixture
    }

    static func makeBareRepository() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-libgit2-session-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "repo.git")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        let fixture = Self(root: root, repositoryPath: repositoryPath)
        try fixture.git("init", "--bare")
        return fixture
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "git",
                "-c",
                "user.name=AgentStudio Test",
                "-c",
                "user.email=agentstudio@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "init.defaultBranch=main",
            ] + arguments
        process.currentDirectoryURL = repositoryPath
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_XDG": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]) { _, testValue in testValue }
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record("git \(arguments.joined(separator: " ")) failed: \(stderr)")
            throw LibGit2RepositoryFixtureError(message: stderr)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LibGit2RepositoryFixtureError: Error {
    let message: String
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
