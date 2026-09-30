import AgentStudioGitContracts
import CLibGit2Local

extension LibGit2BranchIntegrationReader {
    func assessBranch(
        _ branchName: String,
        targetOID: git_oid,
        targetTreeOID: git_oid,
        historyAvailability: LibGit2BranchIntegrationHistoryAvailability,
        repository: OpaquePointer
    ) -> (computed: LibGit2ComputedBranchIntegration, pending: LibGit2PendingBranchDelta?) {
        let branch: LibGit2ResolvedBranchCommit
        switch lookupBranchCommit(branchName, repository: repository) {
        case .failure(let failure):
            return (
                Self.computed(
                    branchName: branchName,
                    branchCommit: failure.branchCommit,
                    grade: .unknown(failure.reason)
                ),
                nil
            )
        case .success(let resolvedBranch):
            branch = resolvedBranch
        }
        defer { git_commit_free(branch.commit) }

        if git_oid_equal(withUnsafePointer(to: branch.oid) { $0 }, withUnsafePointer(to: targetOID) { $0 }) != 0 {
            return (
                Self.computed(
                    branchName: branchName,
                    branchCommit: branch.oidString,
                    grade: .integrated(.sameCommit)
                ),
                nil
            )
        }

        guard let branchTreeOIDPointer = git_commit_tree_id(branch.commit) else {
            return directUnknown(branchName, commit: branch.oidString, reason: .readFailed)
        }
        let branchTreeOID = branchTreeOIDPointer.pointee
        if git_oid_equal(
            withUnsafePointer(to: branchTreeOID) { $0 },
            withUnsafePointer(to: targetTreeOID) { $0 }
        ) != 0 {
            return (
                Self.computed(
                    branchName: branchName,
                    branchCommit: branch.oidString,
                    grade: .integrated(.sameContent)
                ),
                nil
            )
        }

        guard historyAvailability == .complete else {
            let reason: GitIntegrationUnknownReason =
                historyAvailability == .incomplete ? .incompleteHistory : .readFailed
            return directUnknown(branchName, commit: branch.oidString, reason: reason, dependsOnHistory: true)
        }

        return assessGraphBranch(
            branchName,
            branch: branch,
            targetOID: targetOID,
            repository: repository
        )
    }

    private func directUnknown(
        _ branchName: String,
        commit: String,
        reason: GitIntegrationUnknownReason,
        dependsOnHistory: Bool = false
    ) -> (computed: LibGit2ComputedBranchIntegration, pending: LibGit2PendingBranchDelta?) {
        (
            Self.computed(
                branchName: branchName,
                branchCommit: commit,
                grade: .unknown(reason),
                dependsOnHistory: dependsOnHistory
            ),
            nil
        )
    }
}
