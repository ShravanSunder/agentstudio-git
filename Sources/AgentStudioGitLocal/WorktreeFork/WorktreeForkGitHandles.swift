import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct WorktreeForkTreeEntry: Equatable, Sendable {
    let oid: String
    let mode: UInt32
}

/// libgit2 operations the fork transaction performs on root Git identity. Each call maps a libgit2 failure
/// into the fork error union; handles never outlive the serial transaction queue.
enum WorktreeForkGitHandles {
    static func openWorktree(_ path: URL) throws(GitWorktreeForkError) -> OpaquePointer {
        var repository: OpaquePointer?
        let openResult = path.path.withCString {
            git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let repository else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        return repository
    }

    static func lookupCommit(_ oidString: String, repository: OpaquePointer) throws(GitWorktreeForkError)
        -> OpaquePointer
    {
        guard var oid = WorktreeForkObjectID.parse(oidString) else {
            throw .gitFailure(.requiredObjectNotFound(oid: oidString))
        }
        var commit: OpaquePointer?
        let lookupResult = git_commit_lookup(&commit, repository, &oid)
        guard lookupResult >= 0, let commit else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        return commit
    }

    /// Creates a local branch at the captured commit; fails rather than moving an existing branch.
    static func createBranch(
        shortName: String,
        commitOID: String,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        let commit = try lookupCommit(commitOID, repository: repository)
        defer { git_commit_free(commit) }
        var reference: OpaquePointer?
        let createResult = shortName.withCString { git_branch_create(&reference, repository, $0, commit, 0) }
        if let reference {
            git_reference_free(reference)
        }
        guard createResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: createResult))
        }
    }

    /// Registers the linked worktree without checking anything out: libgit2 creates the destination
    /// directory, its `.git` file, and the administration, and `GIT_CHECKOUT_NONE` leaves the working tree
    /// empty for strict materialization.
    static func addWorktree(
        name: String,
        destination: URL,
        branchReferenceName: String,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) {
        var options = git_worktree_add_options()
        do {
            try initializeWorktreeAddOptions(&options)
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        options.checkout_options.checkout_strategy = GIT_CHECKOUT_NONE.rawValue
        var reference: OpaquePointer?
        let lookupResult = branchReferenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        guard lookupResult >= 0, let reference else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_reference_free(reference) }
        options.ref = reference
        var worktree: OpaquePointer?
        let addResult = name.withCString { namePointer in
            destination.path.withCString { git_worktree_add(&worktree, repository, namePointer, $0, &options) }
        }
        if let worktree {
            git_worktree_free(worktree)
        }
        guard addResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: addResult))
        }
    }

    static func detachHead(worktreePath: URL, commitOID: String) throws(GitWorktreeForkError) {
        let repository = try openWorktree(worktreePath)
        defer { git_repository_free(repository) }
        guard var oid = WorktreeForkObjectID.parse(commitOID) else {
            throw .gitFailure(.requiredObjectNotFound(oid: commitOID))
        }
        let detachResult = git_repository_set_head_detached(repository, &oid)
        guard detachResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: detachResult))
        }
    }

    static func deleteBranch(referenceName: String, repository: OpaquePointer) throws(GitWorktreeForkError) {
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        guard lookupResult >= 0, let reference else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_reference_free(reference) }
        let deleteResult = git_branch_delete(reference)
        guard deleteResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: deleteResult))
        }
    }

    /// Every blob, symlink, and gitlink path of a tree with its object ID and mode.
    static func treeEntries(
        _ treeOIDString: String,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> [String: WorktreeForkTreeEntry] {
        guard let treeOID = WorktreeForkObjectID.parse(treeOIDString) else {
            throw .gitFailure(.requiredObjectNotFound(oid: treeOIDString))
        }
        var entries: [String: WorktreeForkTreeEntry] = [:]
        var pendingTrees: [(prefix: String, oid: git_oid)] = [("", treeOID)]
        while let (prefix, pendingOID) = pendingTrees.popLast() {
            var oid = pendingOID
            var tree: OpaquePointer?
            let lookupResult = git_tree_lookup(&tree, repository, &oid)
            guard lookupResult >= 0, let tree else {
                throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
            }
            defer { git_tree_free(tree) }
            for position in 0..<git_tree_entrycount(tree) {
                guard let entry = git_tree_entry_byindex(tree, position), let namePointer = git_tree_entry_name(entry),
                    let entryOID = git_tree_entry_id(entry)
                else {
                    continue
                }
                let path = prefix.isEmpty ? String(cString: namePointer) : "\(prefix)/\(String(cString: namePointer))"
                let mode = UInt32(git_tree_entry_filemode(entry).rawValue)
                if mode == UInt32(GIT_FILEMODE_TREE.rawValue) {
                    pendingTrees.append((path, entryOID.pointee))
                } else {
                    entries[path] = WorktreeForkTreeEntry(oid: oidString(entryOID), mode: mode)
                }
            }
        }
        return entries
    }
}
