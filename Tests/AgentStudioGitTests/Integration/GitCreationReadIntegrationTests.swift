import AgentStudioGit
import Foundation
import Testing

@Suite("Git creation read integration", .serialized)
struct GitCreationReadIntegrationTests {
    @Test("ahead-behind answers equal, behind, ahead, diverged, and unrelated pairs")
    func aheadBehindAnswersEveryRelation() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ahead-behind")
        defer { fixture.remove() }
        let base = try commit("base.txt", in: fixture)
        let tip = try commit("tip.txt", in: fixture)
        try fixture.git.run("switch", "-q", "-c", "side", base)
        let side = try commit("side.txt", in: fixture)
        try fixture.git.run("switch", "-q", "--orphan", "island")
        let island = try commit("island.txt", in: fixture)
        let client = LibGit2AgentStudioGitLocalClient()
        let cases: [(local: String, other: String, expected: GitAheadBehind)] = [
            (tip, tip, GitAheadBehind(ahead: 0, behind: 0)),
            (base, tip, GitAheadBehind(ahead: 0, behind: 1)),
            (tip, base, GitAheadBehind(ahead: 1, behind: 0)),
            (side, tip, GitAheadBehind(ahead: 1, behind: 1)),
            // The island has one commit; the tip's history has the initial commit, base, and tip.
            (island, tip, GitAheadBehind(ahead: 1, behind: 3)),
        ]

        for relation in cases {
            // Act
            let result = try await client.aheadBehind(
                GitAheadBehindRequest(
                    repositoryPath: fixture.repositoryPath, localCommit: relation.local, otherCommit: relation.other))

            // Assert
            #expect(result == relation.expected, "\(relation.local) vs \(relation.other)")
        }
    }

    @Test("ahead-behind refuses abbreviations, unknown objects, and non-commits")
    func aheadBehindRefusesInvalidCommits() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ahead-behind-invalid")
        defer { fixture.remove() }
        let head = try revision("HEAD", in: fixture)
        let tree = try revision("HEAD^{tree}", in: fixture)
        let unknown = String(repeating: "a", count: 40)
        let client = LibGit2AgentStudioGitLocalClient()
        let cases: [(local: String, expected: GitDataPlaneError)] = [
            (String(head.prefix(12)), .unsupported(message: "localCommit must be a full object identifier")),
            // A SHA-256-length text whose first 40 digits name a commit must not be truncated to that commit.
            (
                head + String(repeating: "0", count: 24),
                .unsupported(message: "localCommit must be a full object identifier")
            ),
            (unknown, .requiredObjectNotFound(oid: unknown)),
            (tree, .unsupported(message: "localCommit does not name a commit")),
        ]

        for invalid in cases {
            // Act
            let failure = await dataPlaneFailure {
                _ = try await client.aheadBehind(
                    GitAheadBehindRequest(
                        repositoryPath: fixture.repositoryPath, localCommit: invalid.local, otherCommit: head))
            }

            // Assert
            #expect(failure == invalid.expected)
        }
    }

    @Test("remote names list every configured remote")
    func remoteNamesListEveryConfiguredRemote() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-remote-names")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let before = try await client.remoteNames(for: fixture.repositoryPath)
        try fixture.git.run("remote", "add", "origin", fixture.root.appending(path: "origin.git").path)
        try fixture.git.run("remote", "add", "upstream", fixture.root.appending(path: "upstream.git").path)
        let linked = try fixture.addLinkedWorktree(named: "linked", branch: "linked")

        // Act
        let fromMain = try await client.remoteNames(for: fixture.repositoryPath)
        let fromLinked = try await client.remoteNames(for: linked)

        // Assert
        #expect(before.isEmpty)
        #expect(fromMain.sorted() == ["origin", "upstream"])
        #expect(fromLinked.sorted() == ["origin", "upstream"])
    }

    @Test("branch use finds a branch by HEAD, rebase-merge, rebase-apply, and bisect, and reports a free one")
    func branchUseFindsEveryHoldingWorktree() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-branch-use")
        defer { fixture.remove() }
        try fixture.write("conflict.txt", contents: "base\n")
        try fixture.git.run("add", "conflict.txt")
        try fixture.git.run("commit", "-qm", "base")
        for branch in ["checked", "merging", "applying", "bisecting", "parked"] {
            try fixture.git.run("branch", branch)
        }
        try fixture.write("conflict.txt", contents: "main\n")
        try fixture.git.run("commit", "-qam", "main side")
        let checked = try fixture.addLinkedWorktree(named: "checked-worktree")
        try fixture.git.run(["switch", "-q", "checked"], currentDirectory: checked)
        let merging = try conflictedRebase(fixture, branch: "merging", backend: "--merge")
        let applying = try conflictedRebase(fixture, branch: "applying", backend: "--apply")
        let bisecting = try fixture.addLinkedWorktree(named: "bisecting-worktree")
        try fixture.git.run(["switch", "-q", "bisecting"], currentDirectory: bisecting)
        for index in 0..<3 {
            try fixture.write("bisect-\(index).txt", contents: "\(index)\n", in: bisecting)
            try fixture.git.run(["add", "."], currentDirectory: bisecting)
            try fixture.git.run(["commit", "-qm", "bisect \(index)"], currentDirectory: bisecting)
        }
        try fixture.git.run(["bisect", "start", "HEAD", "HEAD~3"], currentDirectory: bisecting)
        let client = LibGit2AgentStudioGitLocalClient()
        let cases: [(branch: String, expected: GitBranchUse)] = [
            ("main", .inUse(worktreePath: canonical(fixture.repositoryPath))),
            ("checked", .inUse(worktreePath: canonical(checked))),
            ("merging", .inUse(worktreePath: canonical(merging))),
            ("applying", .inUse(worktreePath: canonical(applying))),
            ("bisecting", .inUse(worktreePath: canonical(bisecting))),
            ("parked", .free),
            ("never-created", .free),
        ]

        for useCase in cases {
            // Act
            let fromMain = try await client.branchUse(
                GitBranchUseRequest(repositoryPath: fixture.repositoryPath, branchName: useCase.branch))
            let fromLinked = try await client.branchUse(
                GitBranchUseRequest(repositoryPath: checked, branchName: useCase.branch))

            // Assert
            #expect(fromMain == useCase.expected, "\(useCase.branch)")
            #expect(fromLinked == useCase.expected, "\(useCase.branch) from a linked worktree")
        }
        #expect(try fixture.git.run(["rev-parse", "--abbrev-ref", "HEAD"], currentDirectory: bisecting) == "HEAD\n")
    }

    @Test("branch use counts a registered worktree whose directory is gone and refuses invalid names")
    func branchUseCountsMissingWorktreeDirectories() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-branch-use-missing")
        defer { fixture.remove() }
        let gone = try fixture.addLinkedWorktree(named: "gone", branch: "gone-branch")
        let goneCanonical = canonical(gone)
        try FileManager.default.removeItem(at: gone)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let use = try await client.branchUse(
            GitBranchUseRequest(repositoryPath: fixture.repositoryPath, branchName: "gone-branch"))
        let invalid = await dataPlaneFailure {
            _ = try await client.branchUse(
                GitBranchUseRequest(repositoryPath: fixture.repositoryPath, branchName: "bad..name"))
        }

        // Assert
        #expect(use == .inUse(worktreePath: goneCanonical))
        #expect(invalid == .unsupported(message: "branch name is invalid"))
    }

    /// A linked worktree on `branch` stopped mid-rebase onto `main` by a conflict, with `HEAD` detached.
    private func conflictedRebase(
        _ fixture: GitFixtureRepository,
        branch: String,
        backend: String
    ) throws -> URL {
        let worktree = try fixture.addLinkedWorktree(named: "\(branch)-worktree")
        try fixture.git.run(["switch", "-q", branch], currentDirectory: worktree)
        try fixture.write("conflict.txt", contents: "\(branch)\n", in: worktree)
        try fixture.git.run(["commit", "-qam", "\(branch) side"], currentDirectory: worktree)
        let rebased = try fixture.git.succeeds("rebase", backend, "main", currentDirectory: worktree)
        #expect(!rebased, "the \(branch) rebase must stop on its conflict")
        return worktree
    }

    private func commit(_ file: String, in fixture: GitFixtureRepository) throws -> String {
        try fixture.write(file, contents: "\(file)\n")
        try fixture.git.run("add", file)
        try fixture.git.run("commit", "-qm", file)
        return try revision("HEAD", in: fixture)
    }

    private func revision(_ spec: String, in fixture: GitFixtureRepository) throws -> String {
        try fixture.git.run("rev-parse", spec).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonical(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let path = resolved.hasPrefix("/private/var/") ? String(resolved.dropFirst("/private".count)) : resolved
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private func dataPlaneFailure(_ operation: () async throws -> Void) async -> GitDataPlaneError? {
        do {
            try await operation()
            return nil
        } catch let error as GitDataPlaneError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }
}
