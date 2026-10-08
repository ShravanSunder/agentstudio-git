import AgentStudioGitContracts
import CLibGit2Local
import Foundation

func initializeWorktreeAddOptions(_ options: inout git_worktree_add_options) throws {
    let initResult = git_worktree_add_options_init(&options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))
    guard initResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: initResult)
    }
}

func initializeWorktreePruneOptions(_ options: inout git_worktree_prune_options) throws {
    let initResult = git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
    guard initResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: initResult)
    }
}

func resolveCommit(_ target: GitRevisionTarget, repository: OpaquePointer) throws
    -> OpaquePointer
{
    var object: OpaquePointer?
    let revparseResult = target.name.withCString { targetPointer in
        git_revparse_single(&object, repository, targetPointer)
    }
    guard revparseResult >= 0, let object else {
        throw LibGit2ErrorCapture.failure(code: revparseResult)
    }
    defer { git_object_free(object) }

    var commit: OpaquePointer?
    let peelResult = git_object_peel(&commit, object, GIT_OBJECT_COMMIT)
    guard peelResult >= 0, let commit else {
        throw LibGit2ErrorCapture.failure(code: peelResult)
    }
    return commit
}

struct WorktreeCreateDetachedAdd {
    let name: String
    let destination: URL
    /// The pinned commit the worktree is checked out at.
    let start: String
}

/// Registers the worktree and checks out `start` detached, creating no branch the caller asked for.
/// `git_worktree_add` needs a branch (without one it creates a branch named after the worktree), so a call-owned
/// carrier branch at `start` registers the worktree and is deleted once `HEAD` is detached.
func addDetachedWorktree(
    _ add: WorktreeCreateDetachedAdd,
    repository: OpaquePointer,
    rollback: inout WorktreeCreateRollback
) throws {
    var startOID = try LibGit2PinnedCommit.objectID(add.start, label: "start")
    var commit: OpaquePointer?
    let lookupResult = git_commit_lookup(&commit, repository, &startOID)
    guard lookupResult >= 0, let commit else {
        throw LibGit2ErrorCapture.failure(code: lookupResult)
    }
    defer { git_commit_free(commit) }

    let carrierName = "agentstudio-checkout-carrier-\(UUID().uuidString.lowercased())"
    var carrier: OpaquePointer?
    let createResult = carrierName.withCString { git_branch_create(&carrier, repository, $0, commit, 0) }
    guard createResult >= 0, let carrier else {
        throw LibGit2ErrorCapture.failure(code: createResult)
    }
    defer { git_reference_free(carrier) }
    rollback.createdBranchName = carrierName

    var addOptions = git_worktree_add_options()
    try initializeWorktreeAddOptions(&addOptions)
    addOptions.ref = carrier
    var worktree: OpaquePointer?
    let addResult = add.name.withCString { namePointer in
        add.destination.path.withCString { git_worktree_add(&worktree, repository, namePointer, $0, &addOptions) }
    }
    defer {
        if let worktree {
            git_worktree_free(worktree)
        }
    }
    guard addResult >= 0, let worktree else {
        throw LibGit2ErrorCapture.failure(code: addResult)
    }
    rollback.createdWorktree = true

    var worktreeRepository: OpaquePointer?
    let openResult = git_repository_open_from_worktree(&worktreeRepository, worktree)
    guard openResult >= 0, let worktreeRepository else {
        throw LibGit2ErrorCapture.failure(code: openResult)
    }
    defer { git_repository_free(worktreeRepository) }
    let detachResult = git_repository_set_head_detached(worktreeRepository, &startOID)
    guard detachResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: detachResult)
    }
    let deleteResult = git_branch_delete(carrier)
    guard deleteResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: deleteResult)
    }
    rollback.createdBranchName = nil
}
