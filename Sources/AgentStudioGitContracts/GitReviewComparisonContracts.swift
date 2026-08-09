import Foundation

public enum GitReviewComparisonBranchTarget: Codable, Equatable, Hashable, Sendable {
    case local(branchName: String, oid: String)
    case remoteTracking(remoteName: String, branchName: String, oid: String)

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
