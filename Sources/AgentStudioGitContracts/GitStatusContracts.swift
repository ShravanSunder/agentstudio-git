import Foundation

public enum GitHeadKind: String, Codable, CaseIterable, Sendable {
    case branch
    case detached
    case unborn
}

public struct GitHeadSnapshot: Codable, Equatable, Hashable, Sendable {
    public let kind: GitHeadKind
    public let oid: String?
    public let shortName: String?

    public init(kind: GitHeadKind, oid: String?, shortName: String?) {
        self.kind = kind
        self.oid = oid
        self.shortName = shortName
    }
}

public struct GitBranchSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public let upstreamName: String?

    public init(name: String, isCurrent: Bool, upstreamName: String?) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstreamName = upstreamName
    }
}

public struct GitRemoteSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public enum GitOriginResolution: Codable, Equatable, Hashable, Sendable {
    case awaitingResolution
    case confirmedAbsent
    case resolved(GitRemoteSnapshot)
}

public struct GitStatusSummary: Codable, Equatable, Hashable, Sendable {
    public let changedFileCount: Int
    public let stagedFileCount: Int
    public let unstagedFileCount: Int
    public let untrackedFileCount: Int
    public let ignoredFileCount: Int
    public let linesAdded: Int
    public let linesDeleted: Int
    public let aheadCount: Int
    public let behindCount: Int
    public let hasUpstream: Bool

    public init(
        changedFileCount: Int,
        stagedFileCount: Int,
        unstagedFileCount: Int,
        untrackedFileCount: Int,
        ignoredFileCount: Int,
        linesAdded: Int,
        linesDeleted: Int,
        aheadCount: Int,
        behindCount: Int,
        hasUpstream: Bool
    ) {
        self.changedFileCount = changedFileCount
        self.stagedFileCount = stagedFileCount
        self.unstagedFileCount = unstagedFileCount
        self.untrackedFileCount = untrackedFileCount
        self.ignoredFileCount = ignoredFileCount
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.hasUpstream = hasUpstream
    }
}

public enum GitStatusState: String, Codable, CaseIterable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
    case unmerged
}

public struct GitStatusEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let previousPath: String?
    public let indexState: GitStatusState?
    public let worktreeState: GitStatusState?
    public let ignored: Bool
    public let untracked: Bool

    public init(
        path: String,
        previousPath: String?,
        indexState: GitStatusState?,
        worktreeState: GitStatusState?,
        ignored: Bool,
        untracked: Bool
    ) {
        self.path = path
        self.previousPath = previousPath
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.ignored = ignored
        self.untracked = untracked
    }
}

public struct GitStatusOptions: Codable, Equatable, Hashable, Sendable {
    public let includeIgnored: Bool
    public let includeUntracked: Bool

    public init(includeIgnored: Bool = false, includeUntracked: Bool = true) {
        self.includeIgnored = includeIgnored
        self.includeUntracked = includeUntracked
    }
}

public struct GitStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public let repositoryRoot: URL
    public let worktreePath: URL
    public let generatedAtUnixMilliseconds: Int64
    public let head: GitHeadSnapshot
    public let originResolution: GitOriginResolution
    public let summary: GitStatusSummary
    public let entries: [GitStatusEntry]

    public init(
        repositoryRoot: URL,
        worktreePath: URL,
        generatedAtUnixMilliseconds: Int64,
        head: GitHeadSnapshot,
        originResolution: GitOriginResolution,
        summary: GitStatusSummary,
        entries: [GitStatusEntry]
    ) {
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.head = head
        self.originResolution = originResolution
        self.summary = summary
        self.entries = entries
    }
}
