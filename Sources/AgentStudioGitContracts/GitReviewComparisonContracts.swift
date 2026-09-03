import Foundation

package enum GitReviewComparisonKind: String, Equatable, Sendable {
    case contribution
    case direct
}

package enum GitReviewEffectiveBaseRole: String, Equatable, Sendable {
    case contributionBase
    case selectedTarget
}

package struct GitReviewRefreshSeedKey: Equatable, Sendable {
    package let canonicalCommonDirectoryPath: String
    package let canonicalWorktreePath: String
    package let comparisonKind: GitReviewComparisonKind
    package let comparisonOptionsVersion: UInt32
    package let selectedTargetName: String
    package let resolvedTargetOID: String
    package let reviewedHeadOID: String
    package let effectiveBaseRole: GitReviewEffectiveBaseRole
    package let effectiveBaseOID: String

    package init(
        canonicalCommonDirectoryPath: String,
        canonicalWorktreePath: String,
        comparisonKind: GitReviewComparisonKind,
        comparisonOptionsVersion: UInt32,
        selectedTargetName: String,
        resolvedTargetOID: String,
        reviewedHeadOID: String,
        effectiveBaseRole: GitReviewEffectiveBaseRole,
        effectiveBaseOID: String
    ) {
        self.canonicalCommonDirectoryPath = canonicalCommonDirectoryPath
        self.canonicalWorktreePath = canonicalWorktreePath
        self.comparisonKind = comparisonKind
        self.comparisonOptionsVersion = comparisonOptionsVersion
        self.selectedTargetName = selectedTargetName
        self.resolvedTargetOID = resolvedTargetOID
        self.reviewedHeadOID = reviewedHeadOID
        self.effectiveBaseRole = effectiveBaseRole
        self.effectiveBaseOID = effectiveBaseOID
    }
}

package struct GitReviewRefreshSeedStorage: Sendable {
    package let key: GitReviewRefreshSeedKey
    package let files: [GitDiffFile]

    package init(key: GitReviewRefreshSeedKey, files: [GitDiffFile]) {
        self.key = key
        self.files = files
    }
}

/// Local-only calculation material that can be retained but not inspected or serialized by clients.
public struct GitReviewRefreshSeed: Sendable {
    package let storage: GitReviewRefreshSeedStorage

    package init(key: GitReviewRefreshSeedKey, files: [GitDiffFile]) {
        storage = GitReviewRefreshSeedStorage(key: key, files: files)
    }
}

public enum GitReviewRefreshInput: Sendable {
    case complete
    case proportional(seed: GitReviewRefreshSeed, changedPaths: [String])
}

public enum GitReviewCalculationDisposition: String, Codable, CaseIterable, Sendable {
    case complete
    case proportional
    case proportionalFallback
}

/// Bounded telemetry-safe reasons for the library's Review calculation choice.
public enum GitReviewCalculationReason: String, Codable, CaseIterable, Sendable {
    case completeRequested
    case proportionalAccepted
    case seedIdentityMismatch
    case invalidPath
    case structuralGitControlPath
    case missingScopedRow
    case ineligibleScopedRow
    case duplicateScopedRow
    case outOfScopeScopedRow
    case incompatiblePredecessorRow
    case candidatePathCollision
    case capacityRejected
    case identityMoved
    case scopedCalculationFailed
}

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
