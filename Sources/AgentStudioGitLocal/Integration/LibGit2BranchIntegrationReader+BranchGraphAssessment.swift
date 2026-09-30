import AgentStudioGitContracts
import CLibGit2Local

struct LibGit2BranchIntegrationGraphFailure: Error {
    let reason: GitIntegrationUnknownReason
}

extension LibGit2BranchIntegrationReader {
    func assessGraphBranch(
        _ branchName: String,
        branch: LibGit2ResolvedBranchCommit,
        targetOID: git_oid,
        repository: OpaquePointer
    ) -> (computed: LibGit2ComputedBranchIntegration, pending: LibGit2PendingBranchDelta?) {
        var mutableTargetOID = targetOID
        var mutableBranchOID = branch.oid
        let descendantResult = git_graph_descendant_of(repository, &mutableTargetOID, &mutableBranchOID)
        guard descendantResult >= 0 else {
            return unknownGraphResult(
                branchName,
                commit: branch.oidString,
                reason: Self.proofFailure(for: descendantResult)
            )
        }
        if descendantResult > 0 {
            return (
                Self.computed(
                    branchName: branchName,
                    branchCommit: branch.oidString,
                    grade: .integrated(.ancestor)
                ),
                nil
            )
        }

        let mergeBaseCommit: OpaquePointer
        switch uniqueMergeBase(targetOID: targetOID, branchOID: branch.oid, repository: repository) {
        case .failure(let failure):
            return unknownGraphResult(branchName, commit: branch.oidString, reason: failure.reason)
        case .success(let commit):
            mergeBaseCommit = commit
        }
        defer { git_commit_free(mergeBaseCommit) }

        let delta: GitBranchIntegrationDelta
        switch branchAggregateDelta(
            mergeBaseCommit: mergeBaseCommit,
            branchCommit: branch.commit,
            repository: repository
        ) {
        case .failure(let failure):
            return unknownGraphResult(
                branchName,
                commit: branch.oidString,
                reason: Self.reason(for: failure)
            )
        case .success(let branchDelta):
            delta = branchDelta
        }

        guard !delta.entries.isEmpty else {
            return (
                Self.computed(
                    branchName: branchName,
                    branchCommit: branch.oidString,
                    grade: .integrated(.emptyDelta)
                ),
                nil
            )
        }
        return (
            Self.computed(
                branchName: branchName,
                branchCommit: branch.oidString,
                grade: .unknown(.readFailed),
                dependsOnHistory: true
            ),
            LibGit2PendingBranchDelta(branchCommit: branch.oidString, delta: delta)
        )
    }

    private func uniqueMergeBase(
        targetOID: git_oid,
        branchOID: git_oid,
        repository: OpaquePointer
    ) -> Result<OpaquePointer, LibGit2BranchIntegrationGraphFailure> {
        var mergeBases = git_oidarray(ids: nil, count: 0)
        let result = git_merge_bases(
            &mergeBases,
            repository,
            withUnsafePointer(to: targetOID) { $0 },
            withUnsafePointer(to: branchOID) { $0 }
        )
        defer { git_oidarray_dispose(&mergeBases) }

        if result == GIT_ENOTFOUND.rawValue || (result >= 0 && mergeBases.count < 1) {
            return .failure(.init(reason: .noMergeBase))
        }
        guard result >= 0 else {
            return .failure(.init(reason: Self.proofFailure(for: result)))
        }
        guard mergeBases.count == 1 else {
            return .failure(.init(reason: .multipleMergeBases))
        }
        guard let mergeBaseOIDPointer = mergeBases.ids else {
            return .failure(.init(reason: .readFailed))
        }

        var mergeBaseCommit: OpaquePointer?
        let mergeBaseResult = git_commit_lookup(
            &mergeBaseCommit,
            repository,
            withUnsafePointer(to: mergeBaseOIDPointer.pointee) { $0 }
        )
        guard mergeBaseResult >= 0, let mergeBaseCommit else {
            return .failure(.init(reason: Self.proofFailure(for: mergeBaseResult)))
        }
        return .success(mergeBaseCommit)
    }

    private func branchAggregateDelta(
        mergeBaseCommit: OpaquePointer,
        branchCommit: OpaquePointer,
        repository: OpaquePointer
    ) -> Result<GitBranchIntegrationDelta, GitBranchIntegrationProofFailure> {
        let mergeBaseTreeResult = requiredTree(commit: mergeBaseCommit, repository: repository)
        guard case .success(let mergeBaseTree) = mergeBaseTreeResult else {
            return .failure(Self.failureKind(for: mergeBaseTreeResult))
        }
        defer { git_tree_free(mergeBaseTree) }

        let branchTreeResult = requiredTree(commit: branchCommit, repository: repository)
        guard case .success(let branchTree) = branchTreeResult else {
            return .failure(Self.failureKind(for: branchTreeResult))
        }
        defer { git_tree_free(branchTree) }

        do {
            return .success(
                try deltaReader.read(oldTree: mergeBaseTree, newTree: branchTree, repository: repository)
            )
        } catch let failure {
            return .failure(failure)
        }
    }

    private func unknownGraphResult(
        _ branchName: String,
        commit: String,
        reason: GitIntegrationUnknownReason
    ) -> (computed: LibGit2ComputedBranchIntegration, pending: LibGit2PendingBranchDelta?) {
        (
            Self.computed(
                branchName: branchName,
                branchCommit: commit,
                grade: .unknown(reason),
                dependsOnHistory: true
            ),
            nil
        )
    }
}
