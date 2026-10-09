import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Moves a fast-forwarded branch back to its previous tip under the branch's ref lock, only while it still points
/// where the failed creation moved it. A branch someone else moved meanwhile is left alone: the undo reports
/// failure rather than overwrite another writer's move. The commit renames the ref into place before it syncs the
/// directory, so a commit error can follow an undo that landed; the ref is re-read either way.
struct LibGit2BranchMoveUndo {
    let lockObserver: LibGit2BranchAttachLockObserver
    /// Runs after the undo's commit and before the re-read that confirms it; a fault seam for tests.
    var afterCommit: () -> Void = {}

    /// True only when the branch is verified back at `fromOID`.
    func undo(
        _ referenceName: String,
        from fromOID: String,
        to toOID: String,
        repository: OpaquePointer
    ) -> Bool {
        guard var previousTip = WorktreeForkObjectID.parse(fromOID),
            let referenceLockFact = try? LibGit2LockPathResolver.fact(
                for: .reference(name: referenceName), repository: repository)
        else {
            return false
        }
        var transaction: OpaquePointer?
        guard git_transaction_new(&transaction, repository) >= 0, let transaction else {
            return false
        }
        defer { git_transaction_free(transaction) }
        lockObserver.attempting([referenceLockFact])
        guard referenceName.withCString({ git_transaction_lock_ref(transaction, $0) }) >= 0 else {
            lockObserver.failed([referenceLockFact])
            return false
        }
        lockObserver.acquired(referenceLockFact)
        guard referenceTip(referenceName, repository: repository) == toOID.lowercased() else {
            return false
        }
        let message = "agentstudio worktree: undo fast-forward to \(toOID)"
        let setResult = referenceName.withCString { referencePointer in
            message.withCString { git_transaction_set_target(transaction, referencePointer, &previousTip, nil, $0) }
        }
        guard setResult >= 0 else {
            return false
        }
        if git_transaction_commit(transaction) < 0 {
            lockObserver.failed([referenceLockFact])
        }
        afterCommit()
        return referenceTip(referenceName, repository: repository) == fromOID.lowercased()
    }

    private func referenceTip(_ referenceName: String, repository: OpaquePointer) -> String? {
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        guard lookupResult >= 0, let reference else {
            return nil
        }
        defer { git_reference_free(reference) }
        guard git_reference_type(reference) == GIT_REFERENCE_DIRECT, let target = git_reference_target(reference) else {
            return nil
        }
        return oidString(target)
    }
}
