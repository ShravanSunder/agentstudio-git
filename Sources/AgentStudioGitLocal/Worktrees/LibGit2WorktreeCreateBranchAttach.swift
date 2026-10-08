import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// The plain checkout's branch step: the same locked attach the fork uses (ref lock, branch-use re-read, tip
/// compare-and-swap), run before `git_worktree_add`, which then keeps its own checked-out guard. Each landed
/// change is recorded on the creation's rollback.
struct LibGit2WorktreeCreateBranchAttach {
    /// Any worktree of the repository; branch use is read across every worktree it has.
    let repositoryPath: URL
    let repository: OpaquePointer

    func newBranch(
        _ name: String,
        commit: OpaquePointer,
        upstream: GitBranchUpstream?,
        rollback: inout WorktreeCreateRollback
    ) throws {
        try requireValidBranchName(name)
        guard let commitID = git_commit_id(commit) else {
            throw GitDataPlaneError.unsupported(message: "start point has no commit identifier")
        }
        let target = LibGit2BranchAttachTarget.newBranch(referenceName: "refs/heads/\(name)", commit: oidString(commitID))
        try attach(target, rollback: &rollback)
        if let upstream {
            try LibGit2BranchUpstreamWriter(lockObserver: .untracked).write(
                upstream, branchName: name, repository: repository)
        }
    }

    func existingBranch(
        _ name: String,
        expectedTip: String,
        fastForwardTo: String?,
        rollback: inout WorktreeCreateRollback
    ) throws {
        try requireValidBranchName(name)
        var expectedTipOID = try LibGit2PinnedCommit.requireCommit(
            expectedTip, label: "expectedTip", repository: repository)
        if let fastForwardTo {
            var fastForwardOID = try LibGit2PinnedCommit.requireCommit(
                fastForwardTo, label: "fastForwardTo", repository: repository)
            let descendantResult = git_graph_descendant_of(repository, &fastForwardOID, &expectedTipOID)
            guard descendantResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: descendantResult)
            }
            guard descendantResult == 1 else {
                throw GitDataPlaneError.unsupported(message: "fastForwardTo must descend from expectedTip")
            }
        }
        try attach(
            .existingBranch(
                referenceName: "refs/heads/\(name)", expectedTip: expectedTip, fastForwardTo: fastForwardTo),
            rollback: &rollback)
    }

    private func attach(_ target: LibGit2BranchAttachTarget, rollback: inout WorktreeCreateRollback) throws {
        try LibGit2BranchAttach(
            request: LibGit2BranchAttachRequest(
                repositoryPath: repositoryPath,
                transactionRepository: repository,
                target: target,
                attachingHead: false
            ),
            lockObserver: .untracked
        ).run(
            refusal: Self.dataPlaneError,
            afterReferenceLocked: { _ throws(GitDataPlaneError) in },
            landed: { effect in
                switch effect {
                case .created(let referenceName, _):
                    rollback.createdBranchName = String(referenceName.dropFirst("refs/heads/".count))
                case .fastForwarded(let referenceName, let from, let to):
                    rollback.movedBranch = (referenceName, from, to)
                }
            }
        )
    }

    private func requireValidBranchName(_ name: String) throws {
        var isValid: Int32 = 0
        guard !name.utf8.contains(0), name.withCString({ git_branch_name_is_valid(&isValid, $0) }) >= 0, isValid == 1
        else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: GIT_EINVALIDSPEC.rawValue, message: "'\(name)' is not a valid branch name")
        }
    }

    private static func dataPlaneError(_ refusal: LibGit2BranchAttachRefusal) -> GitDataPlaneError {
        switch refusal {
        case .checkedOut(let worktreePath):
            .branchCheckedOut(worktreePath: worktreePath)
        case .moved:
            .branchMoved
        case .alreadyExists:
            LibGit2ErrorCapture.fallbackFailure(
                code: GIT_EEXISTS.rawValue, message: "a branch with that name already exists")
        case .gitFailure(let error):
            error
        }
    }
}
