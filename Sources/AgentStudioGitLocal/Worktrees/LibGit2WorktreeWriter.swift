import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2WorktreeWriter: Sendable {
    private let runtime: LibGit2Runtime
    private let reader: LibGit2WorktreeReader

    init(runtime: LibGit2Runtime = .shared, reader: LibGit2WorktreeReader = LibGit2WorktreeReader()) {
        self.runtime = runtime
        self.reader = reader
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) throws
        -> GitWorktreeSnapshot
    {
        let worktreeName = request.destinationPath.lastPathComponent
        guard !worktreeName.isEmpty else {
            throw GitDataPlaneError.unsupported(message: "worktree destination must have a final path component")
        }

        var rollback = WorktreeCreateRollback(
            repositoryPath: request.repositoryPath,
            worktreeName: worktreeName
        )
        do {
            var createdWorktree: OpaquePointer?
            try withRepository(at: request.repositoryPath) { repository in
                defer {
                    if let createdWorktree {
                        git_worktree_free(createdWorktree)
                    }
                }
                var addOptions = git_worktree_add_options()
                try initializeWorktreeAddOptions(&addOptions)
                var referenceToFree: OpaquePointer?
                var commitObjectToFree: OpaquePointer?
                defer {
                    if let referenceToFree {
                        git_reference_free(referenceToFree)
                    }
                    if let commitObjectToFree {
                        git_object_free(commitObjectToFree)
                    }
                }

                let detachedObjectID: UnsafePointer<git_oid>?
                switch request.mode {
                case .existingBranch(let name):
                    referenceToFree = try lookupBranchReference(named: name, repository: repository)
                    addOptions.ref = referenceToFree
                    detachedObjectID = nil
                case .newBranch(let name, let startPoint):
                    let commitObject = try resolveCommit(startPoint, repository: repository)
                    commitObjectToFree = commitObject
                    referenceToFree = try createBranchReference(
                        named: name, commit: commitObject, repository: repository)
                    rollback.createdBranchName = name
                    addOptions.ref = referenceToFree
                    detachedObjectID = nil
                case .detached(let startPoint):
                    let commitObject = try resolveCommit(startPoint, repository: repository)
                    commitObjectToFree = commitObject
                    detachedObjectID = git_object_id(commitObject)
                }

                let addResult = worktreeName.withCString { namePointer in
                    request.destinationPath.path.withCString { pathPointer in
                        git_worktree_add(&createdWorktree, repository, namePointer, pathPointer, &addOptions)
                    }
                }
                guard addResult >= 0, createdWorktree != nil else {
                    throw LibGit2ErrorCapture.failure(code: addResult)
                }
                rollback.createdWorktree = true

                if let detachedObjectID, let createdWorktree {
                    try detach(createdWorktree, oid: detachedObjectID)
                }
            }

            let validation = try reader.validateWorktree(
                GitValidateWorktreeRequest(worktreePath: request.destinationPath))
            guard let snapshot = validation.snapshot, validation.isValid else {
                throw GitDataPlaneError.repositoryNotFound(path: request.destinationPath)
            }
            rollback.disarm()
            return snapshot
        } catch {
            rollback.rollback(runtime: runtime)
            throw error
        }
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
            if pruneResult >= 0 {
                return GitWorktreeRemovalResult(
                    removedWorktreeID: resolvedRequest.worktreeID,
                    removedWorkingDirectory: request.removeWorkingDirectory,
                    partialFailure: nil
                )
            }

            if !metadataStillExists(worktreeID: resolvedRequest.worktreeID) {
                return GitWorktreeRemovalResult(
                    removedWorktreeID: resolvedRequest.worktreeID,
                    removedWorkingDirectory: !FileManager.default.fileExists(atPath: snapshot.canonicalPath.path),
                    partialFailure: LibGit2ErrorCapture.capture(code: pruneResult).message
                )
            }

            throw LibGit2ErrorCapture.failure(code: pruneResult)
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
