import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2DirectReviewComparisonReader: Sendable {
    private let beforeIdentityRecheck: @Sendable () -> Void

    init(beforeIdentityRecheck: @escaping @Sendable () -> Void = {}) {
        self.beforeIdentityRecheck = beforeIdentityRecheck
    }

    func compare(_ request: GitDirectReviewComparisonRequest) throws -> GitDirectReviewComparisonResult {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            switch request.refreshInput {
            case .complete:
                return try completeResult(
                    request: request,
                    repository: repository,
                    disposition: .complete,
                    reason: .completeRequested
                )
            case .proportional(let seed, let changedPaths):
                let decision = try withResolvedComparison(request: request, repository: repository) { comparison in
                    let attempt = LibGit2ReviewRefreshCalculator().proportionalAttempt(
                        seed: seed,
                        changedPaths: changedPaths,
                        currentKey: comparison.key,
                        baseTree: comparison.baseTree,
                        repository: repository,
                        resolveCurrentKey: {
                            beforeIdentityRecheck()
                            return try currentKey(request: request, repository: repository)
                        }
                    )
                    switch attempt {
                    case .accepted(let diff):
                        return DirectReviewRefreshDecision.result(
                            GitDirectReviewComparisonResult(
                                snapshot: snapshot(comparison: comparison, diff: diff),
                                successorSeed: GitReviewRefreshSeed(key: comparison.key, files: diff.files),
                                calculationDisposition: .proportional,
                                calculationReason: .proportionalAccepted
                            ))
                    case .requiresComplete(let reason):
                        return DirectReviewRefreshDecision.fallback(reason)
                    }
                }
                switch decision {
                case .result(let result):
                    return result
                case .fallback(let reason):
                    return try completeResult(
                        request: request,
                        repository: repository,
                        disposition: .proportionalFallback,
                        reason: reason
                    )
                }
            }
        }
    }

    private func completeResult(
        request: GitDirectReviewComparisonRequest,
        repository: OpaquePointer,
        disposition: GitReviewCalculationDisposition,
        reason: GitReviewCalculationReason
    ) throws -> GitDirectReviewComparisonResult {
        try withResolvedComparison(request: request, repository: repository) { comparison in
            let calculation = try LibGit2ReviewRefreshCalculator().completeCalculation(
                key: comparison.key,
                baseTree: comparison.baseTree,
                repository: repository,
                disposition: disposition,
                reason: reason
            )
            return GitDirectReviewComparisonResult(
                snapshot: snapshot(comparison: comparison, diff: calculation.diff),
                successorSeed: calculation.successorSeed,
                calculationDisposition: calculation.disposition,
                calculationReason: calculation.reason
            )
        }
    }

    private func currentKey(
        request: GitDirectReviewComparisonRequest,
        repository: OpaquePointer
    ) throws -> GitReviewRefreshSeedKey {
        try withResolvedComparison(request: request, repository: repository) { $0.key }
    }

    private func withResolvedComparison<ReturnValue>(
        request: GitDirectReviewComparisonRequest,
        repository: OpaquePointer,
        _ body: (ResolvedDirectReviewComparison) throws -> ReturnValue
    ) throws -> ReturnValue {
        let contributionReader = LibGit2ContributionDiffReader()
        let resolvedTarget = try contributionReader.resolveTargetCommit(request.target, repository: repository)
        defer { git_commit_free(resolvedTarget.commit) }
        let reviewedHead = try contributionReader.resolveReviewedHead(repository: repository)
        defer { git_commit_free(reviewedHead.commit) }
        let targetTree = try contributionReader.requiredTree(commit: resolvedTarget.commit)
        defer { git_tree_free(targetTree) }

        let targetOID = LibGit2ReviewSupport.oidString(
            try contributionReader.requiredCommitOID(resolvedTarget.commit))
        let headOID = LibGit2ReviewSupport.oidString(
            try contributionReader.requiredCommitOID(reviewedHead.commit))
        let comparison = ResolvedDirectReviewComparison(
            target: GitResolvedRevision(oid: targetOID, shortName: resolvedTarget.shortName),
            reviewedHead: GitResolvedRevision(oid: headOID, shortName: reviewedHead.shortName),
            key: GitReviewRefreshSeedKey(
                canonicalCommonDirectoryPath: try LibGit2ReviewSupport.repositoryCommonDirectory(repository)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
                canonicalWorktreePath: try LibGit2ReviewSupport.repositoryWorkDirectory(repository)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
                comparisonKind: .direct,
                comparisonOptionsVersion: LibGit2ReviewRefreshCalculator.comparisonOptionsVersion,
                selectedTargetName: request.target.name,
                resolvedTargetOID: targetOID,
                reviewedHeadOID: headOID,
                effectiveBaseRole: .selectedTarget,
                effectiveBaseOID: targetOID
            ),
            baseTree: targetTree
        )
        return try body(comparison)
    }

    private func snapshot(
        comparison: ResolvedDirectReviewComparison,
        diff: GitDiffSnapshot
    ) -> GitDirectReviewComparisonSnapshot {
        GitDirectReviewComparisonSnapshot(
            resolvedTarget: comparison.target,
            reviewedHead: comparison.reviewedHead,
            diff: diff
        )
    }
}

private struct ResolvedDirectReviewComparison {
    let target: GitResolvedRevision
    let reviewedHead: GitResolvedRevision
    let key: GitReviewRefreshSeedKey
    let baseTree: OpaquePointer
}

private enum DirectReviewRefreshDecision {
    case result(GitDirectReviewComparisonResult)
    case fallback(GitReviewCalculationReason)
}
