import Foundation

/// Named plain-checkout boundaries where failure injection proves what a failure leaves behind.
enum WorktreeCreateFaultPoint: Hashable, Sendable {
    /// The worktree is registered, checked out, and validated detached at the start; no branch has moved.
    case beforeBranchAttach
    /// A new branch exists at the start and the worktree is on it; its upstream is not written yet.
    case beforeUpstreamWrite
}

/// Production passes `.production`.
struct WorktreeCreateFaultInjector: Sendable {
    static let production = Self { _ in }

    let reach: @Sendable (WorktreeCreateFaultPoint) throws -> Void
}
