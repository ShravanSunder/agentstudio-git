import Foundation

public enum GitReviewComparisonBranchTarget: Codable, Equatable, Hashable, Sendable {
    case local(branchName: String, oid: String)
    case remoteTracking(remoteName: String, branchName: String, oid: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case branchName
        case remoteName
        case oid
    }

    private enum Kind: String, Codable {
        case local
        case remoteTracking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local(
                branchName: try container.decode(String.self, forKey: .branchName),
                oid: try container.decode(String.self, forKey: .oid)
            )
        case .remoteTracking:
            self = .remoteTracking(
                remoteName: try container.decode(String.self, forKey: .remoteName),
                branchName: try container.decode(String.self, forKey: .branchName),
                oid: try container.decode(String.self, forKey: .oid)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let branchName, let oid):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(branchName, forKey: .branchName)
            try container.encode(oid, forKey: .oid)
        case .remoteTracking(let remoteName, let branchName, let oid):
            try container.encode(Kind.remoteTracking, forKey: .kind)
            try container.encode(remoteName, forKey: .remoteName)
            try container.encode(branchName, forKey: .branchName)
            try container.encode(oid, forKey: .oid)
        }
    }

    public var displayName: String {
        switch self {
        case .local(let branchName, _):
            branchName
        case .remoteTracking(let remoteName, let branchName, _):
            "\(remoteName)/\(branchName)"
        }
    }

    public var referenceName: String {
        switch self {
        case .local(let branchName, _):
            "refs/heads/\(branchName)"
        case .remoteTracking(let remoteName, let branchName, _):
            "refs/remotes/\(remoteName)/\(branchName)"
        }
    }

    public var oid: String {
        switch self {
        case .local(_, let oid), .remoteTracking(_, _, let oid):
            oid
        }
    }
}

public struct GitReviewComparisonTargetCatalog: Codable, Equatable, Hashable, Sendable {
    public let defaultTarget: GitReviewComparisonBranchTarget?
    public let branches: [GitReviewComparisonBranchTarget]

    public init(
        defaultTarget: GitReviewComparisonBranchTarget?,
        branches: [GitReviewComparisonBranchTarget]
    ) {
        self.defaultTarget = defaultTarget
        self.branches = branches
    }
}
