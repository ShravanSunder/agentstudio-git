import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Step 2 of a reset copy (LR29). The copy has been materialized, re-homed, indexed from the captured `HEAD`,
/// and validated while detached there; this checks the start's tree out over it, forced, with that rebuilt
/// index as the explicit baseline. libgit2's default baseline is `HEAD`'s tree, which is fine only while `HEAD`
/// is the captured commit; naming the index keeps the rule independent of where `HEAD` points.
///
/// Against that baseline: a file whose content differs from the start gets the start's content; a path tracked
/// at the captured `HEAD` and absent at the start is removed (a removed submodule with its directory); a file
/// equal to the start is not rewritten, because the rebuilt index vouches for its stats, so it keeps its clone
/// and timestamps; an untracked file (an included ignored one) is left alone unless the start tracks its path.
/// The checkout writes the index, which becomes the start's tree; `HEAD` moves only at the attach.
struct WorktreeForkResetCheckout {
    let faults: WorktreeForkFaultInjector

    /// Returns the start's submodules whose copied checkout is not at the start's commit.
    func checkout(
        _ plan: WorktreeForkPlan,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) -> [String] {
        let repository = try WorktreeForkGitHandles.openWorktree(plan.destinationRoot)
        defer { git_repository_free(repository) }
        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: indexResult))
        }
        defer { git_index_free(index) }
        let readResult = git_index_read(index, 1)
        guard readResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: readResult))
        }
        let start = try WorktreeForkGitHandles.lookupCommit(plan.start.commitOID, repository: repository)
        defer { git_commit_free(start) }

        let indexLockFact = try WorktreeForkGitHandles.lockFact(
            for: .index(worktreePath: plan.destinationRequestPath), repository: repository)
        lockTracker.beginAttempt(for: [indexLockFact])
        var options = git_checkout_options()
        let optionsResult = git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        guard optionsResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: optionsResult))
        }
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        options.baseline_index = index
        errno = 0
        let checkoutResult = git_checkout_tree(repository, start, &options)
        let checkoutErrorNumber = errno
        guard checkoutResult >= 0 else {
            lockTracker.recordFailure(for: [indexLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: checkoutResult, lockFacts: [indexLockFact], systemErrorCode: checkoutErrorNumber))
        }
        try faults.reach(.afterResetCheckout)
        return try submodulesNotAtStart(plan, repository: repository)
    }

    /// A gitlink of the start is at the start when the source had that submodule initialized with its checkout
    /// at exactly that commit; the copy carried that checkout. Anything else (another commit, or a submodule the
    /// source never initialized or did not have) arrives not at the start and is listed, never moved.
    private func submodulesNotAtStart(
        _ plan: WorktreeForkPlan,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> [String] {
        let checkedOutCommits = Dictionary(
            plan.gitTopology.nodes.map { ($0.relativePath, $0.capturedHead?.commitOID) },
            uniquingKeysWith: { first, _ in first })
        let gitlinkMode = UInt32(GIT_FILEMODE_COMMIT.rawValue)
        return try WorktreeForkGitHandles.treeEntries(plan.start.treeOID, repository: repository)
            .filter { path, entry in
                entry.mode == gitlinkMode && checkedOutCommits[path].flatMap({ $0 }) != entry.oid
            }
            .map(\.key)
            .sorted()
    }
}
