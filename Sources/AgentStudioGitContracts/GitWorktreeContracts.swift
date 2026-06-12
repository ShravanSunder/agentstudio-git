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
    public let removedWorkingDirectory: Bool
    public let partialFailure: String?

    public init(removedWorktreeID: GitWorktreeID, removedWorkingDirectory: Bool, partialFailure: String?) {
        self.removedWorktreeID = removedWorktreeID
        self.removedWorkingDirectory = removedWorkingDirectory
        self.partialFailure = partialFailure
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
