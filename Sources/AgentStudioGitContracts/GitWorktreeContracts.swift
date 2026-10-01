import Foundation

public struct GitWorktreeID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct GitWorktreeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: GitWorktreeID
    public let repositoryID: GitRepositoryID
    public let displayName: String
    public let path: URL
    public let canonicalPath: URL
    public let gitDirectory: URL
    public let indexPath: URL
    public let isMainWorktree: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let head: GitHeadSnapshot?

    public init(
        id: GitWorktreeID,
        repositoryID: GitRepositoryID,
        displayName: String,
        path: URL,
        canonicalPath: URL,
        gitDirectory: URL,
        indexPath: URL,
        isMainWorktree: Bool,
        isLocked: Bool,
        lockReason: String?,
        head: GitHeadSnapshot?
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.displayName = displayName
        self.path = path
        self.canonicalPath = canonicalPath
        self.gitDirectory = gitDirectory
        self.indexPath = indexPath
        self.isMainWorktree = isMainWorktree
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.head = head
    }
}

public struct GitValidateWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreePath: URL

    public init(worktreePath: URL) {
        self.worktreePath = worktreePath
    }
}

public struct GitWorktreeValidation: Codable, Equatable, Hashable, Sendable {
    public let snapshot: GitWorktreeSnapshot?
    public let isValid: Bool

    public init(snapshot: GitWorktreeSnapshot?, isValid: Bool) {
        self.snapshot = snapshot
        self.isValid = isValid
    }
}

public enum GitWorktreeCreateMode: Codable, Equatable, Hashable, Sendable {
    case existingBranch(name: String)
    case newBranch(name: String, startPoint: GitRevisionTarget)
    case detached(startPoint: GitRevisionTarget)
}

public struct GitCreateWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let destinationPath: URL
    public let mode: GitWorktreeCreateMode

    public init(repositoryPath: URL, destinationPath: URL, mode: GitWorktreeCreateMode) {
        self.repositoryPath = repositoryPath
        self.destinationPath = destinationPath
        self.mode = mode
    }
}

public struct GitPruneStaleWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let worktreeID: GitWorktreeID

    public init(repositoryPath: URL, worktreeID: GitWorktreeID) {
        self.repositoryPath = repositoryPath
        self.worktreeID = worktreeID
    }
}

public struct GitWorktreePruneResult: Codable, Equatable, Hashable, Sendable {
    public let prunedWorktreeID: GitWorktreeID

    public init(prunedWorktreeID: GitWorktreeID) {
        self.prunedWorktreeID = prunedWorktreeID
    }
}

public struct GitRemoveWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreeID: GitWorktreeID?
    public let canonicalPath: URL?
    public let removeWorkingDirectory: Bool
    public let forceDiscardChanges: Bool

    public init(
        worktreeID: GitWorktreeID?,
        canonicalPath: URL?,
        removeWorkingDirectory: Bool,
        forceDiscardChanges: Bool
    ) {
        self.worktreeID = worktreeID
        self.canonicalPath = canonicalPath
        self.removeWorkingDirectory = removeWorkingDirectory
        self.forceDiscardChanges = forceDiscardChanges
    }
}

public struct GitWorktreeRemovalResult: Codable, Equatable, Hashable, Sendable {
    public let removedWorktreeID: GitWorktreeID
    public let effects: GitWorktreeRemovalEffects

    public init(removedWorktreeID: GitWorktreeID, effects: GitWorktreeRemovalEffects) {
        self.removedWorktreeID = removedWorktreeID
        self.effects = effects
    }
}

public enum GitRemovalEffect: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case removed
    case retained
    case partial
    case unknown
    case notRequested
}

public enum GitWorktreeRemovalFailureKind: Codable, Equatable, Hashable, Sendable {
    case pruneFailed(code: Int32, klass: Int32)
    case observationFailed
    case removalIncomplete

    private enum CodingKeys: String, CodingKey {
        case kind
        case code
        case klass
    }

    private enum Kind: String, Codable {
        case pruneFailed
        case observationFailed
        case removalIncomplete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let presentKeys = Set(container.allKeys)

        switch kind {
        case .pruneFailed:
            guard presentKeys == Set([.kind, .code, .klass]) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "pruneFailed requires exactly code and klass"
                    )
                )
            }
            self = try .pruneFailed(
                code: container.decode(Int32.self, forKey: .code),
                klass: container.decode(Int32.self, forKey: .klass)
            )
        case .observationFailed:
            guard presentKeys == Set([.kind]) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "observationFailed does not accept a payload"
                    )
                )
            }
            self = .observationFailed
        case .removalIncomplete:
            guard presentKeys == Set([.kind]) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "removalIncomplete does not accept a payload"
                    )
                )
            }
            self = .removalIncomplete
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pruneFailed(let code, let klass):
            try container.encode(Kind.pruneFailed, forKey: .kind)
            try container.encode(code, forKey: .code)
            try container.encode(klass, forKey: .klass)
        case .observationFailed:
            try container.encode(Kind.observationFailed, forKey: .kind)
        case .removalIncomplete:
            try container.encode(Kind.removalIncomplete, forKey: .kind)
        }
    }
}

public struct GitWorktreeRemovalEffects: Codable, Equatable, Hashable, Sendable {
    public let administration: GitRemovalEffect
    public let workingDirectory: GitRemovalEffect
    public let failure: GitWorktreeRemovalFailureKind?
    public let lockResidue: [URL]

    public init(
        administration: GitRemovalEffect,
        workingDirectory: GitRemovalEffect,
        failure: GitWorktreeRemovalFailureKind?,
        lockResidue: [URL]
    ) {
        self.administration = administration
        self.workingDirectory = workingDirectory
        self.failure = failure
        self.lockResidue = lockResidue
    }

    private enum CodingKeys: String, CodingKey {
        case administration
        case workingDirectory
        case failure
        case lockResidue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let administration = try container.decode(GitRemovalEffect.self, forKey: .administration)
        guard administration != .notRequested else {
            throw DecodingError.dataCorruptedError(
                forKey: .administration,
                in: container,
                debugDescription: "worktree administration cannot be notRequested"
            )
        }
        self.init(
            administration: administration,
            workingDirectory: try container.decode(GitRemovalEffect.self, forKey: .workingDirectory),
            failure: try container.decodeIfPresent(GitWorktreeRemovalFailureKind.self, forKey: .failure),
            lockResidue: try container.decode([URL].self, forKey: .lockResidue)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(administration, forKey: .administration)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encode(lockResidue, forKey: .lockResidue)
    }
}

public struct GitLockWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreeID: GitWorktreeID
    public let reason: String?

    public init(worktreeID: GitWorktreeID, reason: String?) {
        self.worktreeID = worktreeID
        self.reason = reason
    }
}

public struct GitUnlockWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreeID: GitWorktreeID

    public init(worktreeID: GitWorktreeID) {
        self.worktreeID = worktreeID
    }
}
