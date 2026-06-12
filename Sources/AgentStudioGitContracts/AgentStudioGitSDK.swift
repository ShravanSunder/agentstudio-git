import Foundation

public protocol AgentStudioGitLocalClient: Sendable {
    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity
    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot]
    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError) -> GitStatusSnapshot
    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot]
    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision
    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot
    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot
    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload
}

public protocol AgentStudioGitRemoteClient: Sendable {
    func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult
    func fetch(_ request: GitFetchRequest) async throws(GitDataPlaneError) -> GitFetchResult
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
