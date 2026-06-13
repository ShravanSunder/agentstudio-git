import CLibGit2Local
import Foundation

struct WorktreeCreateRollback {
    let repositoryPath: URL
    let worktreeName: String
    var createdBranchName: String?
    var createdWorktree = false
    private var isArmed = true

    init(repositoryPath: URL, worktreeName: String) {
        self.repositoryPath = repositoryPath
        self.worktreeName = worktreeName
    }

    mutating func disarm() {
        isArmed = false
    }

    func rollback(runtime: LibGit2Runtime) {
        guard isArmed else {
            return
        }
        do {
            try runtime.ensureInitialized()
        } catch {
            return
        }

        var repository: OpaquePointer?
        let openResult = repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            return
        }
        defer { git_repository_free(repository) }

        if createdWorktree {
            pruneWorktreeIfPresent(named: worktreeName, repository: repository)
        }
        if let createdBranchName {
            deleteLocalBranchIfPresent(named: createdBranchName, repository: repository)
        }
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
