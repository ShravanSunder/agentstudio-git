import Foundation

enum GitBranchDeletionCheckpoint: Equatable, Sendable {
    case beforeReferenceLock
    case afterReferenceLock
    case beforeCleanupReservation
    case afterCleanupReservation
}

struct GitBranchDeletionTransactionControl: Sendable {
    static let live = Self { _ in }

    private let reach: @Sendable (GitBranchDeletionCheckpoint) -> Void

    init(reach: @escaping @Sendable (GitBranchDeletionCheckpoint) -> Void = { _ in }) {
        self.reach = reach
    }

    func reachCheckpoint(_ checkpoint: GitBranchDeletionCheckpoint) {
        reach(checkpoint)
    }
}
