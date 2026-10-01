import AgentStudioGit
import AgentStudioGitContracts
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git branch deletion race integration", .serialized)
struct GitBranchDeletionRaceIntegrationTests {
    @Test("a tip moved before the locked compare is retained with metadata unchanged")
    func tipMovedBeforeLockedCompareIsRetained() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-moved")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let expectedCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        try fixture.gitFixture.write("moved-target.txt", contents: "new target\n")
        try fixture.git.run("add", "moved-target.txt")
        try fixture.git.run("commit", "-m", "advance main target")
        let movedCommit = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let configurationLock = fixture.gitDirectory.appending(path: "config.lock")
        try fixture.writeLockFile(configurationLock)
        let configurationLockContentsBefore = try Data(contentsOf: configurationLock)
        let releaseLockBoundary = DispatchSemaphore(value: 0)
        let (checkpoints, checkpointContinuation) = AsyncStream.makeStream(of: GitBranchDeletionCheckpoint.self)
        var checkpointIterator = checkpoints.makeAsyncIterator()
        let control = GitBranchDeletionTransactionControl { checkpoint in
            guard checkpoint == .beforeReferenceLock else {
                return
            }
            checkpointContinuation.yield(checkpoint)
            _ = releaseLockBoundary.wait(timeout: .now() + .seconds(10))
        }
        let writer = LibGit2LocalBranchDeletionWriter(transactionControl: control)
        let client = LibGit2AgentStudioGitLocalClient(branchDeletionWriter: writer)
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: fixture.repositoryPath,
            branchName: "topic",
            expectedCommit: expectedCommit
        )

        // Act
        let deleteTask = Task { try await client.deleteLocalBranch(request) }
        defer { releaseLockBoundary.signal() }
        #expect(await checkpointIterator.next() == .beforeReferenceLock)
        try fixture.git.run("update-ref", "refs/heads/topic", movedCommit)
        let configAfterMove = try fixture.localConfiguration()
        let reflogAfterMove = try #require(try fixture.reflogBytes(for: "topic"))
        releaseLockBoundary.signal()
        checkpointContinuation.finish()
        let result = try await deleteTask.value

        // Assert
        #expect(result == .retained(reason: .moved(currentCommit: movedCommit), lockResidue: []))
        #expect(try fixture.branchCommit("topic") == movedCommit)
        #expect(try fixture.localConfiguration() == configAfterMove)
        #expect(try fixture.reflogBytes(for: "topic") == reflogAfterMove)
        #expect(try Data(contentsOf: configurationLock) == configurationLockContentsBefore)
    }

    @Test("a malformed linked worktree administration refuses deletion without changing branch metadata")
    func malformedLinkedWorktreeAdministrationRefusesDeletion() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-corrupt-checkout")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        _ = try fixture.addLinkedWorktree(named: "linked-corrupt", onBranch: "topic")
        let administrationHead = fixture.gitDirectory.appending(path: "worktrees/linked-corrupt/HEAD")
        try Data("not a symbolic ref\n".utf8).write(to: administrationHead)
        let topicCommit = try fixture.branchCommit("topic")
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        do {
            _ = try await client.deleteLocalBranch(
                GitDeleteLocalBranchRequest(
                    repositoryPath: fixture.repositoryPath,
                    branchName: "topic",
                    expectedCommit: topicCommit
                )
            )
            Issue.record("branch deletion unexpectedly ignored corrupt linked worktree administration")
        } catch {
            #expect(error.reason == .checkoutUnreadable(worktreePath: nil))
            #expect(error.lockResidue?.isEmpty == true)
        }
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
    }

    @Test("a native packed reference lock failure after removal staging is re-probed as uncertain")
    func packedReferenceLockFailureAfterStagingIsReprobed() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-packed-lock")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        try fixture.git.run("pack-refs", "--all", "--prune")
        let packedReferencesLock = fixture.gitDirectory.appending(path: "packed-refs.lock")
        try fixture.writeLockFile(packedReferencesLock)
        let packedReferencesLockContentsBefore = try Data(contentsOf: packedReferencesLock)
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(
            result
                == .uncertain(
                    error: .lockHeld(
                        GitLockFact(path: packedReferencesLock, resource: .packedRefs)
                    ),
                    lockResidue: []
                )
        )
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
        #expect(try Data(contentsOf: packedReferencesLock) == packedReferencesLockContentsBefore)
    }

    @Test("metadata cleanup failure leaves the affected config and reports its lock")
    func metadataCleanupFailureLeavesConfigAndReportsLock() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-config-lock")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        let configurationLock = fixture.gitDirectory.appending(path: "config.lock")
        try fixture.writeLockFile(configurationLock)
        let configurationLockContentsBefore = try Data(contentsOf: configurationLock)
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(
                        configuration: .leftInPlace(.removalFailed),
                        reflog: .removed
                    ),
                    lockResidue: []
                )
        )
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/heads/topic") == false)
        #expect(try fixture.configValue("branch.topic.remote") == "origin")
        #expect(try fixture.reflogBytes(for: "topic") == nil)
        #expect(try Data(contentsOf: configurationLock) == configurationLockContentsBefore)
        #expect(!reflogBefore.isEmpty)
    }

    @Test("a branch recreated before reservation keeps its new config and reflog")
    func branchRecreatedBeforeReservationKeepsMetadata() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-recreated-before")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        let releaseCleanupBoundary = DispatchSemaphore(value: 0)
        let (checkpoints, checkpointContinuation) = AsyncStream.makeStream(of: GitBranchDeletionCheckpoint.self)
        var checkpointIterator = checkpoints.makeAsyncIterator()
        let control = GitBranchDeletionTransactionControl { checkpoint in
            guard checkpoint == .beforeCleanupReservation else {
                return
            }
            checkpointContinuation.yield(checkpoint)
            _ = releaseCleanupBoundary.wait(timeout: .now() + .seconds(10))
        }
        let client = LibGit2AgentStudioGitLocalClient(
            branchDeletionWriter: LibGit2LocalBranchDeletionWriter(transactionControl: control)
        )
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: fixture.repositoryPath,
            branchName: "topic",
            expectedCommit: topicCommit
        )

        // Act
        let deleteTask = Task { try await client.deleteLocalBranch(request) }
        defer { releaseCleanupBoundary.signal() }
        #expect(await checkpointIterator.next() == .beforeCleanupReservation)
        try fixture.git.run("update-ref", "--create-reflog", "refs/heads/topic", topicCommit)
        let configAfterRecreation = try fixture.localConfiguration()
        let reflogAfterRecreation = try #require(try fixture.reflogBytes(for: "topic"))
        releaseCleanupBoundary.signal()
        checkpointContinuation.finish()
        let result = try await deleteTask.value

        // Assert
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(
                        configuration: .leftInPlace(.recreatedMeanwhile),
                        reflog: .leftInPlace(.recreatedMeanwhile)
                    ),
                    lockResidue: []
                )
        )
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configAfterRecreation)
        #expect(try fixture.reflogBytes(for: "topic") == reflogAfterRecreation)
    }

    @Test("an unavailable absent-ref reservation defers both metadata cleanups")
    func unavailableAbsentReferenceReservationDefersMetadataCleanup() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-reservation-lock")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        let referenceLock = fixture.gitDirectory.appending(path: "refs/heads/topic.lock").standardizedFileURL
        let reachedReservation = AsyncStream.makeStream(of: GitBranchDeletionCheckpoint.self)
        let releaseReservation = DispatchSemaphore(value: 0)
        let control = GitBranchDeletionTransactionControl { checkpoint in
            guard checkpoint == .beforeCleanupReservation else {
                return
            }
            reachedReservation.continuation.yield(checkpoint)
            _ = releaseReservation.wait(timeout: .now() + .seconds(10))
        }
        let client = LibGit2AgentStudioGitLocalClient(
            branchDeletionWriter: LibGit2LocalBranchDeletionWriter(transactionControl: control)
        )
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: fixture.repositoryPath,
            branchName: "topic",
            expectedCommit: topicCommit
        )

        // Act
        var checkpointIterator = reachedReservation.stream.makeAsyncIterator()
        let deleteTask = Task { try await client.deleteLocalBranch(request) }
        defer { releaseReservation.signal() }
        #expect(await checkpointIterator.next() == .beforeCleanupReservation)
        try fixture.writeLockFile(referenceLock)
        let referenceLockContentsBefore = try Data(contentsOf: referenceLock)
        releaseReservation.signal()
        reachedReservation.continuation.finish()
        let result = try await deleteTask.value

        // Assert
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(
                        configuration: .leftInPlace(.reservationUnavailable),
                        reflog: .leftInPlace(.reservationUnavailable)
                    ),
                    lockResidue: []
                )
        )
        #expect(try Data(contentsOf: referenceLock) == referenceLockContentsBefore)
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/heads/topic") == false)
        #expect(try fixture.configValue("branch.topic.remote") == "origin")
        #expect(try fixture.reflogBytes(for: "topic") != nil)
    }

    @Test("the absent-ref reservation blocks a new branch until metadata cleanup finishes")
    func absentReferenceReservationBlocksRecreationDuringCleanup() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-recreated-during")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        let releaseReservation = DispatchSemaphore(value: 0)
        let (checkpoints, checkpointContinuation) = AsyncStream.makeStream(of: GitBranchDeletionCheckpoint.self)
        var checkpointIterator = checkpoints.makeAsyncIterator()
        let control = GitBranchDeletionTransactionControl { checkpoint in
            guard checkpoint == .afterCleanupReservation else {
                return
            }
            checkpointContinuation.yield(checkpoint)
            _ = releaseReservation.wait(timeout: .now() + .seconds(10))
        }
        let client = LibGit2AgentStudioGitLocalClient(
            branchDeletionWriter: LibGit2LocalBranchDeletionWriter(transactionControl: control)
        )
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: fixture.repositoryPath,
            branchName: "topic",
            expectedCommit: topicCommit
        )

        // Act
        let deleteTask = Task { try await client.deleteLocalBranch(request) }
        defer { releaseReservation.signal() }
        #expect(await checkpointIterator.next() == .afterCleanupReservation)
        let creationSucceeded = try fixture.git.succeeds("update-ref", "refs/heads/topic", topicCommit)
        releaseReservation.signal()
        checkpointContinuation.finish()
        let result = try await deleteTask.value

        // Assert
        #expect(!creationSucceeded)
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(configuration: .removed, reflog: .removed),
                    lockResidue: []
                )
        )
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/heads/topic") == false)
        #expect(try fixture.git.succeeds("config", "--local", "--get", "branch.topic.remote") == false)
    }

    @Test("a checkout read failure plus a denied lock release reports the residue path")
    func checkoutFailureWithDeniedReferenceLockReleaseReportsResidue() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-denied-release")
        let referencesDirectory = fixture.gitDirectory.appending(path: "refs/heads")
        var originalDirectoryStatus = stat()
        let statResult = referencesDirectory.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            fixture.remove()
            Issue.record("could not stat the local branch reference directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        let readOnlyMode = originalMode & ~mode_t(0o222)
        defer {
            _ = referencesDirectory.path.withCString { chmod($0, originalMode) }
            fixture.remove()
        }
        try fixture.makeBranch("topic")
        _ = try fixture.addLinkedWorktree(named: "linked-corrupt", onBranch: "topic")
        let administrationHead = fixture.gitDirectory.appending(path: "worktrees/linked-corrupt/HEAD")
        try Data("not a symbolic ref\n".utf8).write(to: administrationHead)
        let topicCommit = try fixture.branchCommit("topic")
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let chmodResult = OSAllocatedUnfairLock(initialState: Int32(-1))
        let control = GitBranchDeletionTransactionControl { checkpoint in
            guard checkpoint == .afterReferenceLock else {
                return
            }
            let result = referencesDirectory.path.withCString { chmod($0, readOnlyMode) }
            chmodResult.withLock { $0 = result }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            branchDeletionWriter: LibGit2LocalBranchDeletionWriter(transactionControl: control)
        )
        let referenceLock = fixture.gitDirectory.appending(path: "refs/heads/topic.lock").standardizedFileURL

        // Act / Assert
        do {
            _ = try await client.deleteLocalBranch(
                GitDeleteLocalBranchRequest(
                    repositoryPath: fixture.repositoryPath,
                    branchName: "topic",
                    expectedCommit: topicCommit
                )
            )
            Issue.record("branch deletion unexpectedly ignored corrupt linked worktree administration")
        } catch {
            #expect(error.reason == .checkoutUnreadable(worktreePath: nil))
            #expect(error.lockResidue == [referenceLock])
        }
        #expect(chmodResult.withLock { $0 } == 0)
        #expect(FileManager.default.fileExists(atPath: referenceLock.path))
        _ = referencesDirectory.path.withCString { chmod($0, originalMode) }
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
    }
}
