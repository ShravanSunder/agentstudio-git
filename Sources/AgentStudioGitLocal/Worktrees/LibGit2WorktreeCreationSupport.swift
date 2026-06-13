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

func lookupBranchReference(named name: String, repository: OpaquePointer) throws
    -> OpaquePointer
{
    var reference: OpaquePointer?
    let lookupResult = name.withCString { namePointer in
        git_branch_lookup(&reference, repository, namePointer, GIT_BRANCH_LOCAL)
    }
    guard lookupResult >= 0, let reference else {
        throw LibGit2ErrorCapture.failure(code: lookupResult)
    }
    return reference
}

func createBranchReference(
    named name: String,
    commit: OpaquePointer,
    repository: OpaquePointer
) throws -> OpaquePointer {
    var reference: OpaquePointer?
    let createResult = name.withCString { namePointer in
        git_branch_create(&reference, repository, namePointer, commit, 0)
    }
    guard createResult >= 0, let reference else {
        throw LibGit2ErrorCapture.failure(code: createResult)
    }
    return reference
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

func detach(_ worktree: OpaquePointer, oid: UnsafePointer<git_oid>) throws {
    var repository: OpaquePointer?
    let openResult = git_repository_open_from_worktree(&repository, worktree)
    guard openResult >= 0, let repository else {
        throw LibGit2ErrorCapture.failure(code: openResult)
    }
    defer { git_repository_free(repository) }

    let detachResult = git_repository_set_head_detached(repository, oid)
    guard detachResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: detachResult)
    }

    var checkoutOptions = git_checkout_options()
    let checkoutInitResult = git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
    guard checkoutInitResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: checkoutInitResult)
    }
    checkoutOptions.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
    let checkoutResult = git_checkout_head(repository, &checkoutOptions)
    guard checkoutResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: checkoutResult)
    }
}
