import Foundation

/// Named plain-checkout boundaries where failure injection proves what a failure leaves behind.
enum WorktreeCreateFaultPoint: Hashable, Sendable {
    /// The worktree is registered, checked out, and validated detached at the start; no branch has moved.
    case beforeBranchAttach
}

/// Production passes `.production`.
struct WorktreeCreateFaultInjector: Sendable {
    static let production = Self { _ in }

    let reach: @Sendable (WorktreeCreateFaultPoint) throws -> Void
}
