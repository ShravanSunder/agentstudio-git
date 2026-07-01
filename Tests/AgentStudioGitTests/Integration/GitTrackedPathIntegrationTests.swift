import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git tracked path integration", .serialized)
struct GitTrackedPathIntegrationTests {
    @Test("tracked paths enumerate sorted stage-zero index entries")
    func trackedPathsEnumerateSortedStageZeroIndexEntries() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-basic")
        defer { fixture.remove() }
        try fixture.write("Sources/App.swift", contents: "app\n")
        try fixture.write("Sources/Nested/View.swift", contents: "view\n")
        try fixture.write("Sources2/App.swift", contents: "wrong boundary\n")
        try fixture.write("Tests/AppTests.swift", contents: "tests\n")
        try fixture.git.run(
            "add",
            "Sources/App.swift",
            "Sources/Nested/View.swift",
            "Sources2/App.swift",
            "Tests/AppTests.swift"
        )
        let client = LibGit2AgentStudioGitLocalClient()

        let snapshot = try await client.trackedPaths(
            for: fixture.repositoryPath,
            options: GitTrackedPathsOptions()
        )
        let scopedSnapshot = try await client.trackedPaths(
            for: fixture.repositoryPath,
            options: GitTrackedPathsOptions(scopePath: "Sources")
        )

        #expect(
            snapshot.entries.map(\.path) == [
                "README.md",
                "Sources/App.swift",
                "Sources/Nested/View.swift",
                "Sources2/App.swift",
                "Tests/AppTests.swift",
            ])
        #expect(snapshot.entries.allSatisfy { $0.kind == .file })
        #expect(snapshot.rawIndexEntryCount == 5)
        #expect(
            scopedSnapshot.entries.map(\.path) == [
                "Sources/App.swift",
                "Sources/Nested/View.swift",
            ])
        #expect(scopedSnapshot.rawIndexEntryCount == 5)
    }

    @Test("tracked paths reject absolute and escaping scopes")
    func trackedPathsRejectAbsoluteAndEscapingScopes() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-scope")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "/Sources")) {
            _ = try await client.trackedPaths(
                for: fixture.repositoryPath,
                options: GitTrackedPathsOptions(scopePath: "/Sources")
            )
        }
        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "Sources/../Secrets")) {
            _ = try await client.trackedPaths(
                for: fixture.repositoryPath,
                options: GitTrackedPathsOptions(scopePath: "Sources/../Secrets")
            )
        }
    }

    @Test("tracked paths normalize whole-tree and trailing-slash scopes")
    func trackedPathsNormalizeWholeTreeAndTrailingSlashScopes() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-scope-normalize")
        defer { fixture.remove() }
        try fixture.write("Sources/App.swift", contents: "app\n")
        try fixture.write("Sources/Nested/View.swift", contents: "view\n")
        try fixture.write("Sources2/App.swift", contents: "wrong boundary\n")
        try fixture.git.run(
            "add",
            "Sources/App.swift",
            "Sources/Nested/View.swift",
            "Sources2/App.swift"
        )
        let client = LibGit2AgentStudioGitLocalClient()

        let wholeTreePaths = try await trackedPaths(
            client: client,
            repositoryPath: fixture.repositoryPath,
            scopePath: nil
        )
        let emptyScopePaths = try await trackedPaths(
            client: client,
            repositoryPath: fixture.repositoryPath,
            scopePath: ""
        )
        let slashOnlyScopePaths = try await trackedPaths(
            client: client,
            repositoryPath: fixture.repositoryPath,
            scopePath: "///"
        )
        let trailingSlashScopePaths = try await trackedPaths(
            client: client,
            repositoryPath: fixture.repositoryPath,
            scopePath: "Sources/"
        )

        #expect(emptyScopePaths == wholeTreePaths)
        #expect(slashOnlyScopePaths == wholeTreePaths)
        #expect(
            trailingSlashScopePaths == [
                "Sources/App.swift",
                "Sources/Nested/View.swift",
            ])
    }

    @Test("tracked paths classify symlinks and submodules")
    func trackedPathsClassifySymlinksAndSubmodules() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-kinds")
        defer { fixture.remove() }
        let submoduleSourcePath = fixture.root.appending(path: "submodule-source")
        try makeSubmoduleSource(at: submoduleSourcePath)
        try fixture.write("target.txt", contents: "target\n")
        let linkPath = fixture.repositoryPath.appending(path: "current-target")
        try FileManager.default.createSymbolicLink(atPath: linkPath.path, withDestinationPath: "target.txt")
        try fixture.git.run("add", "target.txt", "current-target")
        try fixture.git.run(
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            submoduleSourcePath.path,
            "Vendor/Submodule"
        )
        let client = LibGit2AgentStudioGitLocalClient()

        let snapshot = try await client.trackedPaths(
            for: fixture.repositoryPath,
            options: GitTrackedPathsOptions()
        )
        let entriesByPath = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.path, $0.kind) })

        #expect(entriesByPath["current-target"] == .symlink)
        #expect(entriesByPath["target.txt"] == .file)
        #expect(entriesByPath["Vendor/Submodule"] == .submodule)
        #expect(entriesByPath[".gitmodules"] == .file)
    }

    @Test("tracked paths read linked worktree index instead of main index")
    func trackedPathsReadLinkedWorktreeIndexInsteadOfMainIndex() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-linked-index")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-index", branch: "feature/linked-index")
        let client = LibGit2AgentStudioGitLocalClient()
        let snapshots = try await client.worktrees(for: fixture.repositoryPath)
        let mainSnapshot = try #require(snapshots.first { $0.isMainWorktree })
        let linkedSnapshot = try #require(snapshots.first { samePath($0.canonicalPath, linkedPath) })
        try fixture.write("main-staged.txt", contents: "main staged\n")
        try fixture.git.run("add", "main-staged.txt")
        try fixture.write("linked-staged.txt", contents: "linked staged\n", in: linkedPath)
        try fixture.git.run("add", "linked-staged.txt", currentDirectory: linkedPath)
        let mainIndexBefore = try Data(contentsOf: mainSnapshot.indexPath)
        let linkedIndexBefore = try Data(contentsOf: linkedSnapshot.indexPath)
        let mainLockPath = mainSnapshot.indexPath.deletingLastPathComponent().appending(path: "index.lock")
        let linkedLockPath = linkedSnapshot.indexPath.deletingLastPathComponent().appending(path: "index.lock")
        try "main-lock-sentinel\n".write(to: mainLockPath, atomically: true, encoding: .utf8)
        try "linked-lock-sentinel\n".write(to: linkedLockPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: mainLockPath)
            try? FileManager.default.removeItem(at: linkedLockPath)
        }

        let mainTrackedPaths = try await client.trackedPaths(
            for: mainSnapshot.canonicalPath,
            options: GitTrackedPathsOptions()
        )
        let linkedTrackedPaths = try await client.trackedPaths(
            for: linkedSnapshot.canonicalPath,
            options: GitTrackedPathsOptions()
        )
        let mainIndexPath = try GitIndexPathResolver().indexPath(for: mainSnapshot.canonicalPath)
        let linkedIndexPath = try GitIndexPathResolver().indexPath(for: linkedSnapshot.canonicalPath)

        #expect(mainIndexPath == mainSnapshot.indexPath)
        #expect(linkedIndexPath == linkedSnapshot.indexPath)
        #expect(mainTrackedPaths.entries.map(\.path).contains("main-staged.txt"))
        #expect(!mainTrackedPaths.entries.map(\.path).contains("linked-staged.txt"))
        #expect(linkedTrackedPaths.entries.map(\.path).contains("linked-staged.txt"))
        #expect(!linkedTrackedPaths.entries.map(\.path).contains("main-staged.txt"))
        #expect(try Data(contentsOf: mainSnapshot.indexPath) == mainIndexBefore)
        #expect(try Data(contentsOf: linkedSnapshot.indexPath) == linkedIndexBefore)
        #expect(try String(contentsOf: mainLockPath, encoding: .utf8) == "main-lock-sentinel\n")
        #expect(try String(contentsOf: linkedLockPath, encoding: .utf8) == "linked-lock-sentinel\n")
    }

    @Test("tracked paths omit conflict stages while preserving raw index count")
    func trackedPathsOmitConflictStagesWhilePreservingRawIndexCount() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tracked-paths-conflict")
        defer { fixture.remove() }
        try fixture.write("conflict.txt", contents: "base\n")
        try fixture.git.run("add", "conflict.txt")
        try fixture.git.run("commit", "-m", "seed conflict file")
        try fixture.git.run("checkout", "-b", "conflict-side")
        try fixture.write("conflict.txt", contents: "side\n")
        try fixture.git.run("add", "conflict.txt")
        try fixture.git.run("commit", "-m", "side edit")
        try fixture.git.run("checkout", "main")
        try fixture.write("conflict.txt", contents: "main\n")
        try fixture.git.run("add", "conflict.txt")
        try fixture.git.run("commit", "-m", "main edit")
        #expect(try !fixture.git.succeeds("merge", "conflict-side"))
        let client = LibGit2AgentStudioGitLocalClient()

        let snapshot = try await client.trackedPaths(
            for: fixture.repositoryPath,
            options: GitTrackedPathsOptions()
        )

        #expect(!snapshot.entries.map(\.path).contains("conflict.txt"))
        #expect(snapshot.rawIndexEntryCount > snapshot.entries.count)
        #expect(snapshot.entries.map(\.path) == ["README.md"])
    }

    private func makeSubmoduleSource(at path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let git = GitProcess(repositoryPath: path)
        try git.run("init")
        try "submodule\n".write(to: path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try git.run("add", "README.md")
        try git.run("commit", "-m", "submodule seed")
    }

    private func samePath(_ first: URL, _ second: URL) -> Bool {
        normalizedPath(first) == normalizedPath(second)
    }

    private func trackedPaths(
        client: LibGit2AgentStudioGitLocalClient,
        repositoryPath: URL,
        scopePath: String?
    ) async throws -> [String] {
        let snapshot = try await client.trackedPaths(
            for: repositoryPath,
            options: GitTrackedPathsOptions(scopePath: scopePath)
        )
        return snapshot.entries.map(\.path)
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
