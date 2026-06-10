import Foundation

public struct GitRepositoryLocation: Codable, Equatable, Hashable, Sendable {
    public let repositoryRootPath: String
    public let gitDirectoryPath: String

    public init(repositoryRootPath: String, gitDirectoryPath: String) {
        self.repositoryRootPath = repositoryRootPath
        self.gitDirectoryPath = gitDirectoryPath
    }
}

public struct GitWorktreeDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let repositoryRootPath: String
    public let worktreePath: String
    public let branchName: String?
    public let headCommitSha: String?
    public let isMainWorktree: Bool
    public let isBareRepository: Bool

    public init(
        id: String,
        repositoryRootPath: String,
        worktreePath: String,
        branchName: String?,
        headCommitSha: String?,
        isMainWorktree: Bool,
        isBareRepository: Bool
    ) {
        self.id = id
        self.repositoryRootPath = repositoryRootPath
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.headCommitSha = headCommitSha
        self.isMainWorktree = isMainWorktree
        self.isBareRepository = isBareRepository
    }
}

public enum GitChangeKind: String, Codable, CaseIterable, Sendable {
    case added
    case copied
    case conflicted
    case deleted
    case ignored
    case modified
    case renamed
    case typeChanged
    case untracked
}

public struct GitFileChange: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let previousPath: String?
    public let kind: GitChangeKind
    public let isStaged: Bool
    public let isBinary: Bool
    public let additions: Int
    public let deletions: Int

    public init(
        path: String,
        previousPath: String?,
        kind: GitChangeKind,
        isStaged: Bool,
        isBinary: Bool,
        additions: Int,
        deletions: Int
    ) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.isStaged = isStaged
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
    }
}

public enum GitDiffTargetKind: String, Codable, CaseIterable, Sendable {
    case commit
    case head
    case index
    case workingTree
}

public struct GitDiffTarget: Codable, Equatable, Hashable, Sendable {
    public let kind: GitDiffTargetKind
    public let identifier: String?

    public init(kind: GitDiffTargetKind, identifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
    }

    public static let workingTree = Self(kind: .workingTree)
    public static let index = Self(kind: .index)
    public static let head = Self(kind: .head)

    public static func commit(_ sha: String) -> Self {
        Self(kind: .commit, identifier: sha)
    }
}

public struct GitStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public let repositoryRootPath: String
    public let generatedAtUnixMilliseconds: Int64
    public let branchName: String?
    public let headCommitSha: String?
    public let changes: [GitFileChange]

    public init(
        repositoryRootPath: String,
        generatedAtUnixMilliseconds: Int64,
        branchName: String?,
        headCommitSha: String?,
        changes: [GitFileChange]
    ) {
        self.repositoryRootPath = repositoryRootPath
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.branchName = branchName
        self.headCommitSha = headCommitSha
        self.changes = changes
    }
}

public enum GitCommandKind: String, Codable, CaseIterable, Sendable {
    case diff
    case listWorktrees
    case status
}

public struct GitCommand: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: GitCommandKind
    public let repositoryRootPath: String
    public let baseTarget: GitDiffTarget?
    public let compareTarget: GitDiffTarget?

    public init(
        id: String,
        kind: GitCommandKind,
        repositoryRootPath: String,
        baseTarget: GitDiffTarget? = nil,
        compareTarget: GitDiffTarget? = nil
    ) {
        self.id = id
        self.kind = kind
        self.repositoryRootPath = repositoryRootPath
        self.baseTarget = baseTarget
        self.compareTarget = compareTarget
    }
}

public enum GitCommandResponseKind: String, Codable, CaseIterable, Sendable {
    case diff
    case failure
    case status
    case worktrees
}

public struct GitCommandFailure: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct GitCommandResponse: Codable, Equatable, Hashable, Sendable {
    public let commandId: String
    public let kind: GitCommandResponseKind
    public let statusSnapshot: GitStatusSnapshot?
    public let worktrees: [GitWorktreeDescriptor]
    public let failure: GitCommandFailure?

    public init(
        commandId: String,
        kind: GitCommandResponseKind,
        statusSnapshot: GitStatusSnapshot? = nil,
        worktrees: [GitWorktreeDescriptor] = [],
        failure: GitCommandFailure? = nil
    ) {
        self.commandId = commandId
        self.kind = kind
        self.statusSnapshot = statusSnapshot
        self.worktrees = worktrees
        self.failure = failure
    }
}

public protocol AgentStudioGitClient: Sendable {
    func listWorktrees(repositoryRootPath: String) async throws -> [GitWorktreeDescriptor]
    func status(repositoryRootPath: String) async throws -> GitStatusSnapshot
}
