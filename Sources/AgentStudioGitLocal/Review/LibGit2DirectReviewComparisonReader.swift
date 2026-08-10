import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2DirectReviewComparisonReader: Sendable {
    func compare(_ request: GitDirectReviewComparisonRequest) throws -> GitDirectReviewComparisonSnapshot {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let contributionReader = LibGit2ContributionDiffReader()
            let resolvedTarget = try contributionReader.resolveTargetCommit(
                request.target,
                repository: repository
            )
            defer { git_commit_free(resolvedTarget.commit) }
            let reviewedHead = try contributionReader.resolveReviewedHead(repository: repository)
            defer { git_commit_free(reviewedHead.commit) }
            let targetTree = try contributionReader.requiredTree(commit: resolvedTarget.commit)
            defer { git_tree_free(targetTree) }

            return GitDirectReviewComparisonSnapshot(
                resolvedTarget: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(
                        try contributionReader.requiredCommitOID(resolvedTarget.commit)
                    ),
                    shortName: resolvedTarget.shortName
                ),
                reviewedHead: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(
                        try contributionReader.requiredCommitOID(reviewedHead.commit)
                    ),
                    shortName: reviewedHead.shortName
                ),
                diff: try LibGit2DiffReader().diff(baseTree: targetTree, repository: repository)
            )
        }
    }
}
