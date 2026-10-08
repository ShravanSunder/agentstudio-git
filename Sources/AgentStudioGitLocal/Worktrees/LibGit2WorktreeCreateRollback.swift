import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct WorktreeCreateRollback {
    let repositoryPath: URL
    let worktreeName: String
    /// The call-owned carrier branch while it exists; its unique name lets plain deletion remove it.
    var carrierBranchName: String?
    /// A new branch the attach created, until its upstream write succeeds; removed only at that commit.
    var createdBranch: (name: String, commit: String)?
    /// An existing branch the attach fast-forwarded. Its commit can report failure after the ref landed, so a
    /// failed call moves it back to `from` under its ref lock.
    var movedBranch: (name: String, from: String, to: String)?
    var createdWorktree = false
    private var isArmed = true

    init(repositoryPath: URL, worktreeName: String) {
        self.repositoryPath = repositoryPath
        self.worktreeName = worktreeName
    }

    mutating func disarm() {
        isArmed = false
    }

    /// Removes what the failed call made and moves a fast-forwarded branch back. Returns the error that replaces the
    /// call's own when that move cannot be confirmed undone.
    func rollback(runtime: LibGit2Runtime) -> GitDataPlaneError? {
        guard isArmed else {
            return nil
        }
        let moveNotUndone = movedBranch.map {
            GitDataPlaneError.branchMoveNotUndone(branchName: $0.name, from: $0.from, to: $0.to)
        }
        do {
            try runtime.ensureInitialized()
        } catch {
            return moveNotUndone
        }

        var repository: OpaquePointer?
        let openResult = repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            return moveNotUndone
        }
        defer { git_repository_free(repository) }

        if createdWorktree {
            pruneWorktreeIfPresent(named: worktreeName, repository: repository)
        }
        if let carrierBranchName {
            deleteLocalBranchIfPresent(named: carrierBranchName, repository: repository)
        }
        if let createdBranch {
            _ = LibGit2CreatedBranchCompensation(repositoryPath: repositoryPath, runtime: runtime)
                .remove(branchName: createdBranch.name, createdAt: createdBranch.commit)
        }
        guard let movedBranch else {
            return nil
        }
        let restored = LibGit2BranchMoveUndo(lockObserver: .untracked).undo(
            "refs/heads/\(movedBranch.name)", from: movedBranch.from, to: movedBranch.to, repository: repository)
        return restored ? nil : moveNotUndone
    }
}

private func pruneWorktreeIfPresent(named name: String, repository: OpaquePointer) {
    var worktree: OpaquePointer?
    let lookupResult = name.withCString { namePointer in
        git_worktree_lookup(&worktree, repository, namePointer)
    }
    guard lookupResult >= 0, let worktree else {
        return
    }
    defer { git_worktree_free(worktree) }

    var options = git_worktree_prune_options()
    let optionsResult = git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
    guard optionsResult >= 0 else {
        return
    }
    options.flags =
        GIT_WORKTREE_PRUNE_VALID.rawValue
        | GIT_WORKTREE_PRUNE_LOCKED.rawValue
        | GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue
    _ = git_worktree_prune(worktree, &options)
}

/// Plain deletion, for the carrier only.
private func deleteLocalBranchIfPresent(named name: String, repository: OpaquePointer) {
    var reference: OpaquePointer?
    let lookupResult = name.withCString { namePointer in
        git_branch_lookup(&reference, repository, namePointer, GIT_BRANCH_LOCAL)
    }
    guard lookupResult >= 0, let reference else {
        return
    }
    defer { git_reference_free(reference) }
    _ = git_branch_delete(reference)
}
