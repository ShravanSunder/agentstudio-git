import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2CommitRangeCounter: Sendable {
    func count(_ request: GitCommitRangeCountRequest) throws -> GitCommitRangeCount {
        guard request.maximumCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "commit range maximumCount must be positive")
        }
        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let baseCommit = try LibGit2ReviewSupport.resolveCommit(request.base, repository: repository)
            defer { git_commit_free(baseCommit) }
            let candidateCommit = try LibGit2ReviewSupport.resolveCommit(request.candidate, repository: repository)
            defer { git_commit_free(candidateCommit) }

            let baseOID = git_commit_id(baseCommit)
            let candidateOID = git_commit_id(candidateCommit)
            if git_oid_equal(baseOID, candidateOID) != 0 {
                return .exact(0)
            }

            var walker: OpaquePointer?
            let walkerResult = git_revwalk_new(&walker, repository)
            guard walkerResult >= 0, let walker else {
                throw LibGit2ErrorCapture.failure(code: walkerResult)
            }
            defer { git_revwalk_free(walker) }

            let pushResult = git_revwalk_push(walker, candidateOID)
            guard pushResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: pushResult)
            }
            let hideResult = git_revwalk_hide(walker, baseOID)
            guard hideResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: hideResult)
            }

            var count = 0
            while count < request.maximumCount {
                var oid = git_oid()
                let nextResult = git_revwalk_next(&oid, walker)
                if nextResult == GIT_ITEROVER.rawValue {
                    let descendantResult = git_graph_descendant_of(repository, candidateOID, baseOID)
                    guard descendantResult >= 0 else {
                        throw LibGit2ErrorCapture.failure(code: descendantResult)
                    }
                    return descendantResult == 1 ? .exact(count) : .unrelated
                }
                guard nextResult >= 0 else {
                    throw LibGit2ErrorCapture.failure(code: nextResult)
                }
                count += 1
            }
            return .atLeastLimit(request.maximumCount)
        }
    }
}
