import AgentStudioGit
import CLibGit2Local
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// A plain checkout's attach can land a fast-forward or a new branch and still fail (its commit can report failure
/// after the ref moved, or a later step fails). The rollback undoes what landed; a fast-forward it cannot confirm
/// back at its expected tip fails the call with `branchMoveNotUndone`, and another writer's move is never overwritten.
@Suite("Git worktree create undo integration", .serialized)
struct GitWorktreeCreateUndoIntegrationTests {
    @Test("a fast-forward whose commit fails after the ref rename is moved back, and the call fails with nothing left")
    func fastForwardLandedDespiteCommitFailureIsMovedBack() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-fsync-moved")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let refusingSync = RefusingBranchDirectorySync(fixture)
        defer { refusingSync.restore() }
        let client = try refusingSync.client()

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }
        refusingSync.restore()

        // Assert: the reflog shows the fast-forward landed and was moved back; the call keeps its own error.
        #expect(failure == refusingSync.syncFailure)
        #expect(try revision("behind", in: fixture) == base)
        #expect(
            try fixture.git.run("reflog", "-2", "--format=%gs", "behind")
                == "agentstudio worktree: undo fast-forward to \(tip)\nagentstudio worktree: fast-forward to \(tip)\n")
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
        #expect(!(try fixture.git.run("for-each-ref", "refs/heads").contains("carrier")))
    }

    @Test("a new branch whose commit fails after the ref rename is removed, and the call fails with nothing left")
    func createdBranchLandedDespiteCommitFailureIsRemoved() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-fsync-created")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let refusingSync = RefusingBranchDirectorySync(fixture)
        defer { refusingSync.restore() }
        let client = try refusingSync.client()
        let referencesBefore = try fixture.git.run("for-each-ref")
        let configBefore = try fixture.git.run("config", "--local", "--list")

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(
                    fixture, "fresh",
                    .newBranch(
                        name: "fresh", startPoint: .named(base),
                        upstream: GitBranchUpstream(remoteName: "origin", branchName: "fresh"))))
        }
        refusingSync.restore()

        // Assert
        #expect(failure == refusingSync.syncFailure)
        #expect(try fixture.git.run("for-each-ref") == referencesBefore)
        #expect(try fixture.git.run("config", "--local", "--list") == configBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("fresh").path))
    }

    @Test("a failure after the attach commit with a confirmed undo keeps the call's own error and the branch at from")
    func failureAfterAttachWithConfirmedUndoKeepsItsOwnError() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-undo-confirmed")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let injected = GitDataPlaneError.unsupported(message: "injected after the attach")
        let client = client(at: .afterBranchAttached) { throw injected }

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }

        // Assert
        #expect(failure == injected)
        #expect(try revision("behind", in: fixture) == base)
        #expect(
            try fixture.git.run("reflog", "-2", "--format=%gs", "behind")
                == "agentstudio worktree: undo fast-forward to \(tip)\nagentstudio worktree: fast-forward to \(tip)\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
    }

    @Test("an undo that cannot take the branch's ref lock fails branchMoveNotUndone and leaves the branch where it is")
    func undoThatCannotLockFailsMoveNotUndone() async throws {
        // Arrange: another process holds the branch's ref lock when the rollback tries to undo the fast-forward.
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-undo-locked")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let heldLock = fixture.repositoryPath.appending(path: ".git/refs/heads/behind.lock")
        let client = client(at: .afterBranchAttached) {
            try Data("held by another process\n".utf8).write(to: heldLock)
            throw GitDataPlaneError.unsupported(message: "injected after the attach")
        }

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }
        try FileManager.default.removeItem(at: heldLock)

        // Assert
        #expect(failure == .branchMoveNotUndone(branchName: "behind", fromOID: base, toOID: tip))
        #expect(try revision("behind", in: fixture) == tip)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
    }

    @Test("an undo whose result cannot be read back fails branchMoveNotUndone")
    func undoThatCannotBeReadBackFailsMoveNotUndone() async throws {
        // Arrange: right after the undo commits, the branch's loose ref is overwritten with text that is not an
        // object identifier, so the re-read that would confirm the undo cannot parse it.
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-undo-unreadable")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let branchFile = fixture.repositoryPath.appending(path: ".git/refs/heads/behind")
        let unreadable = Data("not an object identifier\n".utf8)
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    switch point {
                    case .afterBranchAttached:
                        throw GitDataPlaneError.unsupported(message: "injected after the attach")
                    case .afterBranchMoveUndoCommitted:
                        try unreadable.write(to: branchFile)
                    case .beforeBranchAttach:
                        break
                    }
                }))

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }

        // Assert
        #expect(failure == .branchMoveNotUndone(branchName: "behind", fromOID: base, toOID: tip))
        #expect(try Data(contentsOf: branchFile) == unreadable)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
    }

    @Test("a fast-forward another writer moves before the undo fails branchMoveNotUndone and keeps that writer's tip")
    func fastForwardMovedAgainFailsMoveNotUndoneAndKeepsThatTip() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-move-not-undone")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let other = try commit("other.txt", in: fixture)
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let client = client(at: .afterBranchAttached) {
            try fixture.git.run("update-ref", "-m", "another writer", "refs/heads/behind", other)
            throw GitDataPlaneError.unsupported(message: "injected after the attach")
        }

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }

        // Assert
        #expect(failure == .branchMoveNotUndone(branchName: "behind", fromOID: base, toOID: tip))
        #expect(try revision("behind", in: fixture) == other)
        #expect(try fixture.git.run("reflog", "-1", "--format=%gs", "behind") == "another writer\n")
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
    }

    /// A characterization test of the contract at fcc3ad4: "confirmed" means this call's own undo was confirmed. When
    /// another writer sets the branch back to exactly `fromOID` before the undo, the undo writes nothing and the call
    /// still reports `branchMoveNotUndone`, so the caller learns another writer changed the branch during the call.
    @Test("a branch another writer sets back to from before the undo is still reported and keeps that writer's value")
    func branchSetBackToFromByAnotherWriterIsStillReported() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-undo-foreign-from")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let client = client(at: .afterBranchAttached) {
            try fixture.git.run("update-ref", "-m", "another writer", "refs/heads/behind", base)
            throw GitDataPlaneError.unsupported(message: "injected after the attach")
        }

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }

        // Assert: the branch holds the other writer's value, and the undo wrote no entry of its own.
        #expect(failure == .branchMoveNotUndone(branchName: "behind", fromOID: base, toOID: tip))
        #expect(try revision("behind", in: fixture) == base)
        #expect(try fixture.git.run("reflog", "-1", "--format=%gs", "behind") == "another writer\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").path))
    }

    private func client(
        at faultPoint: WorktreeCreateFaultPoint,
        _ action: @escaping @Sendable () throws -> Void
    ) -> LibGit2AgentStudioGitLocalClient {
        LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == faultPoint {
                        try action()
                    }
                }))
    }

    private func request(
        _ fixture: GitFixtureRepository,
        _ destinationName: String,
        _ mode: GitWorktreeCreateMode
    ) -> GitCreateWorktreeRequest {
        GitCreateWorktreeRequest(
            repositoryPath: fixture.repositoryPath,
            destinationPath: fixture.linkedWorktreePath(destinationName),
            mode: mode
        )
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

    private func failure(_ operation: () async throws -> Void) async -> GitDataPlaneError? {
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

/// Turns on ref fsync and, at the attach barrier, leaves `refs/heads` write-and-search only. A ref commit then
/// renames its lock into place, which still works, and fails opening the directory to sync it: libgit2 reports
/// the commit failed after the ref landed (`filebuf.c` rename, then `git_futils_fsync_parent`).
private struct RefusingBranchDirectorySync: Sendable {
    let branchDirectory: URL
    let repositoryPath: URL

    init(_ fixture: GitFixtureRepository) {
        branchDirectory = fixture.repositoryPath.appending(path: ".git/refs/heads")
        repositoryPath = fixture.repositoryPath
    }

    /// The commit error both the attach and the undo's own commit hit.
    var syncFailure: GitDataPlaneError {
        .libgit2Failure(
            code: -1, klass: Int32(GIT_ERROR_OS.rawValue),
            message:
                "failed to open directory '\(GitFixtureRepository.resolvedPath(branchDirectory))' for fsync: Permission denied"
        )
    }

    func client() throws -> LibGit2AgentStudioGitLocalClient {
        try GitProcess(repositoryPath: repositoryPath).run("config", "core.fsyncObjectFiles", "true")
        let branchDirectory = branchDirectory
        return LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == .beforeBranchAttach, chmod(branchDirectory.path, 0o300) != 0 {
                        throw GitDataPlaneError.unsupported(message: "the fixture could not restrict refs/heads")
                    }
                }))
    }

    func restore() {
        _ = chmod(branchDirectory.path, 0o755)
    }
}
