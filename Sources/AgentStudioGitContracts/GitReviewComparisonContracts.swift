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

/// A bounded request for review comparison targets.
///
/// The capture retains the default and current references as mandatory candidates. Other branch tips
/// are retained only when `tipCommittedAt` falls inside the inclusive `cutoff ... capturedAt` window.
public struct GitReviewComparisonTargetCaptureRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    /// Inclusive upper bound of the capture window, in Unix milliseconds.
    public let capturedAt: Int64
    /// Inclusive lower bound of the capture window, in Unix milliseconds.
    public let cutoff: Int64
    /// Maximum number of rows to return. Values below zero are treated as zero.
    public let maximumRows: Int
    /// Canonical or shorthand reference for the current branch. Pass `nil` to omit the current role.
    public let currentBranchReference: String?

    public init(
        repositoryPath: URL,
        capturedAt: Int64,
        cutoff: Int64,
        maximumRows: Int,
        currentBranchReference: String?
    ) {
        self.repositoryPath = repositoryPath
        self.capturedAt = capturedAt
        self.cutoff = cutoff
        self.maximumRows = maximumRows
        self.currentBranchReference = currentBranchReference
    }
}

public struct GitReviewComparisonTargetRow: Codable, Equatable, Hashable, Sendable {
    public let canonicalReferenceName: String
    public let target: GitReviewComparisonBranchTarget
    public let tipCommittedAt: Int64

    public init(
        canonicalReferenceName: String,
        target: GitReviewComparisonBranchTarget,
        tipCommittedAt: Int64
    ) {
        self.canonicalReferenceName = canonicalReferenceName
        self.target = target
        self.tipCommittedAt = tipCommittedAt
    }
}

public struct GitReviewComparisonTargetCapture: Codable, Equatable, Hashable, Sendable {
    public let capturedAt: Int64
    public let cutoff: Int64
    public let isTruncated: Bool
    public let defaultReferenceName: String?
    public let currentReferenceName: String?
    public let rows: [GitReviewComparisonTargetRow]

    public init(
        capturedAt: Int64,
        cutoff: Int64,
        isTruncated: Bool,
        defaultReferenceName: String?,
        currentReferenceName: String?,
        rows: [GitReviewComparisonTargetRow]
    ) {
        self.capturedAt = capturedAt
        self.cutoff = cutoff
        self.isTruncated = isTruncated
        self.defaultReferenceName = defaultReferenceName
        self.currentReferenceName = currentReferenceName
        self.rows = rows
    }
}
