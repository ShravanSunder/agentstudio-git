import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Fork-specific success evidence. Ordinary `validateWorktree` proves only that a worktree opens; this
/// checks the plan, the realized destination, the captured-HEAD index, and the refreshed stat data.
struct WorktreeForkValidator: Sendable {
    let reader: LibGit2WorktreeReader
    let cancellation: WorktreeForkCancellation
    let faults: WorktreeForkFaultInjector

    init(
        reader: LibGit2WorktreeReader,
        cancellation: WorktreeForkCancellation,
        faults: WorktreeForkFaultInjector = .production
    ) {
        self.reader = reader
        self.cancellation = cancellation
        self.faults = faults
    }

    func validate(
        plan: WorktreeForkPlan,
        observations: WorktreeForkMaterializationObservations,
        destinationRootDescriptor: Int32,
        indexEvidence: WorktreeForkIndexRefreshEvidence,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) -> GitWorktreeSnapshot {
        let snapshot = try validateRegistration(plan)
        try validateHead(plan)
        try validateCounts(plan.filesystem, observations)
        try validateDestinationTree(plan.filesystem, destinationRootDescriptor: destinationRootDescriptor)
        try WorktreeForkIndexValidation.validate(
            worktreePath: plan.destinationRoot,
            treeOID: plan.capturedHead.treeOID,
            expectedSkipWorktree: plan.gitTopology.rootSparse?.skipWorktreePaths ?? [],
            evidence: indexEvidence,
            reportPrefix: ""
        )
        try validateNoTransactionArtifacts(plan, lockTracker: lockTracker)
        return snapshot
    }

    func validateChangesOnly(
        plan: WorktreeForkPlan,
        changesOnly: WorktreeForkChangesOnlyPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32,
        indexEvidence: WorktreeForkIndexRefreshEvidence,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) -> GitWorktreeSnapshot {
        let snapshot = try validateRegistration(plan)
        try validateHead(plan)
        let sourceRepository = try WorktreeForkGitHandles.openWorktree(plan.sourceRoot)
        defer { git_repository_free(sourceRepository) }
        let gitSnapshotReader = WorktreeForkChangesOnlyGitSnapshotReader(cancellation: cancellation)
        let currentRepositoryState = try gitSnapshotReader.repositoryState(
            sourceRepository, expectedHead: plan.capturedHead.commitOID)
        guard currentRepositoryState == changesOnly.repositoryState else {
            throw .sourceChanged(relativePath: ".", reason: .repositoryStateChanged)
        }

        let planner = WorktreeForkChangesOnlyPlanner(cancellation: cancellation)
        for entry in changesOnly.entries {
            let sourceNode = try planner.capture(entry.relativePath, rootDescriptor: sourceRootDescriptor)
            try validateSourceEntry(entry, current: sourceNode)
            if entry.shouldOverlay {
                let destinationNode = try planner.capture(entry.relativePath, rootDescriptor: destinationRootDescriptor)
                try validateDestinationEntry(entry, current: destinationNode)
            }
        }
        for restoration in changesOnly.largeFileRestorations {
            let sourceNode = try planner.capture(restoration.relativePath, rootDescriptor: sourceRootDescriptor)
            guard sourceNode.kind == .regularFile,
                sourceNode.identity == restoration.identity,
                sourceNode.size == restoration.size,
                sourceNode.contentSHA256 == restoration.contentSHA256,
                sourceNode.mode & 0o777 == restoration.mode & 0o777
            else {
                throw .sourceChanged(relativePath: restoration.relativePath, reason: .contentChanged)
            }
            let destinationNode = try planner.capture(
                restoration.relativePath, rootDescriptor: destinationRootDescriptor)
            guard destinationNode.kind == .regularFile,
                destinationNode.size == restoration.size,
                destinationNode.contentSHA256 == restoration.contentSHA256,
                destinationNode.mode & 0o777 == restoration.mode & 0o777,
                destinationNode.identity != sourceNode.identity
            else {
                throw .validationFailed(reason: .entryKindMismatch, relativePath: restoration.relativePath)
            }
        }
        try faults.reach(.afterChangesOnlyContentRehash)
        let finalRepositoryState = try gitSnapshotReader.repositoryState(
            sourceRepository, expectedHead: plan.capturedHead.commitOID)
        guard finalRepositoryState == changesOnly.repositoryState else {
            throw .sourceChanged(relativePath: ".", reason: .repositoryStateChanged)
        }
        try WorktreeForkIndexValidation.validate(
            worktreePath: plan.destinationRoot,
            treeOID: plan.capturedHead.treeOID,
            expectedSkipWorktree: [],
            evidence: indexEvidence,
            reportPrefix: ""
        )
        try validateNoTransactionArtifacts(plan, lockTracker: lockTracker)
        return snapshot
    }

    private func validateSourceEntry(
        _ expected: WorktreeForkChangesOnlyEntry,
        current: WorktreeForkChangesOnlySourceNode
    ) throws(GitWorktreeForkError) {
        guard current.kind.publicKind == expected.kind else {
            throw .sourceChanged(relativePath: expected.relativePath, reason: .entryKindChanged)
        }
        guard current.identity == expected.identity else {
            throw .sourceChanged(relativePath: expected.relativePath, reason: .entryIdentityChanged)
        }
        switch expected.kind {
        case .directory:
            guard current.mode & 0o777 == expected.mode & 0o777 else {
                throw .sourceChanged(relativePath: expected.relativePath, reason: .contentChanged)
            }
        case .absent:
            return
        case .regularFile, .symbolicLink:
            guard current.mode & 0o777 == expected.mode & 0o777,
                current.size == expected.size,
                current.contentSHA256 == expected.contentSHA256,
                current.symbolicLinkText == expected.symbolicLinkText
            else {
                throw .sourceChanged(relativePath: expected.relativePath, reason: .contentChanged)
            }
        }
    }

    private func validateDestinationEntry(
        _ expected: WorktreeForkChangesOnlyEntry,
        current: WorktreeForkChangesOnlySourceNode
    ) throws(GitWorktreeForkError) {
        guard current.kind.publicKind == expected.kind else {
            throw .validationFailed(reason: .entryKindMismatch, relativePath: expected.relativePath)
        }
        switch expected.kind {
        case .absent:
            return
        case .directory:
            if expected.shouldOverlay,
                current.mode & 0o777 != expected.mode & 0o777 || current.identity == expected.identity
            {
                throw .validationFailed(reason: .entryKindMismatch, relativePath: expected.relativePath)
            }
        case .regularFile:
            guard current.size == expected.size,
                current.contentSHA256 == expected.contentSHA256,
                current.mode & 0o777 == expected.mode & 0o777,
                current.identity != expected.identity
            else {
                throw .validationFailed(reason: .entryKindMismatch, relativePath: expected.relativePath)
            }
        case .symbolicLink:
            guard current.symbolicLinkText == expected.symbolicLinkText,
                current.identity != expected.identity
            else {
                throw .validationFailed(reason: .entryKindMismatch, relativePath: expected.relativePath)
            }
        }
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
        try validateConfiguredWorktree(repository, plan: plan)
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

    /// The fork's effective `core.worktree`, from any configuration level, must be absent or the fork itself.
    private func validateConfiguredWorktree(
        _ repository: OpaquePointer,
        plan: WorktreeForkPlan
    ) throws(GitWorktreeForkError) {
        var configuration: OpaquePointer?
        guard git_repository_config_snapshot(&configuration, repository) >= 0, let configuration else {
            throw .validationFailed(reason: .worktreeRegistrationInvalid, relativePath: nil)
        }
        defer { git_config_free(configuration) }
        var value: UnsafePointer<CChar>?
        guard git_config_get_string(&value, configuration, "core.worktree") >= 0, let value else {
            return
        }
        let configured = String(cString: value)
        let administration = plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
        let resolved =
            configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : administration.appending(path: configured)
        guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(resolved),
            canonical.path == plan.destinationRoot.path
        else {
            throw .validationFailed(reason: .sourceAdministrationReference, relativePath: nil)
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
        let realized = try WorktreeForkSourceWalker(cancellation: cancellation)
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

    private func validateNoTransactionArtifacts(
        _ plan: WorktreeForkPlan,
        lockTracker: WorktreeForkLockTracker
    ) throws(GitWorktreeForkError) {
        let administration = plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
        var lockFacts = [
            GitLockFact(
                path: administration.appending(path: "index.lock").standardizedFileURL,
                resource: .index(worktreePath: plan.destinationRequestPath)
            ),
            GitLockFact(
                path: administration.appending(path: "HEAD.lock").standardizedFileURL,
                resource: .reference(name: "HEAD")
            ),
            GitLockFact(
                path: administration.appending(path: "config.worktree.lock").standardizedFileURL,
                resource: .config
            ),
        ]
        if let referenceName = plan.branchIdentity.referenceName {
            lockFacts.append(
                GitLockFact(
                    path: plan.commonDirectory.appending(path: "\(referenceName).lock").standardizedFileURL,
                    resource: .reference(name: referenceName)
                ))
        }
        lockTracker.beginAttempt(for: lockFacts)
        if let fact = lockTracker.activeLocks().first {
            throw .validationFailed(reason: .transactionArtifactRemains, relativePath: fact.path.lastPathComponent)
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

/// Checks one rebuilt index: exactly the captured tree's entries, the planned skip-worktree flags, and
/// refreshed stat data on every entry the refresh proved unchanged.
enum WorktreeForkIndexValidation {
    static func validate(
        worktreePath: URL,
        treeOID: String?,
        expectedSkipWorktree: Set<String>,
        evidence: WorktreeForkIndexRefreshEvidence,
        reportPrefix: String
    ) throws(GitWorktreeForkError) {
        let repository = try WorktreeForkGitHandles.openWorktree(worktreePath)
        defer { git_repository_free(repository) }
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) >= 0, let index, git_index_read(index, 1) >= 0 else {
            throw .validationFailed(reason: .indexTreeMismatch, relativePath: reportPrefix.isEmpty ? nil : reportPrefix)
        }
        defer { git_index_free(index) }

        let expectedEntries =
            try treeOID.map { oid throws(GitWorktreeForkError) in
                try WorktreeForkGitHandles.treeEntries(oid, repository: repository)
            } ?? [:]
        var indexedEntries: [String: WorktreeForkTreeEntry] = [:]
        var skipWorktree = Set<String>()
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position)?.pointee, let pathPointer = entry.path else {
                continue
            }
            var oid = entry.id
            let path = String(cString: pathPointer)
            indexedEntries[path] = WorktreeForkTreeEntry(oid: oidString(&oid), mode: entry.mode)
            let isSkipWorktree = entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0
            if isSkipWorktree {
                skipWorktree.insert(path)
            }
            let isGitlink = entry.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue)
            let hasStatData = entry.ino != 0 || entry.file_size != 0 || entry.mtime.seconds != 0
            if !hasStatData, !isSkipWorktree, !isGitlink, !evidence.unrefreshedPaths.contains(path) {
                throw .validationFailed(
                    reason: .indexStatNotRefreshed, relativePath: WorktreeForkDescriptors.joined(reportPrefix, path))
            }
        }
        guard indexedEntries == expectedEntries else {
            let mismatch = Set(indexedEntries.keys).symmetricDifference(expectedEntries.keys).min()
            throw .validationFailed(
                reason: .indexTreeMismatch,
                relativePath: mismatch.map { WorktreeForkDescriptors.joined(reportPrefix, $0) }
            )
        }
        guard skipWorktree == expectedSkipWorktree else {
            let mismatch = skipWorktree.symmetricDifference(expectedSkipWorktree).min()
            throw .validationFailed(
                reason: .sparseStateMismatch,
                relativePath: mismatch.map { WorktreeForkDescriptors.joined(reportPrefix, $0) }
            )
        }
    }
}
