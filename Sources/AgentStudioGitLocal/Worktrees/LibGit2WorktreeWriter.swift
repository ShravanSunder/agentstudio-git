import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2WorktreeWriter: Sendable {
    private let runtime: LibGit2Runtime
    private let reader: LibGit2WorktreeReader
    private let removalPathObserver: GitWorktreeRemovalPathObserver
    private let largeFileStoreFill: LibGit2LargeFileStoreFill
    private let createFaults: WorktreeCreateFaultInjector

    init(
        runtime: LibGit2Runtime = .shared,
        reader: LibGit2WorktreeReader = LibGit2WorktreeReader(),
        removalPathObserver: GitWorktreeRemovalPathObserver = .live,
        largeFileStoreFill: LibGit2LargeFileStoreFill = LibGit2LargeFileStoreFill(),
        createFaults: WorktreeCreateFaultInjector = .production
    ) {
        self.runtime = runtime
        self.reader = reader
        self.removalPathObserver = removalPathObserver
        self.largeFileStoreFill = largeFileStoreFill
        self.createFaults = createFaults
    }

    /// Plans the branch target, registers and checks out the worktree detached at the pinned start, validates it,
    /// and only then attaches the branch; the attach and a new branch's upstream write after it are the last steps
    /// that can fail. The attach's commit can fail after its ref landed, so the ref is re-read after a commit error:
    /// rollback removes a new branch that landed and moves a landed fast-forward back under the ref lock, re-reading
    /// it after its own commit. If that re-read confirms this call's own undo, the call's own error stands; otherwise
    /// the call fails with `branchMoveNotUndone`, naming the branch and both commits. A branch another writer moved,
    /// even back to its expected tip, is reported that way and left alone. The LFS fill after the attach never
    /// throws.
    func createWorktree(_ request: GitCreateWorktreeRequest) throws
        -> GitWorktreeCreation
    {
        let worktreeName = request.destinationPath.lastPathComponent
        guard !worktreeName.isEmpty else {
            throw GitDataPlaneError.unsupported(message: "worktree destination must have a final path component")
        }

        var rollback = WorktreeCreateRollback(
            repositoryPath: request.repositoryPath,
            worktreeName: worktreeName
        )
        let branchAttach = LibGit2WorktreeCreateBranchAttach(repositoryPath: request.repositoryPath)
        let snapshot: GitWorktreeSnapshot
        do {
            let target = try withRepository(at: request.repositoryPath) { repository in
                let target = try branchAttach.plan(request.mode, repository: repository)
                try addDetachedWorktree(
                    WorktreeCreateDetachedAdd(
                        name: worktreeName, destination: request.destinationPath, start: target.start),
                    repository: repository,
                    rollback: &rollback
                )
                return target
            }
            let validation = try reader.validateWorktree(
                GitValidateWorktreeRequest(worktreePath: request.destinationPath))
            guard let detachedSnapshot = validation.snapshot, validation.isValid else {
                throw GitDataPlaneError.repositoryNotFound(path: request.destinationPath)
            }
            try createFaults.reach(.beforeBranchAttach)
            try withRepository(at: request.destinationPath) { destination in
                try branchAttach.attach(target, destination: destination, rollback: &rollback)
                if target.attach != nil {
                    try createFaults.reach(.afterBranchAttached)
                }
                try branchAttach.writeUpstream(target, destination: destination)
            }
            rollback.disarm()
            snapshot = target.attachedSnapshot(detachedSnapshot)
        } catch {
            if let moveNotUndone = rollback.rollback(runtime: runtime, faults: createFaults) {
                throw moveNotUndone
            }
            throw error
        }

        let largeFiles = largeFileStoreFill.fill(worktreePath: snapshot.canonicalPath)
        return GitWorktreeCreation(worktree: snapshot, largeFiles: largeFiles)
    }

    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) throws
        -> GitWorktreePruneResult
    {
        let repositoryPath = request.repositoryPath
        let worktreeID = request.worktreeID
        return try withLocatedLinkedWorktree(repositoryPath: repositoryPath, worktreeID: worktreeID) { worktree, _ in
            var options = git_worktree_prune_options()
            try initializeWorktreePruneOptions(&options)
            let prunableResult = git_worktree_is_prunable(worktree, &options)
            guard prunableResult > 0 else {
                if prunableResult == 0 {
                    let lockState = try worktreeLockState(worktree)
                    if lockState.isLocked {
                        throw GitDataPlaneError.locked(message: lockState.reason ?? "worktree is locked")
                    }
                    throw GitDataPlaneError.worktreeNotPrunable(id: worktreeID, reason: .liveWorktree)
                }
                throw LibGit2ErrorCapture.failure(code: prunableResult)
            }

            let pruneResult = git_worktree_prune(worktree, &options)
            guard pruneResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: pruneResult)
            }
            return GitWorktreePruneResult(prunedWorktreeID: worktreeID)
        }
    }

    func removeWorktree(_ request: GitRemoveWorktreeRequest) throws
        -> GitWorktreeRemovalResult
    {
        let resolvedRequest = try resolveRemovalRequest(request)
        return try withLocatedLinkedWorktree(
            repositoryPath: resolvedRequest.repositoryPath,
            worktreeID: resolvedRequest.worktreeID
        ) { worktree, snapshot in
            if let canonicalPath = request.canonicalPath,
                GitPathCanonicalizer.canonicalURL(for: canonicalPath) != snapshot.canonicalPath
            {
                throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .pathMismatch)
            }

            let lockState = try worktreeLockState(worktree)
            guard !lockState.isLocked else {
                throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .locked)
            }

            if !request.forceDiscardChanges {
                let dirtiness = try worktreeDirtiness(at: snapshot.canonicalPath)
                if dirtiness.hasStagedChanges {
                    throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .stagedChanges)
                }
                if dirtiness.hasDirtyTrackedChanges {
                    throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .dirtyTrackedChanges)
                }
                if dirtiness.hasUntrackedFiles {
                    throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .untrackedFiles)
                }
            }

            var options = git_worktree_prune_options()
            try initializeWorktreePruneOptions(&options)
            options.flags = GIT_WORKTREE_PRUNE_VALID.rawValue
            if request.removeWorkingDirectory {
                options.flags |= GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue
            }

            let pruneResult = git_worktree_prune(worktree, &options)
            let pruneFailure = pruneResult < 0 ? LibGit2ErrorCapture.capture(code: pruneResult) : nil
            let administrationPathStatus = removalPathObserver.status(of: snapshot.gitDirectory)
            let workingDirectoryPathStatus = removalPathObserver.status(of: snapshot.canonicalPath)
            let administration = administrationRemovalEffect(
                pathStatus: administrationPathStatus,
                pruneFailed: pruneFailure != nil
            )
            let workingDirectory = workingDirectoryRemovalEffect(
                pathStatus: workingDirectoryPathStatus,
                removeRequested: request.removeWorkingDirectory,
                administration: administration,
                pruneFailed: pruneFailure != nil
            )
            let failure: GitWorktreeRemovalFailureKind?
            if let pruneFailure {
                failure = .pruneFailed(code: pruneFailure.code, klass: pruneFailure.klass)
            } else if administrationPathStatus == .inaccessible
                || (request.removeWorkingDirectory && workingDirectoryPathStatus == .inaccessible)
            {
                failure = .observationFailed
            } else if administration != .removed
                || (request.removeWorkingDirectory && workingDirectory != .removed)
            {
                failure = .removalIncomplete
            } else {
                failure = nil
            }

            return GitWorktreeRemovalResult(
                removedWorktreeID: resolvedRequest.worktreeID,
                effects: GitWorktreeRemovalEffects(
                    administration: administration,
                    workingDirectory: workingDirectory,
                    failure: failure,
                    lockResidue: []
                )
            )
        }
    }

    func lockWorktree(_ request: GitLockWorktreeRequest) throws -> GitWorktreeSnapshot {
        try withLocatedLinkedWorktree(worktreeID: request.worktreeID) { worktree, snapshot in
            let lockResult = request.reason.withOptionalCString { reasonPointer in
                git_worktree_lock(worktree, reasonPointer)
            }
            guard lockResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: lockResult)
            }
            return try reader.snapshotForWorktreeID(snapshot.id)
        }
    }

    func unlockWorktree(_ request: GitUnlockWorktreeRequest) throws -> GitWorktreeSnapshot {
        try withLocatedLinkedWorktree(worktreeID: request.worktreeID) { worktree, snapshot in
            let unlockResult = git_worktree_unlock(worktree)
            guard unlockResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: unlockResult)
            }
            return try reader.snapshotForWorktreeID(snapshot.id)
        }
    }

    private func resolveRemovalRequest(_ request: GitRemoveWorktreeRequest) throws
        -> ResolvedWorktreeRemovalRequest
    {
        if let worktreeID = request.worktreeID {
            guard let parsedID = LibGit2WorktreeIDParser.parse(worktreeID) else {
                throw GitDataPlaneError.worktreeNotFound(id: worktreeID)
            }
            if parsedID.canonicalPath == parsedID.mainWorktreePath {
                throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .mainWorktree)
            }
            return ResolvedWorktreeRemovalRequest(
                repositoryPath: parsedID.mainWorktreePath,
                worktreeID: worktreeID
            )
        }

        guard let canonicalPath = request.canonicalPath else {
            throw GitDataPlaneError.unsupported(message: "removeWorktree requires a worktree id or canonical path")
        }
        let snapshot = try reader.validateWorktree(GitValidateWorktreeRequest(worktreePath: canonicalPath)).snapshot
        guard let snapshot else {
            throw GitDataPlaneError.repositoryNotFound(path: canonicalPath)
        }
        guard !snapshot.isMainWorktree else {
            throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .mainWorktree)
        }
        guard let parsedID = LibGit2WorktreeIDParser.parse(snapshot.id) else {
            throw GitDataPlaneError.worktreeNotFound(id: snapshot.id)
        }
        return ResolvedWorktreeRemovalRequest(repositoryPath: parsedID.mainWorktreePath, worktreeID: snapshot.id)
    }

    private func withLocatedLinkedWorktree<ReturnValue>(
        worktreeID: GitWorktreeID,
        _ body: (OpaquePointer, GitWorktreeSnapshot) throws -> ReturnValue
    ) throws -> ReturnValue {
        guard let parsedID = LibGit2WorktreeIDParser.parse(worktreeID) else {
            throw GitDataPlaneError.worktreeNotFound(id: worktreeID)
        }
        return try withLocatedLinkedWorktree(
            repositoryPath: parsedID.mainWorktreePath,
            worktreeID: worktreeID,
            body
        )
    }

    private func withLocatedLinkedWorktree<ReturnValue>(
        repositoryPath: URL,
        worktreeID: GitWorktreeID,
        _ body: (OpaquePointer, GitWorktreeSnapshot) throws -> ReturnValue
    ) throws -> ReturnValue {
        try withRepository(at: repositoryPath) { repository in
            let mainWorktreePath = try mainWorktreePath(repository: repository)
            return try withRepository(at: mainWorktreePath) { mainRepository in
                let requestedParsedID = LibGit2WorktreeIDParser.parse(worktreeID)
                let mainSnapshot = try snapshotForMainWorktree(
                    repository: mainRepository,
                    requestedPath: mainWorktreePath
                )
                if mainSnapshot.id == worktreeID {
                    throw GitDataPlaneError.unsafeWorktreeRemoval(reason: .mainWorktree)
                }

                var worktreeNames = git_strarray()
                let listResult = git_worktree_list(&worktreeNames, mainRepository)
                guard listResult >= 0 else {
                    throw LibGit2ErrorCapture.failure(code: listResult)
                }
                defer { git_strarray_free(&worktreeNames) }

                for index in 0..<Int(worktreeNames.count) {
                    guard let namePointer = worktreeNames.strings[index] else {
                        continue
                    }
                    do {
                        var worktree: OpaquePointer?
                        let lookupResult = git_worktree_lookup(&worktree, mainRepository, namePointer)
                        guard lookupResult >= 0, let worktree else {
                            throw LibGit2ErrorCapture.failure(code: lookupResult)
                        }
                        defer { git_worktree_free(worktree) }

                        let currentSnapshot = try lightweightSnapshot(for: worktree, parentRepository: mainRepository)
                        if currentSnapshot.id == worktreeID || currentSnapshot.matches(parsedID: requestedParsedID) {
                            return try body(worktree, currentSnapshot)
                        }
                    }
                }

                throw GitDataPlaneError.worktreeNotFound(id: worktreeID)
            }
        }
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()
        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }
        return try body(repository)
    }
}
