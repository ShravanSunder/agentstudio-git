import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// A plain checkout's branch target, resolved and pinned before anything is created.
struct LibGit2WorktreeCreateTarget {
    /// The commit the checkout writes and the branch ends at.
    let start: String
    /// Nil for a detached checkout, which has nothing to attach.
    let attach: LibGit2BranchAttachTarget?
    let upstream: GitBranchUpstream?

    var branchName: String? {
        attach.map { String($0.referenceName.dropFirst("refs/heads/".count)) }
    }

    /// The snapshot read while the worktree was detached at `start`, with the `HEAD` the attach wrote.
    func attachedSnapshot(_ detached: GitWorktreeSnapshot) -> GitWorktreeSnapshot {
        guard let branchName else {
            return detached
        }
        return GitWorktreeSnapshot(
            id: detached.id,
            repositoryID: detached.repositoryID,
            displayName: detached.displayName,
            path: detached.path,
            canonicalPath: detached.canonicalPath,
            gitDirectory: detached.gitDirectory,
            indexPath: detached.indexPath,
            isMainWorktree: detached.isMainWorktree,
            isLocked: detached.isLocked,
            lockReason: detached.lockReason,
            head: GitHeadSnapshot(kind: .branch, oid: start, shortName: branchName)
        )
    }
}

/// The plain checkout's branch step. Every rule is checked before anything is created; the worktree is then
/// registered and checked out detached at the pinned start, and the locked attach (ref lock, branch-use re-read,
/// tip compare-and-swap or creation, `HEAD`, commit of the one branch ref) runs last. A failure before the attach
/// moves no branch. The attach's commit can still report failure after its ref landed, so whatever landed is
/// recorded on the rollback: a created branch is removed, and a fast-forward is moved back to its expected tip while
/// the branch still points where the attach left it.
struct LibGit2WorktreeCreateBranchAttach {
    /// Any worktree of the repository; branch use is read across every worktree it has.
    let repositoryPath: URL

    func plan(_ mode: GitWorktreeCreateMode, repository: OpaquePointer) throws -> LibGit2WorktreeCreateTarget {
        switch mode {
        case .detached(let startPoint):
            return LibGit2WorktreeCreateTarget(
                start: try resolvedCommit(startPoint, repository: repository), attach: nil, upstream: nil)
        case .newBranch(let name, let startPoint, let upstream):
            try requireValidBranchName(name)
            if let upstream, !LibGit2BranchUpstreamWriter.isValid(upstream) {
                throw LibGit2ErrorCapture.fallbackFailure(
                    code: GIT_EINVALIDSPEC.rawValue,
                    message: "'\(upstream.remoteName)/\(upstream.branchName)' is not a valid upstream")
            }
            if try currentTip(name, repository: repository) != nil {
                throw LibGit2ErrorCapture.fallbackFailure(
                    code: GIT_EEXISTS.rawValue, message: "a branch with that name already exists")
            }
            try requireBranchFree(name)
            let start = try resolvedCommit(startPoint, repository: repository)
            return LibGit2WorktreeCreateTarget(
                start: start, attach: .newBranch(referenceName: "refs/heads/\(name)", commit: start),
                upstream: upstream)
        case .existingBranch(let name, let expectedTip, let fastForwardTo):
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
            guard try currentTip(name, repository: repository) == expectedTip.lowercased() else {
                throw GitDataPlaneError.branchMoved
            }
            try requireBranchFree(name)
            return LibGit2WorktreeCreateTarget(
                start: (fastForwardTo ?? expectedTip).lowercased(),
                attach: .existingBranch(
                    referenceName: "refs/heads/\(name)", expectedTip: expectedTip, fastForwardTo: fastForwardTo),
                upstream: nil)
        }
    }

    /// The checks repeat under the branch's ref lock, the destination's `HEAD` moves to the branch, and the branch
    /// ref alone is committed. Each landed change is recorded on the rollback, including one whose commit reported
    /// failure: a new branch's upstream write still follows, and a commit error is no proof the ref did not move.
    func attach(
        _ target: LibGit2WorktreeCreateTarget,
        destination: OpaquePointer,
        rollback: inout WorktreeCreateRollback
    ) throws {
        guard let attachTarget = target.attach, let branchName = target.branchName else {
            return
        }
        try LibGit2BranchAttach(
            request: LibGit2BranchAttachRequest(
                repositoryPath: repositoryPath,
                transactionRepository: destination,
                target: attachTarget
            ),
            lockObserver: .untracked
        ).run(
            refusal: Self.dataPlaneError,
            checkpoint: { _ throws(GitDataPlaneError) in },
            landed: { effect in
                switch effect {
                case .created(_, let commit):
                    rollback.createdBranch = (branchName, commit)
                case .fastForwarded(_, let from, let to):
                    rollback.movedBranch = (branchName, from.lowercased(), to.lowercased())
                }
            }
        )
    }

    /// The one step after the attach that can fail, and only for a new branch: if it does, rollback deletes the
    /// branch this call just created. Writing it before the branch exists would leave a `branch.<name>` section that
    /// a later branch of that name silently inherits as its tracking.
    func writeUpstream(_ target: LibGit2WorktreeCreateTarget, destination: OpaquePointer) throws {
        guard let upstream = target.upstream, let branchName = target.branchName else {
            return
        }
        try LibGit2BranchUpstreamWriter(lockObserver: .untracked).write(
            upstream, branchName: branchName, repository: destination)
    }

    private func resolvedCommit(_ startPoint: GitRevisionTarget, repository: OpaquePointer) throws -> String {
        let commit = try resolveCommit(startPoint, repository: repository)
        defer { git_commit_free(commit) }
        guard let commitID = git_commit_id(commit) else {
            throw GitDataPlaneError.unsupported(message: "start point has no commit identifier")
        }
        return oidString(commitID)
    }

    /// The branch's direct target, or nil when the branch does not exist.
    private func currentTip(_ name: String, repository: OpaquePointer) throws -> String? {
        var reference: OpaquePointer?
        let lookupResult = name.withCString { git_branch_lookup(&reference, repository, $0, GIT_BRANCH_LOCAL) }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return nil
        }
        guard lookupResult >= 0, let reference else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_reference_free(reference) }
        guard git_reference_type(reference) == GIT_REFERENCE_DIRECT, let target = git_reference_target(reference) else {
            return ""
        }
        return oidString(target)
    }

    private func requireBranchFree(_ name: String) throws {
        if case .inUse(let worktreePath) = try LibGit2BranchUseReader().branchUse(
            GitBranchUseRequest(repositoryPath: repositoryPath, branchName: name))
        {
            throw GitDataPlaneError.branchCheckedOut(worktreePath: worktreePath)
        }
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
