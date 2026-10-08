import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree fork attach integration", .serialized)
struct GitWorktreeForkAttachIntegrationTests {
    private static let injected = GitWorktreeForkError.entryFailed(
        relativePath: "injected", reason: .entryCreationFailed, errorNumber: nil)

    @Test("an existing branch another worktree checks out at the barrier is refused and the fork rolled back")
    func existingBranchTakenAtBarrierIsRefused() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-race-existing")
        defer { fixture.remove() }
        let head = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "feat")
        let rival = fixture.destination("rival")
        let client = client(at: .beforeBranchAttach) {
            try fixture.git.run("worktree", "add", "-q", rival.path, "feat")
        }

        // Act
        let failure = await forkFailure(
            client, fixture.request(mode: .existingBranch(name: "feat", expectedTip: head, fastForwardTo: nil)))

        // Assert
        #expect(failure == .branchCheckedOut(worktreePath: rival))
        try expectRolledBack(fixture)
        #expect(try fixture.blobID("feat", at: fixture.source) == head)
        #expect(try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: rival) == "refs/heads/feat\n")
    }

    @Test("a new branch another worktree creates and checks out at the barrier is refused and left alone")
    func newBranchTakenAtBarrierIsRefused() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-race-new")
        defer { fixture.remove() }
        let head = try fixture.blobID("HEAD", at: fixture.source)
        let rival = fixture.destination("rival")
        let client = client(at: .beforeBranchAttach) {
            try fixture.git.run("worktree", "add", "-q", "-b", "feat", rival.path)
        }

        // Act
        let failure = await forkFailure(
            client, fixture.request(mode: .newBranch(name: "feat", start: .sourceHead, upstream: nil)))

        // Assert
        #expect(failure == .branchCheckedOut(worktreePath: rival))
        try expectRolledBack(fixture)
        #expect(try fixture.blobID("feat", at: fixture.source) == head)
        #expect(try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: rival) == "refs/heads/feat\n")
    }

    @Test("an existing branch whose tip moves at the barrier is refused branchMoved with the move kept")
    func movedTipAtBarrierIsRefused() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-moved")
        defer { fixture.remove() }
        let base = try fixture.blobID("HEAD", at: fixture.source)
        let head = try commit("second.txt", in: fixture)
        try fixture.git.run("branch", "feat")
        let client = client(at: .beforeBranchAttach) {
            try fixture.git.run("update-ref", "refs/heads/feat", base)
        }

        // Act
        let failure = await forkFailure(
            client, fixture.request(mode: .existingBranch(name: "feat", expectedTip: head, fastForwardTo: nil)))

        // Assert
        #expect(failure == .rejected(reason: .branchMoved))
        try expectRolledBack(fixture)
        #expect(try fixture.blobID("feat", at: fixture.source) == base)
    }

    @Test("a strictly behind branch is fast-forwarded to the captured HEAD and the snapshot reports it")
    func strictlyBehindBranchIsFastForwarded() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-fast-forward")
        defer { fixture.remove() }
        let base = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "feat")
        let head = try commit("second.txt", in: fixture)
        try fixture.write("dirty.txt", "work in progress\n")

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(mode: .existingBranch(name: "feat", expectedTip: base, fastForwardTo: head)))

        // Assert
        let destination = fixture.destination()
        #expect(try fixture.blobID("feat", at: fixture.source) == head)
        #expect(try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: destination) == "refs/heads/feat\n")
        #expect(result.worktree.head == GitHeadSnapshot(kind: .branch, oid: head, shortName: "feat"))
        #expect(try fixture.statusLines(at: destination) == ["?? dirty.txt"])
        #expect(try fixture.git.run("reflog", "-1", "--format=%gs", "feat").contains("fast-forward"))
    }

    @Test(
        "a fast-forward is undone when a later phase fails",
        arguments: [WorktreeForkFaultPoint.afterBranchAttached, .afterAttachValidation]
    )
    func fastForwardIsUndoneAfterLaterFailure(point: WorktreeForkFaultPoint) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-undo")
        defer { fixture.remove() }
        let base = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "feat")
        let head = try commit("second.txt", in: fixture)
        let client = client(at: point) { throw Self.injected }

        // Act
        let failure = await forkFailure(
            client, fixture.request(mode: .existingBranch(name: "feat", expectedTip: base, fastForwardTo: head)))

        // Assert
        #expect(failure == Self.injected)
        try expectRolledBack(fixture)
        #expect(try fixture.blobID("feat", at: fixture.source) == base)
    }

    @Test("an undo that finds the branch moved again leaves it and reports branchMoveNotUndone")
    func failedUndoIsReportedAsResidue() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-undo-blocked")
        defer { fixture.remove() }
        let base = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "feat")
        let head = try commit("second.txt", in: fixture)
        let elsewhere = try fixture.git.run("commit-tree", "-p", head, "-m", "elsewhere", "HEAD^{tree}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client(at: .afterBranchAttached) {
            try fixture.git.run("update-ref", "refs/heads/feat", elsewhere)
            throw Self.injected
        }

        // Act
        let failure = await forkFailure(
            client, fixture.request(mode: .existingBranch(name: "feat", expectedTip: base, fastForwardTo: head)))

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: Self.injected,
                    residue: [GitWorktreeForkResidue(kind: .branchMoveNotUndone, location: "refs/heads/feat")]
                ))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.blobID("feat", at: fixture.source) == elsewhere)
    }

    @Test("a new branch with an upstream tracks it, so push.default=simple pushes it")
    func upstreamIsWrittenForNewBranch() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-upstream")
        defer { fixture.remove() }
        let origin = fixture.repository.root.appending(path: "origin.git")
        try fixture.git.run("init", "-q", "--bare", origin.path)
        try fixture.git.run("remote", "add", "origin", origin.path)
        let head = try fixture.blobID("HEAD", at: fixture.source)

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                mode: .newBranch(
                    name: "feat", start: .sourceHead,
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "feat"))))
        let pushed = try fixture.git.succeeds("-c", "push.default=simple", "push", currentDirectory: fixture.destination())

        // Assert
        #expect(try fixture.git.run("config", "branch.feat.remote") == "origin\n")
        #expect(try fixture.git.run("config", "branch.feat.merge") == "refs/heads/feat\n")
        #expect(pushed)
        #expect(try fixture.git.run(["rev-parse", "refs/heads/feat"], currentDirectory: origin) == "\(head)\n")
    }

    @Test("a failure after the attach deletes the created branch together with its upstream")
    func failureAfterAttachRemovesBranchAndUpstream() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-upstream-rollback")
        defer { fixture.remove() }
        let client = client(at: .afterBranchAttached) { throw Self.injected }

        // Act
        let failure = await forkFailure(
            client,
            fixture.request(
                mode: .newBranch(
                    name: "feat", start: .sourceHead,
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "feat"))))

        // Assert
        #expect(failure == Self.injected)
        try expectRolledBack(fixture)
        #expect(try fixture.branchNames() == ["refs/heads/main"])
        #expect(!(try fixture.git.succeeds("config", "--get-regexp", "^branch\\.")))
    }

    private func client(
        at point: WorktreeForkFaultPoint,
        _ action: @escaping @Sendable () throws -> Void
    ) -> LibGit2AgentStudioGitLocalClient {
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            guard reached == point else {
                return
            }
            do {
                try action()
            } catch let error as GitWorktreeForkError {
                throw error
            } catch {
                throw .entryFailed(relativePath: "fixture action", reason: .entryCreationFailed, errorNumber: nil)
            }
        }
        return LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
    }

    private func expectRolledBack(_ fixture: GitWorktreeForkFixture) throws {
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(!(try fixture.git.run("worktree", "list", "--porcelain").contains(fixture.destination().path)))
        #expect(!(try fixture.branchNames().contains { $0.contains("agentstudio-fork-carrier") }))
    }

    private func commit(_ file: String, in fixture: GitWorktreeForkFixture) throws -> String {
        try fixture.write(file, "\(file)\n")
        try fixture.git.run("add", file)
        try fixture.git.run("commit", "-qm", file)
        return try fixture.blobID("HEAD", at: fixture.source)
    }

    private func forkFailure(
        _ client: LibGit2AgentStudioGitLocalClient,
        _ request: GitForkWorktreeRequest
    ) async -> GitWorktreeForkError? {
        do {
            _ = try await client.forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
