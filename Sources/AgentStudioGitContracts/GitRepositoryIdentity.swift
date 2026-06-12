import Foundation

public struct GitRepositoryID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct GitRepositoryIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: GitRepositoryID
    public let canonicalCommonDirectory: URL
    public let mainWorktreePath: URL?

    public init(id: GitRepositoryID, canonicalCommonDirectory: URL, mainWorktreePath: URL?) {
        self.id = id
        self.canonicalCommonDirectory = canonicalCommonDirectory
        self.mainWorktreePath = mainWorktreePath
    }
}

public struct GitRevisionTarget: Codable, Equatable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public static func named(_ name: String) -> Self {
        Self(name: name)
    }
}
