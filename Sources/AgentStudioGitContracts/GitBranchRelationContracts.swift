import Foundation

/// Two commits to compare by the commits only one side has, for a strictly-behind or diverged decision.
public struct GitAheadBehindRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    /// Full object identifier of the side whose unique commits are `ahead`.
    public let localCommit: String
    /// Full object identifier of the side whose unique commits are `behind`.
    public let otherCommit: String

    public init(repositoryPath: URL, localCommit: String, otherCommit: String) {
        self.repositoryPath = repositoryPath
        self.localCommit = localCommit
        self.otherCommit = otherCommit
    }
}

/// Commits reachable from only one side. Unrelated histories count every commit of each side, so a caller
/// never reads `ahead == 0` as "an ancestor" unless `localCommit` really is one.
public struct GitAheadBehind: Codable, Equatable, Hashable, Sendable {
    /// Commits only `localCommit` has.
    public let ahead: Int
    /// Commits only `otherCommit` has.
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }

    private enum CodingKeys: String, CodingKey {
        case ahead
        case behind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ahead = try container.decode(Int.self, forKey: .ahead)
        let behind = try container.decode(Int.self, forKey: .behind)
        guard ahead >= 0, behind >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ahead and behind counts must be nonnegative"
                ))
        }
        self.init(ahead: ahead, behind: behind)
    }

    public func encode(to encoder: Encoder) throws {
        guard ahead >= 0, behind >= 0 else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ahead and behind counts must be nonnegative"
                ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
    }
}

public struct GitBranchUseRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    /// Short local branch name, without `refs/heads/`.
    public let branchName: String

    public init(repositoryPath: URL, branchName: String) {
        self.repositoryPath = repositoryPath
        self.branchName = branchName
    }
}

/// Whether a worktree holds a local branch the way `git worktree add` refuses it: its `HEAD` names the
/// branch, or, with `HEAD` detached, it is rebasing that branch or bisecting from it.
public enum GitBranchUse: Equatable, Hashable, Sendable {
    case free
    case inUse(worktreePath: URL)
}

extension GitBranchUse: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case worktreePath
    }

    private enum Kind: String, Codable {
        case free
        case inUse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .free:
            guard keys == [.kind] else {
                throw Self.invalidPayload(decoder, "a free branch carries no worktree path")
            }
            self = .free
        case .inUse:
            guard keys == [.kind, .worktreePath] else {
                throw Self.invalidPayload(decoder, "a branch in use names exactly one worktree path")
            }
            self = .inUse(worktreePath: try container.decode(URL.self, forKey: .worktreePath))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .free:
            try container.encode(Kind.free, forKey: .kind)
        case .inUse(let worktreePath):
            try container.encode(Kind.inUse, forKey: .kind)
            try container.encode(worktreePath, forKey: .worktreePath)
        }
    }

    private static func invalidPayload(_ decoder: Decoder, _ description: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: description))
    }
}
