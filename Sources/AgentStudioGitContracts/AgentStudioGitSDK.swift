import Foundation

public protocol AgentStudioGitLocalClient: Sendable {
    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity
    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot]
    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    /// Forks an existing worktree's current filesystem into a new linked worktree with APFS copy-on-write
    /// storage. Normal `createWorktree` is unaffected by whether this capability is available.
    func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult
    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func statusObservationPlan(for worktreePath: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan
    func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError)
        -> GitStatusFactsRead
    func exactLineCountDetail(for worktreePath: URL) async throws(GitDataPlaneError) -> GitStatusLineCountDetail
    func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) async throws(GitDataPlaneError) -> Bool
    func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot]
    func resolveReviewDefaultTarget(for repositoryPath: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    func captureReviewComparisonTargets(_ request: GitReviewComparisonTargetCaptureRequest)
        async throws(GitDataPlaneError)
        -> GitReviewComparisonTargetCapture
    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision
    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot
    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot
    func countCommitRange(_ request: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    func summarizeDiffImpact(_ request: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload
}

extension AgentStudioGitLocalClient {
    public func statusFacts(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitStatusFactsRead
    {
        try await statusFacts(for: worktreePath, options: options, observationPlan: nil)
    }

    /// Conformers written before Worktree Fork keep compiling and report the capability as unavailable.
    public func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError)
        -> GitForkWorktreeResult
    {
        throw .rejected(reason: .clientCapabilityUnavailable)
    }
}

public protocol AgentStudioGitRemoteClient: Sendable {
    func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult
    func fetch(_ request: GitFetchRequest) async throws(GitDataPlaneError) -> GitFetchResult
    func captureRemoteTrackingSnapshot(_ request: GitRemoteTrackingSnapshotRequest)
        async throws(GitDataPlaneError) -> GitRemoteTrackingSnapshot
    func stageFetch(_ request: GitStagedFetchRequest) async throws(GitDataPlaneError) -> GitStagedFetchResult
    func promoteStagedFetch(_ request: GitPromoteStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitPromoteStagedFetchResult
    func cleanupStagedFetch(_ request: GitCleanupStagedFetchRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    func cleanupAbandonedStagedFetches(_ request: GitCleanupAbandonedStagedFetchesRequest)
        async throws(GitDataPlaneError) -> GitCleanupStagedFetchResult
    func push(_ request: GitPushRequest) async throws(GitDataPlaneError) -> GitPushResult
    func remoteReferences(_ request: GitRemoteReferencesRequest) async throws(GitDataPlaneError)
        -> [GitRemoteReference]
}

public struct AgentStudioGitSDK<LocalClient: AgentStudioGitLocalClient, RemoteClient: AgentStudioGitRemoteClient>:
    Sendable
{
    public let local: LocalClient
    public let remote: RemoteClient

    public init(local: LocalClient, remote: RemoteClient) {
        self.local = local
        self.remote = remote
    }
}
