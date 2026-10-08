import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Attaches a copied, validated fork to its branch target. Every fork registers its linked worktree detached at
/// the captured `HEAD`, so this is the one place a fork's branch is created, fast-forwarded, or checked out: under
/// the branch's native ref lock, with branch use re-read there. Each landed change is journaled for rollback.
struct WorktreeForkBranchAttach {
    let faults: WorktreeForkFaultInjector

    func attach(_ plan: WorktreeForkPlan, journal: inout WorktreeForkRollbackJournal) throws(GitWorktreeForkError) {
        try faults.reach(.beforeBranchAttach)
        switch plan.branchIdentity {
        case .detached:
            if plan.resetsToStart {
                try WorktreeForkGitHandles.detachHead(
                    worktreePath: plan.destinationRoot,
                    commitOID: plan.start.commitOID,
                    lockTracker: journal.lockTracker
                )
            }
        case .newBranch(let referenceName, let upstream):
            try attachBranch(
                plan,
                target: .newBranch(referenceName: referenceName, commit: plan.start.commitOID),
                upstream: upstream,
                journal: &journal
            )
        case .existingBranch(let referenceName, let expectedTip, let fastForwardTo):
            try attachBranch(
                plan,
                target: .existingBranch(
                    referenceName: referenceName, expectedTip: expectedTip, fastForwardTo: fastForwardTo),
                upstream: nil,
                journal: &journal
            )
        }
        try faults.reach(.afterBranchAttached)
    }

    private func attachBranch(
        _ plan: WorktreeForkPlan,
        target: LibGit2BranchAttachTarget,
        upstream: GitBranchUpstream?,
        journal: inout WorktreeForkRollbackJournal
    ) throws(GitWorktreeForkError) {
        let repository = try WorktreeForkGitHandles.openWorktree(plan.destinationRoot)
        defer { git_repository_free(repository) }
        let lockObserver = LibGit2BranchAttachLockObserver.tracking(journal.lockTracker)
        let faults = self.faults
        try LibGit2BranchAttach(
            request: LibGit2BranchAttachRequest(
                repositoryPath: plan.sourceRoot,
                transactionRepository: repository,
                target: target
            ),
            lockObserver: lockObserver
        ).run(
            refusal: Self.forkError,
            checkpoint: { point throws(GitWorktreeForkError) in
                switch point {
                case .referenceLocked(let referenceName):
                    try faults.reach(.afterBranchReferenceLockAcquired(referenceName: referenceName))
                case .headAttached(let referenceName):
                    try faults.reach(.afterBranchHeadAttached(referenceName: referenceName))
                }
            },
            landed: { effect in
                switch effect {
                case .created(let referenceName, let commit):
                    journal.record(.attachedBranch(referenceName: referenceName, targetOID: commit))
                case .fastForwarded(let referenceName, let from, let to):
                    journal.record(.movedBranch(referenceName: referenceName, fromOID: from, toOID: to))
                }
            }
        )
        guard let upstream else {
            return
        }
        do throws(GitDataPlaneError) {
            try LibGit2BranchUpstreamWriter(lockObserver: lockObserver).write(
                upstream,
                branchName: String(target.referenceName.dropFirst("refs/heads/".count)),
                repository: repository
            )
        } catch {
            throw .gitFailure(error)
        }
    }

    private static func forkError(_ refusal: LibGit2BranchAttachRefusal) -> GitWorktreeForkError {
        switch refusal {
        case .checkedOut(let worktreePath):
            .branchCheckedOut(worktreePath: worktreePath)
        case .moved:
            .rejected(reason: .branchMoved)
        case .alreadyExists:
            .rejected(reason: .branchAlreadyExists)
        case .gitFailure(let error):
            .gitFailure(error)
        }
    }
}

extension LibGit2BranchAttachLockObserver {
    static func tracking(_ tracker: WorktreeForkLockTracker) -> Self {
        Self(
            attempting: { tracker.beginAttempt(for: $0) },
            acquired: { tracker.recordAcquisition(of: $0) },
            failed: { tracker.recordFailure(for: $0) }
        )
    }
}
