import AgentStudioGit
import CLibGit2Local
import Foundation
import Testing
import os

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
        let pushed = try fixture.git.succeeds(
            "-c", "push.default=simple", "push", currentDirectory: fixture.destination())

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

    @Test("a branch in HEAD's transaction bucket is checked out before its lock is released")
    func headLandsBeforeTheBranchLockIsReleased() async throws {
        // Arrange: libgit2 commits a ref transaction in hash-bucket order, and `refs/heads/release` shares HEAD's
        // bucket, so a two-ref transaction would unlock the branch before HEAD named it.
        #expect(Self.transactionBucket("refs/heads/release") == Self.transactionBucket("HEAD"))
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-head-first")
        defer { fixture.remove() }
        let head = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "release")
        let destination = fixture.destination()
        let observed = OSAllocatedUnfairLock(initialState: AttachObservation())
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            switch point {
            case .afterBranchHeadAttached:
                let headName = try? GitProcess(repositoryPath: destination).run("symbolic-ref", "HEAD")
                let use = try? LibGit2BranchUseReader().branchUse(
                    GitBranchUseRequest(repositoryPath: fixture.source, branchName: "release"))
                let lockHeld = GitWorktreeForkFileProbe.exists(
                    fixture.source.appending(path: ".git/refs/heads/release.lock"))
                observed.withLock {
                    $0.headWhileLocked = headName
                    $0.useWhileLocked = use
                    $0.branchLockHeld = lockHeld
                }
            case .afterBranchAttached:
                let refusal = Self.secondAttach(of: "release", at: head, from: fixture.source)
                observed.withLock { $0.secondAttach = refusal }
            default:
                return
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let result = try await client.forkWorktree(
            fixture.request(mode: .existingBranch(name: "release", expectedTip: head, fastForwardTo: nil)))

        // Assert
        let observation = observed.withLock { $0 }
        #expect(observation.branchLockHeld)
        #expect(observation.headWhileLocked == "refs/heads/release\n")
        #expect(observation.useWhileLocked == .inUse(worktreePath: destination))
        #expect(observation.secondAttach == .checkedOut(worktreePath: destination))
        #expect(result.worktree.head == GitHeadSnapshot(kind: .branch, oid: head, shortName: "release"))
        #expect(try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: fixture.source) == "refs/heads/main\n")
    }

    @Test("a created branch another writer moves before compensation keeps its ref, config, and reflog")
    func movedCreatedBranchSurvivesCompensation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-attach-moved-created")
        defer { fixture.remove() }
        let head = try fixture.blobID("HEAD", at: fixture.source)
        let elsewhere = try fixture.git.run("commit-tree", "-p", head, "-m", "elsewhere", "HEAD^{tree}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client(at: .afterBranchAttached) {
            try fixture.git.run("update-ref", "-m", "another writer", "refs/heads/feat", elsewhere)
            throw Self.injected
        }

        // Act
        let failure = await forkFailure(
            client,
            fixture.request(
                mode: .newBranch(
                    name: "feat", start: .sourceHead,
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "feat"))))

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: Self.injected,
                    residue: [GitWorktreeForkResidue(kind: .createdBranch, location: "refs/heads/feat")]
                ))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.blobID("feat", at: fixture.source) == elsewhere)
        #expect(try fixture.git.run("config", "branch.feat.remote") == "origin\n")
        #expect(try fixture.git.run("reflog", "-1", "--format=%gs", "feat") == "another writer\n")
    }

    /// libgit2's ref-transaction map: an x31 string hash over its four initial buckets (`util/hashmap_str.h`).
    private static func transactionBucket(_ name: String) -> UInt32 {
        var bytes = name.utf8.makeIterator()
        guard var hash = bytes.next().map(UInt32.init) else {
            return 0
        }
        while let byte = bytes.next() {
            hash = (hash &<< 5) &- hash &+ UInt32(byte)
        }
        return hash & 3
    }

    /// A second attach of the same branch from the source repository, as another process would run it.
    private static func secondAttach(of branch: String, at tip: String, from source: URL) -> LibGit2BranchAttachRefusal?
    {
        var repository: OpaquePointer?
        guard source.path.withCString({ git_repository_open_ext(&repository, $0, 0, nil) }) >= 0, let repository else {
            return .gitFailure(.repositoryNotFound(path: source))
        }
        defer { git_repository_free(repository) }
        do throws(LibGit2BranchAttachRefusal) {
            try LibGit2BranchAttach(
                request: LibGit2BranchAttachRequest(
                    repositoryPath: source,
                    transactionRepository: repository,
                    target: .existingBranch(referenceName: "refs/heads/\(branch)", expectedTip: tip, fastForwardTo: nil)
                ),
                lockObserver: .untracked
            ).run(refusal: { $0 }, checkpoint: { _ throws(LibGit2BranchAttachRefusal) in }, landed: { _ in })
            return nil
        } catch {
            return error
        }
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

private struct AttachObservation: Sendable {
    var branchLockHeld = false
    var headWhileLocked: String?
    var useWhileLocked: GitBranchUse?
    var secondAttach: LibGit2BranchAttachRefusal?
}
