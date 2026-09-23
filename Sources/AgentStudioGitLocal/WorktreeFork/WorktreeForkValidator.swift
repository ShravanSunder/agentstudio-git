import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Fork-specific success evidence. Ordinary `validateWorktree` proves only that a worktree opens; this
/// checks the plan, the realized destination, the captured-HEAD index, and the refreshed stat data.
struct WorktreeForkValidator: Sendable {
    let reader: LibGit2WorktreeReader

    func validate(
        plan: WorktreeForkPlan,
        observations: WorktreeForkMaterializationObservations,
        destinationRootDescriptor: Int32,
        indexEvidence: WorktreeForkIndexRefreshEvidence
    ) throws(GitWorktreeForkError) -> GitWorktreeSnapshot {
        let snapshot = try validateRegistration(plan)
        try validateHead(plan)
        try validateCounts(plan.filesystem, observations)
        try validateDestinationTree(plan.filesystem, destinationRootDescriptor: destinationRootDescriptor)
        try validateIndex(
            worktreePath: plan.destinationRoot,
            treeOID: plan.capturedHead.treeOID,
            evidence: indexEvidence
        )
        try validateNoTransactionArtifacts(plan)
        return snapshot
    }

    private func validateRegistration(_ plan: WorktreeForkPlan) throws(GitWorktreeForkError) -> GitWorktreeSnapshot {
        let validation: GitWorktreeValidation
        do {
            validation = try reader.validateWorktree(
                GitValidateWorktreeRequest(worktreePath: plan.destinationRequestPath))
        } catch let error as GitDataPlaneError {
            throw .gitFailure(error)
        } catch {
            throw .gitFailure(.unsupported(message: String(describing: error)))
        }
        guard validation.isValid, let snapshot = validation.snapshot, !snapshot.isMainWorktree,
            case .success(let registeredRoot) = WorktreeForkDescriptors.realpathURL(snapshot.canonicalPath),
            registeredRoot.path == plan.destinationRoot.path
        else {
            throw .validationFailed(reason: .worktreeRegistrationInvalid, relativePath: nil)
        }
        return snapshot
    }

    private func validateHead(_ plan: WorktreeForkPlan) throws(GitWorktreeForkError) {
        let repository = try WorktreeForkGitHandles.openWorktree(plan.destinationRoot)
        defer { git_repository_free(repository) }
        var headOID = git_oid()
        guard git_reference_name_to_id(&headOID, repository, "HEAD") >= 0,
            oidString(&headOID) == plan.capturedHead.commitOID
        else {
            throw .validationFailed(reason: .headMismatch, relativePath: nil)
        }
        switch plan.branchIdentity {
        case .detached:
            guard git_repository_head_detached(repository) == 1 else {
                throw .validationFailed(reason: .branchMismatch, relativePath: nil)
            }
        case .existingBranch(let referenceName), .newBranch(let referenceName):
            var head: OpaquePointer?
            guard git_repository_head(&head, repository) >= 0, let head else {
                throw .validationFailed(reason: .branchMismatch, relativePath: nil)
            }
            defer { git_reference_free(head) }
            guard let name = git_reference_name(head), String(cString: name) == referenceName else {
                throw .validationFailed(reason: .branchMismatch, relativePath: nil)
            }
        }
    }

    private func validateCounts(
        _ filesystem: WorktreeForkFilesystemPlan,
        _ observations: WorktreeForkMaterializationObservations
    ) throws(GitWorktreeForkError) {
        guard observations.createdDirectoryCount == filesystem.createdDirectoryCount,
            observations.clonedRegularFileCount == filesystem.leafCount(of: .regularFile),
            observations.recreatedSymbolicLinkCount == filesystem.leafCount(of: .symbolicLink),
            observations.recreatedFIFOCount == filesystem.leafCount(of: .fifo),
            observations.preservedHardLinkCount == filesystem.hardLinkSecondaryCount
        else {
            throw .validationFailed(reason: .entryCountMismatch, relativePath: nil)
        }
    }

    /// Re-walks the destination and requires exactly the planned paths and kinds, hard-link groups sharing
    /// one destination inode, and regular files that are new inodes rather than the source's.
    private func validateDestinationTree(
        _ plan: WorktreeForkFilesystemPlan,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let realized = try WorktreeForkSourceWalker(cancellation: WorktreeForkCancellation())
            .walk(sourceRootDescriptor: destinationRootDescriptor)
        guard Self.pathKinds(of: realized) == Self.pathKinds(of: plan) else {
            let mismatch = Self.pathKinds(of: realized).symmetricDifference(Self.pathKinds(of: plan))
            throw .validationFailed(reason: .entryKindMismatch, relativePath: mismatch.map(\.path).min())
        }
        let realizedGroups = Set(realized.hardLinkGroups.map { [$0.primaryRelativePath] + $0.secondaryRelativePaths })
        for group in plan.hardLinkGroups
        where !realizedGroups.contains([group.primaryRelativePath] + group.secondaryRelativePaths) {
            throw .validationFailed(reason: .hardLinkGroupBroken, relativePath: group.primaryRelativePath)
        }
        let sourceIdentities = Set(plan.leafBatches.flatMap { $0.leaves.map(\.identity) })
        for leaf in realized.leafBatches.flatMap(\.leaves)
        where leaf.kind == .regularFile && sourceIdentities.contains(leaf.identity) {
            throw .validationFailed(reason: .entryKindMismatch, relativePath: leaf.relativePath)
        }
    }

    private func validateIndex(
        worktreePath: URL,
        treeOID: String,
        evidence: WorktreeForkIndexRefreshEvidence
    ) throws(GitWorktreeForkError) {
        let repository = try WorktreeForkGitHandles.openWorktree(worktreePath)
        defer { git_repository_free(repository) }
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) >= 0, let index, git_index_read(index, 1) >= 0 else {
            throw .validationFailed(reason: .indexTreeMismatch, relativePath: nil)
        }
        defer { git_index_free(index) }

        let expectedEntries = try WorktreeForkGitHandles.treeEntries(treeOID, repository: repository)
        var indexedEntries: [String: WorktreeForkTreeEntry] = [:]
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position)?.pointee, let pathPointer = entry.path else {
                continue
            }
            var oid = entry.id
            let path = String(cString: pathPointer)
            indexedEntries[path] = WorktreeForkTreeEntry(oid: oidString(&oid), mode: entry.mode)
            let isSkipWorktree = entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0
            let isGitlink = entry.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue)
            let hasStatData = entry.ino != 0 || entry.file_size != 0 || entry.mtime.seconds != 0
            if !hasStatData, !isSkipWorktree, !isGitlink, !evidence.unrefreshedPaths.contains(path) {
                throw .validationFailed(reason: .indexStatNotRefreshed, relativePath: path)
            }
        }
        guard indexedEntries == expectedEntries else {
            let mismatch = Set(indexedEntries.keys).symmetricDifference(expectedEntries.keys).min()
            throw .validationFailed(reason: .indexTreeMismatch, relativePath: mismatch)
        }
    }

    private func validateNoTransactionArtifacts(_ plan: WorktreeForkPlan) throws(GitWorktreeForkError) {
        let administration = plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
        var lockPaths = [administration.appending(path: "index.lock"), administration.appending(path: "HEAD.lock")]
        if let referenceName = plan.branchIdentity.referenceName {
            lockPaths.append(plan.commonDirectory.appending(path: "\(referenceName).lock"))
        }
        for lockPath in lockPaths {
            if case .success = WorktreeForkDescriptors.lstatPath(lockPath) {
                throw .validationFailed(reason: .transactionArtifactRemains, relativePath: lockPath.lastPathComponent)
            }
        }
    }

    private static func pathKinds(of plan: WorktreeForkFilesystemPlan) -> Set<WorktreeForkPathKind> {
        var pathKinds = Set(plan.directories.map { WorktreeForkPathKind(path: $0.relativePath, kind: "directory") })
        for leaf in plan.leafBatches.flatMap(\.leaves) {
            pathKinds.insert(WorktreeForkPathKind(path: leaf.relativePath, kind: "\(leaf.kind)"))
        }
        for path in plan.hardLinkGroups.flatMap(\.secondaryRelativePaths) {
            pathKinds.insert(WorktreeForkPathKind(path: path, kind: "\(WorktreeForkLeafKind.regularFile)"))
        }
        for path in plan.nestedGitEntryPaths {
            pathKinds.insert(WorktreeForkPathKind(path: path, kind: "git"))
        }
        return pathKinds
    }
}

private struct WorktreeForkPathKind: Hashable {
    let path: String
    let kind: String
}
