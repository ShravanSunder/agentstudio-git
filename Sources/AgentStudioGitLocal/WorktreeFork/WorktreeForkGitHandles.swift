import AgentStudioGitContracts
import CLibGit2Local
import Darwin
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
        referenceName: String,
        commitOID: String,
        repository: OpaquePointer,
        faults: WorktreeForkFaultInjector,
        lockTracker: WorktreeForkLockTracker,
        onCreated: () -> Void
    ) throws(GitWorktreeForkError) {
        let referenceLockFact = try lockFact(for: .reference(name: referenceName), repository: repository)
        lockTracker.beginAttempt(for: [referenceLockFact])

        guard var commitOIDValue = WorktreeForkObjectID.parse(commitOID) else {
            throw .gitFailure(.requiredObjectNotFound(oid: commitOID))
        }

        var transaction: OpaquePointer?
        let transactionResult = git_transaction_new(&transaction, repository)
        guard transactionResult >= 0, let transactionHandle = transaction else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: transactionResult))
        }
        defer {
            if let transaction {
                git_transaction_free(transaction)
            }
        }

        errno = 0
        let lockResult = referenceName.withCString { git_transaction_lock_ref(transactionHandle, $0) }
        let lockErrorNumber = errno
        guard lockResult >= 0 else {
            lockTracker.recordFailure(for: [referenceLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: lockResult,
                    lockFacts: [referenceLockFact],
                    systemErrorCode: lockErrorNumber
                ))
        }
        lockTracker.recordAcquisition(of: referenceLockFact)
        try faults.reach(.afterBranchReferenceLockAcquired(referenceName: referenceName))

        var existingReference: OpaquePointer?
        let existingResult = referenceName.withCString { git_reference_lookup(&existingReference, repository, $0) }
        if let existingReference {
            git_reference_free(existingReference)
            throw .rejected(reason: .branchAlreadyExists)
        }
        guard existingResult == GIT_ENOTFOUND.rawValue else {
            lockTracker.recordFailure(for: [referenceLockFact])
            throw .gitFailure(LibGit2ErrorCapture.failure(code: existingResult))
        }

        let logMessage = "branch: Created from \(commitOID)"
        errno = 0
        let setTargetResult = referenceName.withCString { referencePointer in
            logMessage.withCString { messagePointer in
                withUnsafePointer(to: &commitOIDValue) { oidPointer in
                    git_transaction_set_target(
                        transactionHandle,
                        referencePointer,
                        oidPointer,
                        nil,
                        messagePointer
                    )
                }
            }
        }
        let setTargetErrorNumber = errno
        guard setTargetResult >= 0 else {
            lockTracker.recordFailure(for: [referenceLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: setTargetResult,
                    lockFacts: [referenceLockFact],
                    systemErrorCode: setTargetErrorNumber
                ))
        }

        errno = 0
        let commitResult = git_transaction_commit(transactionHandle)
        let commitErrorNumber = errno
        guard commitResult >= 0 else {
            if referencePointsTo(referenceName, commitOID: commitOID, repository: repository) {
                onCreated()
            }
            lockTracker.recordFailure(for: [referenceLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: commitResult,
                    lockFacts: [referenceLockFact],
                    systemErrorCode: commitErrorNumber
                ))
        }

        onCreated()
        git_transaction_free(transactionHandle)
        transaction = nil
    }

    /// Registers the linked worktree without checking anything out: libgit2 creates the destination
    /// directory, its `.git` file, and the administration, and `GIT_CHECKOUT_NONE` leaves the working tree
    /// empty for strict materialization.
    static func addWorktree(
        name: String,
        destination: URL,
        branchReferenceName: String,
        repository: OpaquePointer,
        lockTracker: WorktreeForkLockTracker
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

        guard let commonDirectory = git_repository_commondir(repository) else {
            throw .gitFailure(.unsupported(message: "repository common directory unavailable"))
        }
        let commonDirectoryPath = URL(fileURLWithPath: String(cString: commonDirectory), isDirectory: true)
        let worktreesDirectoryPath = commonDirectoryPath.appending(path: "worktrees")
        let administrationPath = worktreesDirectoryPath.appending(path: name)
        let headLockFact = GitLockFact(
            path: administrationPath.appending(path: "HEAD.lock").standardizedFileURL,
            resource: .reference(name: "HEAD")
        )
        lockTracker.beginAttempt(for: [headLockFact])
        var worktree: OpaquePointer?
        errno = 0
        let addResult = name.withCString { namePointer in
            destination.path.withCString { git_worktree_add(&worktree, repository, namePointer, $0, &options) }
        }
        let addErrorNumber = errno
        if let worktree {
            git_worktree_free(worktree)
        }
        guard addResult >= 0 else {
            lockTracker.recordFailure(for: [headLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: addResult,
                    lockFacts: [headLockFact],
                    systemErrorCode: addErrorNumber,
                    permissionDirectories: [
                        destination.deletingLastPathComponent(),
                        administrationPath,
                        worktreesDirectoryPath,
                        commonDirectoryPath,
                    ]
                ))
        }
    }

    /// Checks out the captured commit into the transaction-owned empty destination. The commit tree is
    /// explicit so a concurrent source HEAD move cannot change what the destination receives.
    static func checkoutCapturedHead(
        _ commitOID: String,
        repository: OpaquePointer,
        worktreePath: URL,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) {
        let commit = try lookupCommit(commitOID, repository: repository)
        defer { git_commit_free(commit) }
        let indexLockFact = try lockFact(for: .index(worktreePath: worktreePath), repository: repository)
        lockTracker.beginAttempt(for: [indexLockFact])
        var options = git_checkout_options()
        let optionsResult = git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        guard optionsResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: optionsResult))
        }
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        errno = 0
        let checkoutResult = git_checkout_tree(repository, commit, &options)
        let checkoutErrorNumber = errno
        guard checkoutResult >= 0 else {
            lockTracker.recordFailure(for: [indexLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: checkoutResult,
                    lockFacts: [indexLockFact],
                    systemErrorCode: checkoutErrorNumber
                ))
        }
    }

    static func detachHead(
        worktreePath: URL,
        commitOID: String,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) {
        let repository = try openWorktree(worktreePath)
        defer { git_repository_free(repository) }
        guard var oid = WorktreeForkObjectID.parse(commitOID) else {
            throw .gitFailure(.requiredObjectNotFound(oid: commitOID))
        }
        let headLockFact = try lockFact(for: .reference(name: "HEAD"), repository: repository)
        lockTracker.beginAttempt(for: [headLockFact])
        errno = 0
        let detachResult = git_repository_set_head_detached(repository, &oid)
        let detachErrorNumber = errno
        guard detachResult >= 0 else {
            lockTracker.recordFailure(for: [headLockFact])
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: detachResult,
                    lockFacts: [headLockFact],
                    systemErrorCode: detachErrorNumber
                ))
        }
    }

    static func deleteBranch(
        referenceName: String,
        repository: OpaquePointer,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) {
        let referenceLockFact = try lockFact(for: .reference(name: referenceName), repository: repository)
        let configurationLockFact = try lockFact(for: .config, repository: repository)
        let lockFacts = [configurationLockFact, referenceLockFact]
        lockTracker.beginAttempt(for: lockFacts)
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        guard lookupResult >= 0, let reference else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_reference_free(reference) }
        errno = 0
        let deleteResult = git_branch_delete(reference)
        let deleteErrorNumber = errno
        guard deleteResult >= 0 else {
            lockTracker.recordFailure(for: lockFacts)
            throw .gitFailure(
                LibGit2ErrorCapture.failure(
                    code: deleteResult,
                    lockFacts: lockFacts,
                    systemErrorCode: deleteErrorNumber
                ))
        }
    }

    static func lockFact(for resource: GitLockResource, repository: OpaquePointer) throws(GitWorktreeForkError)
        -> GitLockFact
    {
        do {
            return try LibGit2LockPathResolver.fact(for: resource, repository: repository)
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
    }

    private static func referencePointsTo(
        _ referenceName: String,
        commitOID: String,
        repository: OpaquePointer
    ) -> Bool {
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        guard lookupResult >= 0, let reference else {
            return false
        }
        defer { git_reference_free(reference) }
        guard let target = git_reference_target(reference) else {
            return false
        }
        return oidString(target) == commitOID
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
