import AgentStudioGit
import Foundation

/// A source conformer written before `forkWorktree` existed. It must keep compiling through the
/// protocol-extension default, which is the Specification's source-compatibility promise.
struct LegacyLocalClientDouble: AgentStudioGitLocalClient {
    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        throw unavailable
    }

    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        throw unavailable
    }

    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        throw unavailable
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw unavailable
    }

    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        throw unavailable
    }

    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    {
        throw unavailable
    }

    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw unavailable
    }

    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw unavailable
    }

    func statusObservationPlan(for worktreePath: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan {
        throw unavailable
    }

    func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError) -> GitStatusFactsRead {
        throw unavailable
    }

    func exactLineCountDetail(for worktreePath: URL) async throws(GitDataPlaneError) -> GitStatusLineCountDetail {
        throw unavailable
    }

    func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    {
        throw unavailable
    }

    func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    {
        throw unavailable
    }

    func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) async throws(GitDataPlaneError) -> Bool {
        throw unavailable
    }

    func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    {
        throw unavailable
    }

    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw unavailable
    }

    func resolveReviewDefaultTarget(for repositoryPath: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    {
        throw unavailable
    }

    func captureReviewComparisonTargets(_ request: GitReviewComparisonTargetCaptureRequest)
        async throws(GitDataPlaneError) -> GitReviewComparisonTargetCapture
    {
        throw unavailable
    }

    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
        -> GitResolvedRevision
    {
        throw unavailable
    }

    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        throw unavailable
    }

    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        throw unavailable
    }

    func countCommitRange(_ request: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    {
        throw unavailable
    }

    func summarizeDiffImpact(_ request: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    {
        throw unavailable
    }

    func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    {
        throw unavailable
    }

    func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    {
        throw unavailable
    }

    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        throw unavailable
    }

    private var unavailable: GitDataPlaneError {
        .unsupported(message: "legacy test double")
    }
}
