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

    /// Constructs a deterministic result for an external in-process client fake.
    ///
    /// The opaque successor cannot authorize proportional work in the libgit2 client. Passing it
    /// across client implementations therefore selects that client's complete fallback.
    public static func clientFixture(
        snapshot: GitContributionDiffSnapshot,
        calculationDisposition: GitReviewCalculationDisposition = .complete,
        calculationReason: GitReviewCalculationReason = .completeRequested
    ) -> Self {
        Self(
            snapshot: snapshot,
            successorSeed: GitReviewRefreshSeed(
                key: GitReviewRefreshSeedKey(
                    canonicalCommonDirectoryPath: "__agentstudio_git_client_fixture__",
                    canonicalWorktreePath: "__agentstudio_git_client_fixture__",
                    comparisonKind: .contribution,
                    comparisonOptionsVersion: 0,
                    selectedTargetName: snapshot.resolvedTarget.shortName ?? "__client_fixture_target__",
                    resolvedTargetOID: snapshot.resolvedTarget.oid,
                    reviewedHeadOID: snapshot.reviewedHead.oid,
                    effectiveBaseRole: .contributionBase,
                    effectiveBaseOID: snapshot.contributionBase.oid
                ),
                files: snapshot.diff.files
            ),
            calculationDisposition: calculationDisposition,
            calculationReason: calculationReason
        )
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
