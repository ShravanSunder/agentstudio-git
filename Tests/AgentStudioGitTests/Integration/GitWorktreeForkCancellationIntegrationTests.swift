import AgentStudioGit
import Dispatch
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree fork cancellation integration", .serialized)
struct GitWorktreeForkCancellationIntegrationTests {
    @Test(
        "changes-only cancellation at registration, checkout, and overlay rolls back",
        arguments: [
            WorktreeForkFaultPoint.afterWorktreeAdded,
            .afterHeadCheckedOut,
            .afterChangesOnlyOverlay,
        ]
    )
    func changesOnlyCancellationAtMaterializationPhaseRollsBack(point: WorktreeForkFaultPoint) async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-cancel-phase")
        defer { fixture.remove() }
        let name = "changes-only-cancel-phase"
        let destination = fixture.destination(name)

        // Act
        let failure = await cancelForkWhenReached(
            fixture: fixture,
            destination: destination,
            branchName: name,
            point: point,
            materialization: .changesOnly
        )

        // Assert
        #expect(failure == .cancelled)
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(name)))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test(
        "cancellation after final validation rolls back both materializations",
        arguments: [GitWorktreeForkMaterialization.copyOnWrite, .changesOnly]
    )
    func cancellationAfterFinalValidationRollsBack(materialization: GitWorktreeForkMaterialization) async throws {
        // Arrange
        let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-cancel-validation")
        defer { fixture.remove() }
        let name = "validation-cancel-\(materialization.rawValue)"
        let destination = fixture.destination(name)

        // Act
        let failure = await cancelForkWhenReached(
            fixture: fixture,
            destination: destination,
            branchName: name,
            point: .afterValidation,
            materialization: materialization
        )

        // Assert
        #expect(failure == .cancelled)
        #expect(!GitWorktreeForkFileProbe.exists(destination))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(name)))
        #expect(try fixture.branchNames() == ["refs/heads/main"])
    }

    @Test("HEAD and index moves during final content rehash refuse as repositoryStateChanged")
    func repositoryStateMovesDuringFinalContentRehashAreDetected() async throws {
        for (name, command) in [
            ("final-head-race", ["update-ref", "refs/heads/main", "HEAD~1"]),
            ("final-index-race", ["add", "tracked.txt"]),
        ] {
            // Arrange
            let fixture = try Self.preparedSource(prefix: "agentstudio-git-fork-\(name)")
            defer { fixture.remove() }
            let sourceRoot = fixture.source
            let destination = fixture.destination(name)
            let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
                guard point == .afterChangesOnlyContentRehash else {
                    return
                }
                _ = try? GitProcess(repositoryPath: sourceRoot).run(command)
            }
            let client = LibGit2AgentStudioGitLocalClient(
                writerRegistry: GitRepositoryWriterRegistry(),
                worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
            )

            // Act
            let failure: GitWorktreeForkError?
            do {
                _ = try await client.forkWorktree(
                    fixture.request(
                        destination: destination,
                        mode: .newBranch(name: name),
                        materialization: .changesOnly
                    )
                )
                failure = nil
            } catch {
                failure = error
            }

            // Assert
            #expect(failure == .sourceChanged(relativePath: ".", reason: .repositoryStateChanged))
            #expect(!GitWorktreeForkFileProbe.exists(destination))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration(name)))
            #expect(try fixture.branchNames() == ["refs/heads/main"])
        }
    }

    private func cancelForkWhenReached(
        fixture: GitWorktreeForkFixture,
        destination: URL,
        branchName: String,
        point: WorktreeForkFaultPoint,
        materialization: GitWorktreeForkMaterialization
    ) async -> GitWorktreeForkError? {
        let (events, continuation) = AsyncStream.makeStream(of: Bool.self)
        var eventIterator = events.makeAsyncIterator()
        let releasePoint = DispatchSemaphore(value: 0)
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            guard reached == point else {
                return
            }
            continuation.yield(true)
            releasePoint.wait()
        }
        let client = LibGit2AgentStudioGitLocalClient(
            writerRegistry: GitRepositoryWriterRegistry(),
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )
        let request = fixture.request(
            destination: destination,
            mode: .newBranch(name: branchName),
            materialization: materialization
        )

        let fork = Task { () -> GitWorktreeForkError? in
            do throws(GitWorktreeForkError) {
                _ = try await client.forkWorktree(request)
                return nil
            } catch {
                return error
            }
        }
        #expect(await eventIterator.next() == true)
        fork.cancel()
        releasePoint.signal()
        let failure = await fork.value
        continuation.finish()
        return failure
    }

    private static func preparedSource(prefix: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        try fixture.write("tracked.txt", "baseline\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.git.run("commit", "-m", "cancellation baseline")
        try fixture.write("tracked.txt", "carried change\n")
        return fixture
    }
}
