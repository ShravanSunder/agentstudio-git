import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2CommitRangeCounter: Sendable {
    func count(_ request: GitCommitRangeCountRequest) throws -> GitCommitRangeCount {
        guard request.maximumCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "commit range maximumCount must be positive")
        }
        guard request.maximumTraversalCount > 0 else {
            throw GitDataPlaneError.unsupported(message: "commit range maximumTraversalCount must be positive")
        }
        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let baseCommit = try LibGit2ReviewSupport.resolveCommit(request.base, repository: repository)
            defer { git_commit_free(baseCommit) }
            let candidateCommit = try LibGit2ReviewSupport.resolveCommit(request.candidate, repository: repository)
            defer { git_commit_free(candidateCommit) }

            guard let baseOID = git_commit_id(baseCommit),
                let candidateOID = git_commit_id(candidateCommit)
            else {
                throw GitDataPlaneError.unsupported(message: "libgit2 resolved a commit without an object ID")
            }
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
                    return try classifyCompletedRange(
                        exactCount: count,
                        candidateOID: candidateOID,
                        baseOID: baseOID,
                        maximumTraversalCount: request.maximumTraversalCount,
                        repository: repository
                    )
                }
                guard nextResult >= 0 else {
                    throw LibGit2ErrorCapture.failure(code: nextResult)
                }
                count += 1
            }
            return .atLeastLimit(request.maximumCount)
        }
    }

    private func classifyCompletedRange(
        exactCount: Int,
        candidateOID: UnsafePointer<git_oid>,
        baseOID: UnsafePointer<git_oid>,
        maximumTraversalCount: Int,
        repository: OpaquePointer
    ) throws -> GitCommitRangeCount {
        var ancestryWalker: OpaquePointer?
        let walkerResult = git_revwalk_new(&ancestryWalker, repository)
        guard walkerResult >= 0, let ancestryWalker else {
            throw LibGit2ErrorCapture.failure(code: walkerResult)
        }
        defer { git_revwalk_free(ancestryWalker) }

        let pushResult = git_revwalk_push(ancestryWalker, candidateOID)
        guard pushResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: pushResult)
        }

        var visitedCommitCount = 0
        while visitedCommitCount < maximumTraversalCount {
            var oid = git_oid()
            let nextResult = git_revwalk_next(&oid, ancestryWalker)
            if nextResult == GIT_ITEROVER.rawValue {
                return .unrelated
            }
            guard nextResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }
            visitedCommitCount += 1
            if git_oid_equal(&oid, baseOID) != 0 {
                return .exact(exactCount)
            }
        }
        return .traversalLimitReached(maximumTraversalCount)
    }
}
