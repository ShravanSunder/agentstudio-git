import AgentStudioGit
import Dispatch
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git repository writer lane")
struct GitRepositoryWriterLaneTests {
    @Test("mutations on one lane run FIFO and never interleave")
    func mutationsOnOneLaneRunFIFOAndNeverInterleave() async throws {
        // Arrange
        let lane = await GitRepositoryWriterRegistry().writer(for: identity(named: "fifo"))
        let (events, ledger) = AsyncStream.makeStream(of: LaneEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseFirst = DispatchSemaphore(value: 0)

        // Act
        let first = Task {
            await lane.run { () -> Int in
                ledger.yield(.firstStarted)
                releaseFirst.wait()
                ledger.yield(.firstFinished)
                return 1
            }
        }
        #expect(await eventIterator.next() == .firstStarted)
        let second = Task {
            await lane.run(
                { () -> Int in
                    ledger.yield(.secondStarted)
                    return 2
                },
                onEnqueued: { ledger.yield(.secondEnqueued) }
            )
        }
        #expect(await eventIterator.next() == .secondEnqueued)
        releaseFirst.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        ledger.finish()
        var remainingEvents: [LaneEvent] = []
        while let event = await eventIterator.next() {
            remainingEvents.append(event)
        }

        // Assert
        #expect(firstResult == 1)
        #expect(secondResult == 2)
        #expect(remainingEvents == [.firstFinished, .secondStarted])
    }

    @Test("an unrelated lane progresses while another lane's mutation is blocked")
    func unrelatedLaneProgressesWhileAnotherLaneIsBlocked() async throws {
        // Arrange
        let registry = GitRepositoryWriterRegistry()
        let blockedLane = await registry.writer(for: identity(named: "blocked"))
        let unrelatedLane = await registry.writer(for: identity(named: "unrelated"))
        let (events, ledger) = AsyncStream.makeStream(of: LaneEvent.self)
        var eventIterator = events.makeAsyncIterator()
        let releaseBlocked = DispatchSemaphore(value: 0)
        let blocked = Task {
            await blockedLane.run { () -> Int in
                ledger.yield(.firstStarted)
                releaseBlocked.wait()
                return 1
            }
        }
        #expect(await eventIterator.next() == .firstStarted)

        // Act
        let unrelatedResult = await unrelatedLane.run { () -> Int in 2 }
        releaseBlocked.signal()
        let blockedResult = await blocked.value

        // Assert
        #expect(unrelatedResult == 2)
        #expect(blockedResult == 1)
    }

    @Test("mutation closures execute on the lane's serial queue and rethrow typed failures")
    func mutationClosuresExecuteOnLaneQueue() async throws {
        // Arrange
        let lane = await GitRepositoryWriterRegistry().writer(for: identity(named: "queue"))

        // Act
        let executedOnLaneQueue = await lane.run { lane.isExecutingOnLaneQueue }
        let failure: LaneProbeFailure?
        do throws(LaneProbeFailure) {
            _ = try await lane.run { () throws(LaneProbeFailure) -> Int in throw LaneProbeFailure.expected }
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(executedOnLaneQueue)
        #expect(!lane.isExecutingOnLaneQueue)
        #expect(failure == .expected)
    }

    private func identity(named name: String) -> GitRepositoryIdentity {
        GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "lane-\(name)-\(UUID().uuidString)"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/\(name)/.git"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/\(name)")
        )
    }
}

private enum LaneEvent: Equatable, Sendable {
    case firstStarted
    case firstFinished
    case secondEnqueued
    case secondStarted
}

private enum LaneProbeFailure: Error, Equatable {
    case expected
}
