import AgentStudioGit
import Foundation
import Testing

@Suite("Git repository identity")
struct GitRepositoryIdentityTests {
    @Test("absolute and symlink paths resolve to the same repository identity")
    func absoluteAndSymlinkPathsResolveToSameRepositoryIdentity() throws {
        let fixture = try GitIdentityFixture.makeRepository()
        defer { fixture.remove() }
        let symlinkPath = fixture.root.appending(path: "repo-link")
        try FileManager.default.createSymbolicLink(
            at: symlinkPath,
            withDestinationURL: fixture.repositoryPath
        )
        let resolver = GitRepositoryIdentityResolver()

        let directIdentity = try resolver.identity(for: fixture.repositoryPath)
        let symlinkIdentity = try resolver.identity(for: symlinkPath)

        #expect(directIdentity == symlinkIdentity)
    }

    @Test("main and linked worktrees share a common git directory")
    func mainAndLinkedWorktreesShareCommonGitDirectory() throws {
        let fixture = try GitIdentityFixture.makeRepository()
        defer { fixture.remove() }
        let linkedPath = fixture.root.appending(path: "linked")
        try fixture.git("worktree", "add", "-b", "feature/linked", linkedPath.path)
        let resolver = GitRepositoryIdentityResolver()

        let mainSnapshot = try resolver.worktreeSnapshot(for: fixture.repositoryPath)
        let linkedSnapshot = try resolver.worktreeSnapshot(for: linkedPath)

        #expect(mainSnapshot.repositoryID == linkedSnapshot.repositoryID)
        #expect(mainSnapshot.isMainWorktree)
        #expect(!linkedSnapshot.isMainWorktree)
        #expect(mainSnapshot.gitDirectory == mainSnapshot.indexPath.deletingLastPathComponent())
        #expect(linkedSnapshot.gitDirectory.path.contains(".git/worktrees"))
        #expect(linkedSnapshot.indexPath == linkedSnapshot.gitDirectory.appending(path: "index"))
    }

    @Test("synthetic main display name does not define worktree identity")
    func syntheticMainDisplayNameDoesNotDefineWorktreeIdentity() throws {
        let fixture = try GitIdentityFixture.makeRepository()
        defer { fixture.remove() }
        let linkedPath = fixture.root.appending(path: "main")
        try fixture.git("worktree", "add", "-b", "feature/main-name", linkedPath.path)
        let resolver = GitRepositoryIdentityResolver()

        let mainSnapshot = try resolver.worktreeSnapshot(for: fixture.repositoryPath)
        let linkedSnapshot = try resolver.worktreeSnapshot(for: linkedPath)

        #expect(mainSnapshot.displayName == "main")
        #expect(linkedSnapshot.displayName == "main")
        #expect(mainSnapshot.id != linkedSnapshot.id)
        #expect(mainSnapshot.canonicalPath != linkedSnapshot.canonicalPath)
    }
}

private struct GitIdentityFixture {
    let root: URL
    let repositoryPath: URL

    static func makeRepository() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-identity-\(UUID().uuidString)")
        let repositoryPath = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        let fixture = Self(root: root, repositoryPath: repositoryPath)
        try fixture.git("init")
        try "hello\n".write(to: repositoryPath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try fixture.git("add", "README.md")
        try fixture.git("commit", "-m", "initial")
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
            throw GitIdentityFixtureError(message: stderr)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct GitIdentityFixtureError: Error {
    let message: String
}
