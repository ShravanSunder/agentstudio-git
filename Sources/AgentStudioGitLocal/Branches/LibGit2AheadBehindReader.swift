import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Counts the commits only one of two pinned commits has. Unlike the commit-range counter, it answers for
/// any pair, so "strictly behind" (ahead 0, behind > 0) and "diverged" stay distinguishable.
struct LibGit2AheadBehindReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func aheadBehind(_ request: GitAheadBehindRequest) throws -> GitAheadBehind {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath, runtime: runtime) { repository in
            var localCommit = try LibGit2PinnedCommit.requireCommit(
                request.localCommit, label: "localCommit", repository: repository)
            var otherCommit = try LibGit2PinnedCommit.requireCommit(
                request.otherCommit, label: "otherCommit", repository: repository)
            var ahead = 0
            var behind = 0
            let graphResult = git_graph_ahead_behind(&ahead, &behind, repository, &localCommit, &otherCommit)
            guard graphResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: graphResult)
            }
            return GitAheadBehind(ahead: ahead, behind: behind)
        }
    }
}
