import AgentStudioGitContracts
import Foundation
import os

/// Cancellation observed by the fork transaction on its blocking queue. The async caller's task
/// cancellation handler flips it; planning and leaf workers check it only at bounded boundaries, so
/// in-flight leaf operations finish and rollback runs before the lane releases custody.
final class WorktreeForkCancellation: Sendable {
    private let cancelledState = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelledState.withLock { $0 = true }
    }

    var isCancelled: Bool {
        cancelledState.withLock { $0 }
    }

    func throwIfCancelled() throws(GitWorktreeForkError) {
        if isCancelled {
            throw .cancelled
        }
    }
}

/// Named transaction boundaries where failure injection can prove rollback. Production passes `.production`.
enum WorktreeForkFaultPoint: Equatable, Sendable {
    case afterPlanning
    case afterIdentityCreated
    case afterWorktreeAdded
    case afterDirectoriesCreated
    case leafBatchStarted
    case afterMaterialization
    case afterGitStateRehomed
    case afterIndexesBuilt
    case afterValidation
    case rollbackRemovingDestination
    case afterRollback
}

struct WorktreeForkFaultInjector: Sendable {
    static let production = Self { _ throws(GitWorktreeForkError) in }

    let reach: @Sendable (WorktreeForkFaultPoint) throws(GitWorktreeForkError) -> Void
}
