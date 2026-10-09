import AgentStudioGit
import CLibGit2Local
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

/// The plain checkout (`new --no-fork`) takes the fork's branch shapes: a pinned existing tip, a fast-forward
/// when strictly behind, a new branch at a pinned commit with an optional upstream, or a detached commit.
@Suite("Git worktree create branch integration", .serialized)
struct GitWorktreeCreateBranchIntegrationTests {
    @Test("an existing branch strictly behind is fast-forwarded and checked out; one at its tip is checked out as is")
    func existingBranchIsFastForwardedOrCheckedOut() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-existing")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        try fixture.git.run("branch", "parked")
        let tip = try commit("tip.txt", in: fixture)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let fastForwarded = try await client.createWorktree(
            request(fixture, "behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        let parked = try await client.createWorktree(
            request(fixture, "parked", .existingBranch(name: "parked", expectedTip: base, fastForwardTo: nil)))

        // Assert
        #expect(fastForwarded.worktree.head == GitHeadSnapshot(kind: .branch, oid: tip, shortName: "behind"))
        #expect(try revision("behind", in: fixture) == tip)
        #expect(
            FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("behind").appending(path: "tip.txt").path)
        )
        #expect(parked.worktree.head == GitHeadSnapshot(kind: .branch, oid: base, shortName: "parked"))
        #expect(try revision("parked", in: fixture) == base)
        #expect(try status(fixture.linkedWorktreePath("behind")).isEmpty)
    }

    @Test("a moved tip refuses branchMoved and a branch held elsewhere refuses branchCheckedOut, with nothing made")
    func movedOrHeldBranchesAreRefused() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-refused")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "moved")
        try fixture.git.run("branch", "held")
        let tip = try commit("tip.txt", in: fixture)
        try fixture.git.run("branch", "-f", "moved", tip)
        let holder = fixture.linkedWorktreePath("holder")
        try fixture.git.run("worktree", "add", "-q", holder.path, "held")
        let client = LibGit2AgentStudioGitLocalClient()
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")

        // Act
        let moved = await failure {
            _ = try await client.createWorktree(
                request(fixture, "moved", .existingBranch(name: "moved", expectedTip: base, fastForwardTo: nil)))
        }
        let held = await failure {
            _ = try await client.createWorktree(
                request(fixture, "held", .existingBranch(name: "held", expectedTip: base, fastForwardTo: nil)))
        }
        let notDescendant = await failure {
            _ = try await client.createWorktree(
                request(fixture, "back", .existingBranch(name: "moved", expectedTip: tip, fastForwardTo: base)))
        }

        // Assert
        #expect(moved == .branchMoved)
        #expect(held == .branchCheckedOut(worktreePath: holder))
        #expect(notDescendant == .unsupported(message: "fastForwardTo must descend from expectedTip"))
        #expect(try revision("moved", in: fixture) == tip)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        for name in ["moved", "held", "back"] {
            #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath(name).path))
        }
    }

    @Test("a failure right before the attach leaves every branch tip unchanged and no worktree behind")
    func failureBeforeAttachMovesNothing() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-before-attach")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let injected = GitDataPlaneError.unsupported(message: "injected before the attach")
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == .beforeBranchAttach {
                        throw injected
                    }
                }))
        let branchesBefore = try fixture.git.run("for-each-ref", "refs/heads")
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let modes: [(destination: String, mode: GitWorktreeCreateMode)] = [
            ("behind", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)),
            (
                "fresh",
                .newBranch(
                    name: "fresh", startPoint: .named(base),
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "fresh"))
            ),
            ("detached", .detached(startPoint: .named(base))),
        ]

        for (destination, mode) in modes {
            // Act
            let failure = await failure {
                _ = try await client.createWorktree(request(fixture, destination, mode))
            }

            // Assert
            #expect(failure == injected, "\(destination)")
            #expect(try fixture.git.run("for-each-ref", "refs/heads") == branchesBefore, "\(destination)")
            #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore, "\(destination)")
            #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath(destination).path))
            #expect(!(try fixture.git.succeeds("config", "--get-regexp", "^branch\\.")), "\(destination)")
        }
    }

    @Test("a checkout failure moves nothing")
    func checkoutFailureMovesNothing() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-occupied")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "behind")
        let tip = try commit("tip.txt", in: fixture)
        let occupied = fixture.linkedWorktreePath("occupied")
        try fixture.write("owner.txt", contents: "someone else's directory\n", in: occupied)
        let branchesBefore = try fixture.git.run("for-each-ref", "refs/heads")

        // Act
        let failure = await failure {
            _ = try await LibGit2AgentStudioGitLocalClient().createWorktree(
                request(fixture, "occupied", .existingBranch(name: "behind", expectedTip: base, fastForwardTo: tip)))
        }

        // Assert
        #expect(failure != nil)
        #expect(try revision("behind", in: fixture) == base)
        #expect(try fixture.git.run("for-each-ref", "refs/heads") == branchesBefore)
        #expect(
            try String(contentsOf: occupied.appending(path: "owner.txt"), encoding: .utf8)
                == "someone else's directory\n")
    }

    @Test("a failed upstream write removes the new branch and the worktree, and nothing else changes")
    func failedUpstreamWriteRemovesNewBranchAndWorktree() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-upstream-failure")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "parked")
        _ = try commit("tip.txt", in: fixture)
        let injected = GitDataPlaneError.unsupported(message: "injected upstream write failure")
        let reached = OSAllocatedUnfairLock(initialState: false)
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == .afterBranchAttached {
                        reached.withLock { $0 = true }
                        throw injected
                    }
                }))
        let referencesBefore = try fixture.git.run("for-each-ref")
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
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

        // Assert
        #expect(reached.withLock { $0 })
        #expect(failure == injected)
        #expect(try fixture.git.run("for-each-ref") == referencesBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(try fixture.git.run("config", "--local", "--list") == configBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("fresh").path))
    }

    @Test("a branch another worktree takes at the barrier refuses branchCheckedOut with nothing left behind")
    func branchTakenAtBarrierIsRefused() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-barrier")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        try fixture.git.run("branch", "parked")
        let rival = fixture.linkedWorktreePath("rival")
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == .beforeBranchAttach {
                        try fixture.git.run("worktree", "add", "-q", rival.path, "parked")
                    }
                }))

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(
                    fixture, "parked-checkout", .existingBranch(name: "parked", expectedTip: base, fastForwardTo: nil)))
        }

        // Assert
        #expect(failure == .branchCheckedOut(worktreePath: rival))
        #expect(try revision("parked", in: fixture) == base)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("parked-checkout").path))
        #expect(!(try fixture.git.run("worktree", "list", "--porcelain").contains("parked-checkout")))
        #expect(try GitProcess(repositoryPath: rival).run("symbolic-ref", "HEAD") == "refs/heads/parked\n")
        #expect(!(try fixture.git.run("for-each-ref", "refs/heads").contains("carrier")))
    }

    @Test("a new branch another writer moves before compensation keeps its ref, config, and reflog")
    func movedCreatedBranchSurvivesRollback() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-moved-created")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        let tip = try commit("tip.txt", in: fixture)
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeWriter: LibGit2WorktreeWriter(
                createFaults: WorktreeCreateFaultInjector { point in
                    if point == .afterBranchAttached {
                        try fixture.git.run("update-ref", "-m", "another writer", "refs/heads/fresh", tip)
                        try fixture.git.run("config", "branch.fresh.description", "kept by another writer")
                        throw GitDataPlaneError.unsupported(message: "injected upstream write failure")
                    }
                }))

        // Act
        let failure = await failure {
            _ = try await client.createWorktree(
                request(
                    fixture, "fresh",
                    .newBranch(
                        name: "fresh", startPoint: .named(base),
                        upstream: GitBranchUpstream(remoteName: "origin", branchName: "fresh"))))
        }

        // Assert
        #expect(failure == .unsupported(message: "injected upstream write failure"))
        #expect(try revision("fresh", in: fixture) == tip)
        #expect(try fixture.git.run("config", "branch.fresh.description") == "kept by another writer\n")
        #expect(try fixture.git.run("reflog", "-1", "--format=%gs", "fresh") == "another writer\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("fresh").path))
    }

    @Test("a branch whose rebase state cannot be searched fails the create with nothing made and nothing moved")
    func unsearchableRebaseStateFailsCreate() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-unsearchable-rebase")
        defer { fixture.remove() }
        let rebasing = try fixture.addWorktreeStoppedInRebase(branch: "merging")
        defer { _ = chmod(rebasing.rebaseState.path, 0o755) }
        let mergingTip = try revision("merging", in: fixture)
        let referencesBefore = try fixture.git.run("for-each-ref")
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        #expect(chmod(rebasing.rebaseState.path, 0o600) == 0)

        // Act
        let failure = await failure {
            _ = try await LibGit2AgentStudioGitLocalClient().createWorktree(
                request(
                    fixture, "merging-checkout",
                    .existingBranch(name: "merging", expectedTip: mergingTip, fastForwardTo: nil)))
        }
        _ = chmod(rebasing.rebaseState.path, 0o755)

        // Assert
        #expect(failure == .unsupported(message: "worktree administration is unreadable"))
        #expect(try fixture.git.run("for-each-ref") == referencesBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("merging-checkout").path))
    }

    @Test("an invalid upstream remote or branch, or one with a NUL, fails before anything is made; a valid one works")
    func invalidUpstreamFailsBeforeAnythingIsMade() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-invalid-upstream")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        let client = LibGit2AgentStudioGitLocalClient()
        let referencesBefore = try fixture.git.run("for-each-ref")
        let configBefore = try fixture.git.run("config", "--local", "--list")
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let invalidUpstreams = [
            GitBranchUpstream(remoteName: "bad remote", branchName: "fresh"),
            GitBranchUpstream(remoteName: "origin", branchName: "bad..branch"),
            GitBranchUpstream(remoteName: "origin\u{0}x", branchName: "fresh"),
            GitBranchUpstream(remoteName: "origin", branchName: "fresh\u{0}x"),
        ]

        for upstream in invalidUpstreams {
            // Act
            let failure = await failure {
                _ = try await client.createWorktree(
                    request(fixture, "fresh", .newBranch(name: "fresh", startPoint: .named(base), upstream: upstream)))
            }

            // Assert
            #expect(
                failure
                    == .libgit2Failure(
                        code: GIT_EINVALIDSPEC.rawValue, klass: 0,
                        message: "'\(upstream.remoteName)/\(upstream.branchName)' is not a valid upstream"),
                "\(upstream)")
            #expect(try fixture.git.run("for-each-ref") == referencesBefore, "\(upstream)")
            #expect(try fixture.git.run("config", "--local", "--list") == configBefore, "\(upstream)")
            #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore, "\(upstream)")
            #expect(!FileManager.default.fileExists(atPath: fixture.linkedWorktreePath("fresh").path))
        }
        let valid = try await client.createWorktree(
            request(
                fixture, "fresh",
                .newBranch(
                    name: "fresh", startPoint: .named(base),
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "fresh"))))
        #expect(valid.worktree.head == GitHeadSnapshot(kind: .branch, oid: base, shortName: "fresh"))
        #expect(try fixture.git.run("config", "branch.fresh.merge") == "refs/heads/fresh\n")
    }

    @Test("a new branch at a pinned commit writes its upstream; a detached checkout sits at its commit")
    func newBranchWithUpstreamAndDetachedCommit() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-create-new")
        defer { fixture.remove() }
        let base = try revision("HEAD", in: fixture)
        _ = try commit("tip.txt", in: fixture)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let created = try await client.createWorktree(
            request(
                fixture, "feat",
                .newBranch(
                    name: "feat", startPoint: .named(base),
                    upstream: GitBranchUpstream(remoteName: "origin", branchName: "feat"))))
        let branchesBeforeDetached = try fixture.git.run("for-each-ref", "refs/heads")
        let detached = try await client.createWorktree(
            request(fixture, "detached", .detached(startPoint: .named(base))))

        // Assert
        #expect(created.worktree.head == GitHeadSnapshot(kind: .branch, oid: base, shortName: "feat"))
        #expect(try fixture.git.run("config", "branch.feat.remote") == "origin\n")
        #expect(try fixture.git.run("config", "branch.feat.merge") == "refs/heads/feat\n")
        #expect(detached.worktree.head == GitHeadSnapshot(kind: .detached, oid: base, shortName: nil))
        #expect(try fixture.git.run("for-each-ref", "refs/heads") == branchesBeforeDetached)
        #expect(try status(fixture.linkedWorktreePath("detached")).isEmpty)
        #expect(try status(fixture.linkedWorktreePath("feat")).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.linkedWorktreePath("detached").appending(path: "tip.txt").path))
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

    private func status(_ worktree: URL) throws -> String {
        try GitProcess(repositoryPath: worktree).run("status", "--porcelain")
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
