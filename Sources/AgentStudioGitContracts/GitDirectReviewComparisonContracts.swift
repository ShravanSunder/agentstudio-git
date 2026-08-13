import Foundation

/// A single-read comparison between an exact target revision and the current working tree.
public struct GitDirectReviewComparisonRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let target: GitRevisionTarget

    public init(repositoryPath: URL, target: GitRevisionTarget) {
        self.repositoryPath = repositoryPath
        self.target = target
    }
}

/// Correlated identity and diff facts for a direct target-to-working-tree comparison.
public struct GitDirectReviewComparisonSnapshot: Codable, Equatable, Hashable, Sendable {
    public let resolvedTarget: GitResolvedRevision
    public let reviewedHead: GitResolvedRevision
    public let diff: GitDiffSnapshot

    public init(
        resolvedTarget: GitResolvedRevision,
        reviewedHead: GitResolvedRevision,
        diff: GitDiffSnapshot
    ) {
        self.resolvedTarget = resolvedTarget
        self.reviewedHead = reviewedHead
        self.diff = diff
    }
}
