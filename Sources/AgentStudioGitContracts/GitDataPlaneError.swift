import Foundation

public enum GitDataPlaneError: Error, Codable, Equatable, Sendable {
    case repositoryNotFound(path: URL)
    case worktreeNotFound(id: GitWorktreeID)
    case locked(message: String)
    case worktreeNotPrunable(id: GitWorktreeID, reason: GitWorktreePruneRefusalReason)
    case unsafeWorktreeRemoval(reason: GitWorktreeRemovalRefusalReason)
    case contentTooLarge(path: String, sizeBytes: Int64, maxSizeBytes: Int64)
    case pathEscapesRepository(path: String)
    case processFailed(GitRemoteProcessFailure)
    case processTimedOut(GitRemoteProcessFailure)
    case libgit2Failure(code: Int32, klass: Int32, message: String)
    case unsupported(message: String)
}

public enum GitWorktreePruneRefusalReason: String, Codable, CaseIterable, Sendable {
    case liveWorktree
}

public enum GitWorktreeRemovalRefusalReason: String, Codable, CaseIterable, Sendable {
    case mainWorktree
    case dirtyTrackedChanges
    case stagedChanges
    case untrackedFiles
    case locked
    case ambiguousPath
    case pathMismatch
}

public struct GitRemoteProcessFailure: Codable, Equatable, Hashable, Sendable {
    public let executable: String
    public let redactedArguments: [String]
    public let exitCode: Int32
    public let redactedStderr: String

    public init(
        executable: String,
        redactedArguments: [String],
        exitCode: Int32,
        redactedStderr: String
    ) {
        self.executable = executable
        self.redactedArguments = redactedArguments
        self.exitCode = exitCode
        self.redactedStderr = redactedStderr
    }

    public static func redacting(
        executable: String,
        arguments: [String],
        exitCode: Int32,
        stderr: String
    ) -> Self {
        Self(
            executable: executable,
            redactedArguments: arguments.map(GitRedaction.redact),
            exitCode: exitCode,
            redactedStderr: GitRedaction.redact(stderr)
        )
    }
}
