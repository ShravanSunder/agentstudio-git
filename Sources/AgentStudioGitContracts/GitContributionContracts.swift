import Foundation

/// In-process Review calculation input. The optional proportional capability intentionally keeps this non-Codable.
public struct GitContributionDiffRequest: Sendable {
    public let repositoryPath: URL
    public let target: GitRevisionTarget
    public let refreshInput: GitReviewRefreshInput

    public init(
        repositoryPath: URL,
        target: GitRevisionTarget,
        refreshInput: GitReviewRefreshInput = .complete
    ) {
        self.repositoryPath = repositoryPath
        self.target = target
        self.refreshInput = refreshInput
    }
}

/// One complete contribution projection plus local-only calculation continuity for its successor.
public struct GitContributionDiffResult: Sendable {
    public let snapshot: GitContributionDiffSnapshot
    public let successorSeed: GitReviewRefreshSeed
    public let calculationDisposition: GitReviewCalculationDisposition
    public let calculationReason: GitReviewCalculationReason

    package init(
        snapshot: GitContributionDiffSnapshot,
        successorSeed: GitReviewRefreshSeed,
        calculationDisposition: GitReviewCalculationDisposition,
        calculationReason: GitReviewCalculationReason
    ) {
        self.snapshot = snapshot
        self.successorSeed = successorSeed
        self.calculationDisposition = calculationDisposition
        self.calculationReason = calculationReason
    }
}

public struct GitContributionDiffSnapshot: Codable, Equatable, Hashable, Sendable {
    public let resolvedTarget: GitResolvedRevision
    public let reviewedHead: GitResolvedRevision
    public let contributionBase: GitResolvedRevision
    public let diff: GitDiffSnapshot

    public init(
        resolvedTarget: GitResolvedRevision,
        reviewedHead: GitResolvedRevision,
        contributionBase: GitResolvedRevision,
        diff: GitDiffSnapshot
    ) {
        self.resolvedTarget = resolvedTarget
        self.reviewedHead = reviewedHead
        self.contributionBase = contributionBase
        self.diff = diff
    }
}
