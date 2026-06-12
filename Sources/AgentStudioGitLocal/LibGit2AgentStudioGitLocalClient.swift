import AgentStudioGitContracts
import CLibGit2Local
import Foundation

public struct LibGit2AgentStudioGitLocalClient: AgentStudioGitLocalClient {
    private let identityResolver: GitRepositoryIdentityResolver
    private let writerRegistry: GitRepositoryWriterRegistry
    private let worktreeReader: LibGit2WorktreeReader
    private let worktreeWriter: LibGit2WorktreeWriter

    public init() {
        self.init(
            identityResolver: GitRepositoryIdentityResolver(),
            writerRegistry: .shared,
            worktreeReader: LibGit2WorktreeReader(),
            worktreeWriter: LibGit2WorktreeWriter()
        )
    }

    init(
        identityResolver: GitRepositoryIdentityResolver = GitRepositoryIdentityResolver(),
        writerRegistry: GitRepositoryWriterRegistry = .shared,
        worktreeReader: LibGit2WorktreeReader = LibGit2WorktreeReader(),
        worktreeWriter: LibGit2WorktreeWriter = LibGit2WorktreeWriter()
    ) {
        self.identityResolver = identityResolver
        self.writerRegistry = writerRegistry
        self.worktreeReader = worktreeReader
        self.worktreeWriter = worktreeWriter
    }

    public func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        try mapIdentityResolutionError(path: worktreePath) {
            try identityResolver.identity(for: worktreePath)
        }
    }

    public func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        try mapSyncGitDataPlaneError {
            try worktreeReader.worktrees(for: repositoryPath)
        }
    }

    public func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        try mapSyncGitDataPlaneError {
            try worktreeReader.validateWorktree(request)
        }
    }

    public func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        let writer = try await writer(for: request.repositoryPath)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.createWorktree(request)
            }
        }
    }

    public func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        let writer = try await writer(for: request.repositoryPath)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.pruneStaleWorktree(request)
            }
        }
    }

    public func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    {
        let writer = try await writer(for: request)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.removeWorktree(request)
            }
        }
    }

    public func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        let writer = try await writer(for: request.worktreeID)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.lockWorktree(request)
            }
        }
    }

    public func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        let writer = try await writer(for: request.worktreeID)
        return try await mapAsyncGitDataPlaneError {
            try await writer.run {
                try worktreeWriter.unlockWorktree(request)
            }
        }
    }

    public func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitStatusSnapshot
    {
        throw .unsupported(message: "status is implemented in Task 6")
    }

    public func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw .unsupported(message: "branches are implemented in Task 6")
    }

    public func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
        -> GitResolvedRevision
    {
        throw .unsupported(message: "revision resolution is implemented in Task 7")
    }

    public func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        throw .unsupported(message: "tree reads are implemented in Task 7")
    }

    public func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        throw .unsupported(message: "diff is implemented in Task 7")
    }

    public func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        throw .unsupported(message: "content is implemented in Task 7")
    }

    private func writer(for repositoryPath: URL) async throws(GitDataPlaneError) -> GitRepositoryWriterLane {
        let identity = try mapIdentityResolutionError(path: repositoryPath) {
            let identity = try identityResolver.identity(for: repositoryPath)
            return identity
        }
        return await writerRegistry.writer(for: identity)
    }

    private func writer(for request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitRepositoryWriterLane
    {
        if let worktreeID = request.worktreeID {
            return try await writer(for: worktreeID)
        }
        guard let canonicalPath = request.canonicalPath else {
            throw .unsupported(message: "removeWorktree requires a worktree id or canonical path")
        }
        return try await writer(for: canonicalPath)
    }

    private func writer(for worktreeID: GitWorktreeID) async throws(GitDataPlaneError) -> GitRepositoryWriterLane {
        guard let parsedID = LibGit2WorktreeIDParser.parse(worktreeID) else {
            throw .worktreeNotFound(id: worktreeID)
        }
        let identity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:\(parsedID.commonDirectory.path)"),
            canonicalCommonDirectory: parsedID.commonDirectory,
            mainWorktreePath: parsedID.mainWorktreePath
        )
        return await writerRegistry.writer(for: identity)
    }

    private func mapSyncGitDataPlaneError<ReturnValue>(
        _ operation: () throws -> ReturnValue
    ) throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try operation()
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }

    private func mapAsyncGitDataPlaneError<ReturnValue>(
        _ operation: () async throws -> ReturnValue
    ) async throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try await operation()
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }

    private func mapIdentityResolutionError<ReturnValue>(
        path: URL,
        _ operation: () throws -> ReturnValue
    ) throws(GitDataPlaneError) -> ReturnValue {
        do {
            return try operation()
        } catch GitRepositoryIdentityResolverError.missingGitDirectory {
            throw .repositoryNotFound(path: path)
        } catch GitRepositoryIdentityResolverError.invalidGitFile(let gitFilePath) {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_EINVALID.rawValue,
                message: "invalid .git file: \(gitFilePath.path)"
            )
        } catch {
            throw .unsupported(message: String(describing: error))
        }
    }
}
