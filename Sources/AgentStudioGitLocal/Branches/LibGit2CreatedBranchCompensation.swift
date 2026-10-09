import AgentStudioGitContracts
import Foundation

/// What compensating a call-created branch left behind.
struct LibGit2CreatedBranchRemoval: Equatable, Sendable {
    /// The branch and its configuration and reflog are gone, or the branch was already absent.
    let removed: Bool
    /// Lock files the deletion took and could not release.
    let lockResidue: [URL]
}

/// Removes a branch the current call created, only while it is still at the commit the call created it at, through
/// the locked expected-OID deletion that branch deletion (LR14) uses. `git_branch_delete` is not used: it drops the
/// branch's configuration and reflog before comparing the ref, so a branch another writer moved meanwhile would lose
/// its metadata. A moved or checked-out branch, an uncertain deletion, and metadata left in place all count as not
/// removed. A transaction carrier, whose unique name only its call knows, keeps plain deletion.
struct LibGit2CreatedBranchCompensation {
    /// Any worktree or the common directory of the repository.
    let repositoryPath: URL
    let runtime: LibGit2Runtime

    func remove(branchName: String, createdAt commit: String) -> LibGit2CreatedBranchRemoval {
        let result: GitDeleteLocalBranchResult
        do throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) {
            result = try LibGit2LocalBranchDeletionWriter(runtime: runtime).deleteLocalBranch(
                GitDeleteLocalBranchRequest(
                    repositoryPath: repositoryPath, branchName: branchName, expectedCommit: commit)
            )
        } catch {
            return LibGit2CreatedBranchRemoval(removed: false, lockResidue: error.lockResidue ?? [])
        }
        switch result {
        case .deleted(let cleanup, let lockResidue):
            return LibGit2CreatedBranchRemoval(
                removed: Self.isGone(cleanup.configuration) && Self.isGone(cleanup.reflog), lockResidue: lockResidue)
        case .retained(.notFound, let lockResidue):
            return LibGit2CreatedBranchRemoval(removed: true, lockResidue: lockResidue)
        case .retained(_, let lockResidue), .uncertain(_, let lockResidue):
            return LibGit2CreatedBranchRemoval(removed: false, lockResidue: lockResidue)
        }
    }

    private static func isGone(_ disposition: GitBranchMetadataDisposition) -> Bool {
        switch disposition {
        case .removed, .absent:
            true
        case .leftInPlace:
            false
        }
    }
}
