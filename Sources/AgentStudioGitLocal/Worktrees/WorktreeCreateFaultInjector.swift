import Foundation

/// Named plain-checkout boundaries where failure injection proves what a failure leaves behind.
enum WorktreeCreateFaultPoint: Hashable, Sendable {
    /// The worktree is registered, checked out, and validated detached at the start; no branch has moved.
    case beforeBranchAttach
    /// The branch ref is committed and the worktree is on it; a new branch's upstream is not written yet. A fault
    /// here also stands for an attach whose commit reported failure after its ref landed.
    case afterBranchAttached
}

/// Production passes `.production`.
struct WorktreeCreateFaultInjector: Sendable {
    static let production = Self { _ in }

    let reach: @Sendable (WorktreeCreateFaultPoint) throws -> Void
}
