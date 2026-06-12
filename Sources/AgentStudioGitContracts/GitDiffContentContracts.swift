import Foundation

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

public enum GitDiffChangeKind: String, Codable, CaseIterable, Sendable {
    case added
    case copied
    case deleted
    case modified
    case renamed
    case typeChanged
    case unmerged
}

public struct GitDiffFile: Codable, Equatable, Hashable, Sendable {
    public let fileId: String
    public let path: String
    public let previousPath: String?
    public let changeKind: GitDiffChangeKind
    public let oldContentHash: String?
    public let newContentHash: String?
    public let contentHashAlgorithm: String
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    public let sizeBytes: Int64?

    public init(
        fileId: String,
        path: String,
        previousPath: String?,
        changeKind: GitDiffChangeKind,
        oldContentHash: String?,
        newContentHash: String?,
        contentHashAlgorithm: String,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        sizeBytes: Int64?
    ) {
        self.fileId = fileId
        self.path = path
        self.previousPath = previousPath
        self.changeKind = changeKind
        self.oldContentHash = oldContentHash
        self.newContentHash = newContentHash
        self.contentHashAlgorithm = contentHashAlgorithm
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.sizeBytes = sizeBytes
    }
}

public struct GitRevisionResolutionRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let target: GitRevisionTarget

    public init(repositoryPath: URL, target: GitRevisionTarget) {
        self.repositoryPath = repositoryPath
        self.target = target
    }
}

public struct GitResolvedRevision: Codable, Equatable, Hashable, Sendable {
    public let oid: String
    public let shortName: String?

    public init(oid: String, shortName: String?) {
        self.oid = oid
        self.shortName = shortName
    }
}

public struct GitTreeReadRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let revision: GitRevisionTarget
    public let path: String?

    public init(repositoryPath: URL, revision: GitRevisionTarget, path: String?) {
        self.repositoryPath = repositoryPath
        self.revision = revision
        self.path = path
    }
}

public struct GitTreeEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let oid: String
    public let mode: Int32
    public let isTree: Bool
    public let sizeBytes: Int64?

    public init(path: String, oid: String, mode: Int32, isTree: Bool, sizeBytes: Int64?) {
        self.path = path
        self.oid = oid
        self.mode = mode
        self.isTree = isTree
        self.sizeBytes = sizeBytes
    }
}

public struct GitTreeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let revision: GitResolvedRevision
    public let entries: [GitTreeEntry]

    public init(revision: GitResolvedRevision, entries: [GitTreeEntry]) {
        self.revision = revision
        self.entries = entries
    }
}

public struct GitDiffRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let base: GitDiffTarget
    public let compare: GitDiffTarget

    public init(repositoryPath: URL, base: GitDiffTarget, compare: GitDiffTarget) {
        self.repositoryPath = repositoryPath
        self.base = base
        self.compare = compare
    }
}

public struct GitDiffSnapshot: Codable, Equatable, Hashable, Sendable {
    public let files: [GitDiffFile]

    public init(files: [GitDiffFile]) {
        self.files = files
    }
}

public struct GitContentRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let revision: GitRevisionTarget
    public let path: String

    public init(repositoryPath: URL, revision: GitRevisionTarget, path: String) {
        self.repositoryPath = repositoryPath
        self.revision = revision
        self.path = path
    }
}

public struct GitContentPayload: Codable, Equatable, Hashable, Sendable {
    public let data: Data
    public let contentHash: String
    public let contentHashAlgorithm: String
    public let isBinary: Bool

    public init(data: Data, contentHash: String, contentHashAlgorithm: String, isBinary: Bool) {
        self.data = data
        self.contentHash = contentHash
        self.contentHashAlgorithm = contentHashAlgorithm
        self.isBinary = isBinary
    }
}
