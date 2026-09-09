import Foundation

public enum GitDataPlaneError: Error, Codable, Equatable, Sendable {
    case repositoryNotFound(path: URL)
    case worktreeNotFound(id: GitWorktreeID)
    case locked(message: String)
    case worktreeNotPrunable(id: GitWorktreeID, reason: GitWorktreePruneRefusalReason)
    case unsafeWorktreeRemoval(reason: GitWorktreeRemovalRefusalReason)
    case contentTooLarge(path: String, sizeBytes: Int64, maxSizeBytes: Int64)
    case pathEscapesRepository(path: String)
    case revisionUnavailable(target: GitRevisionTarget)
    case headUnavailable
    case requiredObjectNotFound(oid: String)
    case noSharedHistory(targetOID: String, headOID: String)
    case multipleBestMergeBases(targetOID: String, headOID: String, count: Int)
    case processFailed(GitRemoteProcessFailure)
    case processTimedOut(GitRemoteProcessFailure)
    case processCancelled(GitRemoteProcessFailure)
    case processOutputTooLarge(stream: GitProcessOutputStream, sizeBytes: Int64, maxSizeBytes: Int64)
    case remoteRefTransactionIndeterminate(message: String)
    case libgit2Failure(code: Int32, klass: Int32, message: String)
    case unsupported(message: String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case repositoryNotFound
        case worktreeNotFound
        case locked
        case worktreeNotPrunable
        case unsafeWorktreeRemoval
        case contentTooLarge
        case pathEscapesRepository
        case revisionUnavailable
        case headUnavailable
        case requiredObjectNotFound
        case noSharedHistory
        case multipleBestMergeBases
        case processFailed
        case processTimedOut
        case processCancelled
        case processOutputTooLarge
        case remoteRefTransactionIndeterminate
        case libgit2Failure
        case unsupported
    }

    private enum PayloadKeys: String, CodingKey {
        case path
        case id
        case message
        case reason
        case sizeBytes
        case maxSizeBytes
        case stream
        case code
        case klass
        case target
        case oid
        case targetOID
        case headOID
        case count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCases = CodingKeys.allCases.filter { container.contains($0) }
        guard decodedCases.count == 1 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "GitDataPlaneError payload must contain exactly one case"
                )
            )
        }
        if container.contains(.repositoryNotFound) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .repositoryNotFound)
            self = try .repositoryNotFound(path: payload.decode(URL.self, forKey: .path))
        } else if container.contains(.worktreeNotFound) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .worktreeNotFound)
            self = try .worktreeNotFound(id: payload.decode(GitWorktreeID.self, forKey: .id))
        } else if container.contains(.locked) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .locked)
            self = try .locked(message: payload.decode(String.self, forKey: .message))
        } else if container.contains(.worktreeNotPrunable) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .worktreeNotPrunable)
            self = try .worktreeNotPrunable(
                id: payload.decode(GitWorktreeID.self, forKey: .id),
                reason: payload.decode(GitWorktreePruneRefusalReason.self, forKey: .reason)
            )
        } else if container.contains(.unsafeWorktreeRemoval) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .unsafeWorktreeRemoval)
            self = try .unsafeWorktreeRemoval(
                reason: payload.decode(GitWorktreeRemovalRefusalReason.self, forKey: .reason)
            )
        } else if container.contains(.contentTooLarge) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .contentTooLarge)
            self = try .contentTooLarge(
                path: payload.decode(String.self, forKey: .path),
                sizeBytes: payload.decode(Int64.self, forKey: .sizeBytes),
                maxSizeBytes: payload.decode(Int64.self, forKey: .maxSizeBytes)
            )
        } else if container.contains(.pathEscapesRepository) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .pathEscapesRepository)
            self = try .pathEscapesRepository(path: payload.decode(String.self, forKey: .path))
        } else if container.contains(.revisionUnavailable) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .revisionUnavailable)
            self = try .revisionUnavailable(target: payload.decode(GitRevisionTarget.self, forKey: .target))
        } else if container.contains(.headUnavailable) {
            _ = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .headUnavailable)
            self = .headUnavailable
        } else if container.contains(.requiredObjectNotFound) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .requiredObjectNotFound)
            self = try .requiredObjectNotFound(oid: payload.decode(String.self, forKey: .oid))
        } else if container.contains(.noSharedHistory) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .noSharedHistory)
            self = try .noSharedHistory(
                targetOID: payload.decode(String.self, forKey: .targetOID),
                headOID: payload.decode(String.self, forKey: .headOID)
            )
        } else if container.contains(.multipleBestMergeBases) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .multipleBestMergeBases)
            self = try .multipleBestMergeBases(
                targetOID: payload.decode(String.self, forKey: .targetOID),
                headOID: payload.decode(String.self, forKey: .headOID),
                count: payload.decode(Int.self, forKey: .count)
            )
        } else if container.contains(.processFailed) {
            self = try .processFailed(container.decode(GitRemoteProcessFailure.self, forKey: .processFailed))
        } else if container.contains(.processTimedOut) {
            self = try .processTimedOut(container.decode(GitRemoteProcessFailure.self, forKey: .processTimedOut))
        } else if container.contains(.processCancelled) {
            self = try .processCancelled(container.decode(GitRemoteProcessFailure.self, forKey: .processCancelled))
        } else if container.contains(.processOutputTooLarge) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .processOutputTooLarge)
            self = try .processOutputTooLarge(
                stream: payload.decode(GitProcessOutputStream.self, forKey: .stream),
                sizeBytes: payload.decode(Int64.self, forKey: .sizeBytes),
                maxSizeBytes: payload.decode(Int64.self, forKey: .maxSizeBytes)
            )
        } else if container.contains(.remoteRefTransactionIndeterminate) {
            let payload = try container.nestedContainer(
                keyedBy: PayloadKeys.self,
                forKey: .remoteRefTransactionIndeterminate
            )
            self = try .remoteRefTransactionIndeterminate(
                message: payload.decode(String.self, forKey: .message)
            )
        } else if container.contains(.libgit2Failure) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .libgit2Failure)
            self = try .libgit2Failure(
                code: payload.decode(Int32.self, forKey: .code),
                klass: payload.decode(Int32.self, forKey: .klass),
                message: payload.decode(String.self, forKey: .message)
            )
        } else if container.contains(.unsupported) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .unsupported)
            self = try .unsupported(message: payload.decode(String.self, forKey: .message))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "Unknown GitDataPlaneError case")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repositoryNotFound(let path):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .repositoryNotFound)
            try payload.encode(path, forKey: .path)
        case .worktreeNotFound(let id):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .worktreeNotFound)
            try payload.encode(id, forKey: .id)
        case .locked(let message):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .locked)
            try payload.encode(message, forKey: .message)
        case .worktreeNotPrunable(let id, let reason):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .worktreeNotPrunable)
            try payload.encode(id, forKey: .id)
            try payload.encode(reason, forKey: .reason)
        case .unsafeWorktreeRemoval(let reason):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .unsafeWorktreeRemoval)
            try payload.encode(reason, forKey: .reason)
        case .contentTooLarge(let path, let sizeBytes, let maxSizeBytes):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .contentTooLarge)
            try payload.encode(path, forKey: .path)
            try payload.encode(sizeBytes, forKey: .sizeBytes)
            try payload.encode(maxSizeBytes, forKey: .maxSizeBytes)
        case .pathEscapesRepository(let path):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .pathEscapesRepository)
            try payload.encode(path, forKey: .path)
        case .revisionUnavailable(let target):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .revisionUnavailable)
            try payload.encode(target, forKey: .target)
        case .headUnavailable:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .headUnavailable)
        case .requiredObjectNotFound(let oid):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .requiredObjectNotFound)
            try payload.encode(oid, forKey: .oid)
        case .noSharedHistory(let targetOID, let headOID):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .noSharedHistory)
            try payload.encode(targetOID, forKey: .targetOID)
            try payload.encode(headOID, forKey: .headOID)
        case .multipleBestMergeBases(let targetOID, let headOID, let count):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .multipleBestMergeBases)
            try payload.encode(targetOID, forKey: .targetOID)
            try payload.encode(headOID, forKey: .headOID)
            try payload.encode(count, forKey: .count)
        case .processFailed(let failure):
            try container.encode(failure, forKey: .processFailed)
        case .processTimedOut(let failure):
            try container.encode(failure, forKey: .processTimedOut)
        case .processCancelled(let failure):
            try container.encode(failure, forKey: .processCancelled)
        case .processOutputTooLarge(let stream, let sizeBytes, let maxSizeBytes):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .processOutputTooLarge)
            try payload.encode(stream, forKey: .stream)
            try payload.encode(sizeBytes, forKey: .sizeBytes)
            try payload.encode(maxSizeBytes, forKey: .maxSizeBytes)
        case .remoteRefTransactionIndeterminate(let message):
            var payload = container.nestedContainer(
                keyedBy: PayloadKeys.self,
                forKey: .remoteRefTransactionIndeterminate
            )
            try payload.encode(message, forKey: .message)
        case .libgit2Failure(let code, let klass, let message):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .libgit2Failure)
            try payload.encode(code, forKey: .code)
            try payload.encode(klass, forKey: .klass)
            try payload.encode(message, forKey: .message)
        case .unsupported(let message):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .unsupported)
            try payload.encode(message, forKey: .message)
        }
    }
}

public enum GitProcessOutputStream: String, Codable, CaseIterable, Sendable {
    case stdout
    case stderr
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
