import AgentStudioGit
import Dispatch
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork rollback integration", .serialized)
struct GitWorktreeForkRollbackIntegrationTests {
    private static let injected = GitWorktreeForkError.entryFailed(
        relativePath: "injected", reason: .entryCreationFailed, errorNumber: nil)

    @Test(
        "a failure after each transaction phase removes the destination, administration, and created branch",
        arguments: [
            WorktreeForkFaultPoint.afterPreflight,
            .afterPlanning,
            .afterIdentityCreated,
            .afterWorktreeAdded,
            .afterDirectoriesCreated,
            .leafBatchStarted,
            .afterMaterialization,
            .afterGitStateRehomed,
            .afterDirectoryMetadataApplied,
            .afterIndexesBuilt,
            .afterValidation,
        ],
        [GitForkWorktreeMode.newBranch(name: "fork"), .detached]
    )
    func failureAfterEachPhaseRollsBack(point: WorktreeForkFaultPoint, mode: GitForkWorktreeMode) async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-rollback")
        defer { fixture.removeRestoringPermissions() }
        let branchesBefore = try fixture.branchNames()
        let worktreesBefore = try fixture.git.run("worktree", "list", "--porcelain")
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == point {
                throw Self.injected
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request(mode: mode))

        // Assert
        #expect(failure == Self.injected)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
        #expect(try fixture.git.run("worktree", "list", "--porcelain") == worktreesBefore)
    }

    @Test("a cleanup failure returns cleanup-incomplete with ordered residue and never success")
    func cleanupFailureReturnsOrderedResidue() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-residue")
        defer { fixture.removeRestoringPermissions() }
        let branchesBefore = try fixture.branchNames()
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            switch reached {
            case .afterMaterialization, .rollbackRemovingDestination:
                throw Self.injected
            default:
                return
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        #expect(
            failure
                == .cleanupIncomplete(
                    primary: Self.injected,
                    residue: [GitWorktreeForkResidue(kind: .destinationContent, location: ".")]
                ))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
        _ = chmod(fixture.destination().appending(path: "sealed").path, 0o755)
    }

    @Test(
        "a destination another process creates after planning is never deleted by rollback, empty or not",
        arguments: [true, false]
    )
    func foreignDestinationCreatedAfterPlanningSurvivesRollback(foreignDirectoryHasFile: Bool) async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-foreign-destination")
        defer { fixture.removeRestoringPermissions() }
        let destination = fixture.destination()
        let foreignFile = destination.appending(path: "owner.txt")
        let branchesBefore = try fixture.branchNames()
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == .afterPlanning {
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                if foreignDirectoryHasFile {
                    try? Data("another process\n".utf8).write(to: foreignFile)
                }
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))

        // Act
        let failure = await forkFailure(client, fixture.request())

        // Assert
        guard case .cleanupIncomplete(let primary, let residue) = failure, case .gitFailure = primary else {
            Issue.record("expected a Git failure with residue, got \(String(describing: failure))")
            return
        }
        // The destination is foreign, and libgit2's empty administration skeleton from the failed add is
        // unconfirmed too: both are truthful residue, and neither is deleted.
        #expect(
            residue == [
                GitWorktreeForkResidue(kind: .destinationContent, location: "."),
                GitWorktreeForkResidue(kind: .linkedWorktreeAdministration, location: "worktrees/fork"),
            ])
        #expect(GitWorktreeForkFileProbe.exists(destination))
        if foreignDirectoryHasFile {
            #expect(try String(contentsOf: foreignFile, encoding: .utf8) == "another process\n")
        } else {
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
        #expect(try fixture.branchNames() == branchesBefore)
    }

    @Test("cancellation while leaves are in flight rolls back before the lane admits the next mutation")
    func cancellationWithLeavesInFlightRollsBackBeforeReleasingLane() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-cancel")
        defer { fixture.removeRestoringPermissions() }
        let registry = GitRepositoryWriterRegistry()
        let (events, ledger) = AsyncStream.makeStream(of: CancellationEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseLeaf = DispatchSemaphore(value: 0)
        let firstLeaf = OSAllocatedUnfairLock(initialState: true)
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            switch reached {
            case .leafBatchStarted
            where firstLeaf.withLock({ isFirst in
                defer { isFirst = false }
                return isFirst
            }):
                ledger.yield(.leafInFlight)
                releaseLeaf.wait()
            case .afterRollback:
                ledger.yield(.rollbackFinished)
            default:
                return
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: registry,
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )
        let lane = await registry.writer(for: try await client.repositoryIdentity(for: fixture.source))
        let request = fixture.request()

        // Act
        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(request)
                return nil
            } catch {
                return error
            }
        }
        #expect(await eventIterator.next() == .leafInFlight)
        let probe = Task {
            await lane.run(
                { _ = ledger.yield(.nextMutationRan) },
                onEnqueued: { ledger.yield(.nextMutationQueued) }
            )
        }
        #expect(await eventIterator.next() == .nextMutationQueued)
        fork.cancel()
        releaseLeaf.signal()
        let failure = await fork.value
        await probe.value
        ledger.finish()
        var remainingEvents: [CancellationEvent] = []
        while let event = await eventIterator.next() {
            remainingEvents.append(event)
        }

        // Assert
        #expect(failure == .cancelled)
        #expect(remainingEvents == [.rollbackFinished, .nextMutationRan])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("cancellation while queued behind another mutation returns cancelled without mutating")
    func cancellationWhileQueuedReturnsCancelledWithoutMutating() async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-queued")
        defer { fixture.removeRestoringPermissions() }
        let registry = GitRepositoryWriterRegistry()
        let client = LibGit2AgentStudioGitLocalClient(writerRegistry: registry)
        let lane = await registry.writer(for: try await client.repositoryIdentity(for: fixture.source))
        let (events, ledger) = AsyncStream.makeStream(of: CancellationEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blocker = Task {
            await lane.run {
                ledger.yield(.leafInFlight)
                releaseBlocker.wait()
            }
        }
        #expect(await eventIterator.next() == .leafInFlight)
        let request = fixture.request()

        // Act
        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(request)
                return nil
            } catch {
                return error
            }
        }
        fork.cancel()
        releaseBlocker.signal()
        await blocker.value
        let failure = await fork.value

        // Assert
        #expect(failure == .cancelled)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    /// A source with enough leaf batches for concurrent workers and a read-only directory, so rollback must
    /// undo reproduced restrictive modes.
    private static func preparedSource(prefix: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        for directoryIndex in 0..<6 {
            for fileIndex in 0..<(WorktreeForkSourceWalker.leafBatchSize + 1) {
                try fixture.write("bulk/\(directoryIndex)/file-\(fileIndex).txt", "\(directoryIndex)-\(fileIndex)\n")
            }
        }
        try fixture.write("sealed/inner.txt", "inside read-only directory\n")
        _ = chmod(fixture.source.appending(path: "sealed").path, 0o555)
        return fixture
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

private enum CancellationEvent: Equatable, Sendable {
    case leafInFlight
    case nextMutationQueued
    case rollbackFinished
    case nextMutationRan
}

extension GitWorktreeForkFixture {
    /// Restores write access to fixture directories made read-only before the fixture root is removed.
    func removeRestoringPermissions() {
        _ = chmod(source.appending(path: "sealed").path, 0o755)
        repository.remove()
    }
}
