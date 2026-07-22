import Foundation

public struct GitTrackedPathsOptions: Codable, Equatable, Hashable, Sendable {
    public let scopePath: String?

    public init(scopePath: String? = nil) {
        self.scopePath = scopePath
    }
}

public enum GitTrackedPathKind: String, Codable, CaseIterable, Sendable {
    case file
    case symlink
    case submodule
}

public struct GitTrackedPathEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let kind: GitTrackedPathKind

    public init(path: String, kind: GitTrackedPathKind) {
        self.path = path
        self.kind = kind
    }
}

public struct GitTrackedPathsSnapshot: Codable, Equatable, Hashable, Sendable {
    public let entries: [GitTrackedPathEntry]
    public let rawIndexEntryCount: Int

    public init(entries: [GitTrackedPathEntry], rawIndexEntryCount: Int) {
        self.entries = entries
        self.rawIndexEntryCount = rawIndexEntryCount
    }
}
