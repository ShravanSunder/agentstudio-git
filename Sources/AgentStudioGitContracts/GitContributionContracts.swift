import Foundation

public struct GitContributionDiffRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let target: GitRevisionTarget

    public init(repositoryPath: URL, target: GitRevisionTarget) {
        self.repositoryPath = repositoryPath
        self.target = target
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
