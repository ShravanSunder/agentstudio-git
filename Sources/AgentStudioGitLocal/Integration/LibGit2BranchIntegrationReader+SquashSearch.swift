import AgentStudioGitContracts
import CLibGit2Local

extension LibGit2BranchIntegrationReader {
    func resolveSquashAssessments(
        _ pendingBranches: [LibGit2PendingBranchIntegration],
        targetCommit: OpaquePointer,
        repository: OpaquePointer,
        limit: Int,
        computedAssessments: inout [LibGit2ComputedBranchIntegration?]
    ) {
        var unmatchedBranches = Dictionary(
            uniqueKeysWithValues: pendingBranches.map { ($0.assessmentIndex, $0) }
        )
        var deltaIndex = GitBranchIntegrationDeltaIndex()
        var currentCommit = targetCommit
        var ownedCurrentCommit: OpaquePointer?
        defer {
            if let ownedCurrentCommit {
                git_commit_free(ownedCurrentCommit)
            }
        }
        var candidateCount = 0
        var reachedRoot = false
        var failure: GitIntegrationUnknownReason?

        while candidateCount < limit, !unmatchedBranches.isEmpty {
            let parentCount = Int(git_commit_parentcount(currentCommit))
            guard parentCount > 0 else {
                reachedRoot = true
                break
            }
            guard let parentOIDPointer = git_commit_parent_id(currentCommit, 0) else {
                failure = .readFailed
                break
            }

            let parentOID = parentOIDPointer.pointee
            var parentCommit: OpaquePointer?
            let parentResult = git_commit_lookup(
                &parentCommit,
                repository,
                withUnsafePointer(to: parentOID) { $0 }
            )
            guard parentResult >= 0, let parentCommit else {
                failure = Self.proofFailure(for: parentResult)
                break
            }

            let targetDeltaResult = firstParentDelta(
                currentCommit: currentCommit,
                parentCommit: parentCommit,
                repository: repository
            )
            guard case .success(let targetDelta) = targetDeltaResult else {
                failure = Self.reason(for: targetDeltaResult)
                git_commit_free(parentCommit)
                break
            }

            let targetCommitOID = git_commit_id(currentCommit).map { Self.oidString($0.pointee) } ?? ""
            deltaIndex.insert(targetDelta, commit: targetCommitOID)
            candidateCount += 1

            var matchedAssessmentIndexes: [Int] = []
            for (assessmentIndex, branch) in unmatchedBranches {
                guard let matchingCommit = deltaIndex.matchingCommit(for: branch.delta) else {
                    continue
                }
                computedAssessments[assessmentIndex] = Self.computed(
                    branchName: branch.branchName,
                    branchCommit: branch.branchCommit,
                    grade: .integrated(.squash(commit: matchingCommit))
                )
                matchedAssessmentIndexes.append(assessmentIndex)
            }
            for assessmentIndex in matchedAssessmentIndexes {
                unmatchedBranches.removeValue(forKey: assessmentIndex)
            }

            if !unmatchedBranches.isEmpty {
                if let ownedCurrentCommit {
                    git_commit_free(ownedCurrentCommit)
                }
                ownedCurrentCommit = parentCommit
                currentCommit = parentCommit
            } else {
                git_commit_free(parentCommit)
            }
        }

        guard !unmatchedBranches.isEmpty else {
            return
        }

        let remainingReason: GitIntegrationUnknownReason
        if let failure {
            remainingReason = failure
        } else if reachedRoot {
            remainingReason = .noMergeBase
        } else if candidateCount == limit, Int(git_commit_parentcount(currentCommit)) > 0 {
            remainingReason = .historyLimitReached
        } else {
            remainingReason = .noMergeBase
        }

        for (assessmentIndex, branch) in unmatchedBranches {
            let grade: GitBranchIntegrationGrade =
                remainingReason == .noMergeBase ? .hasRemainingContribution : .unknown(remainingReason)
            computedAssessments[assessmentIndex] = Self.computed(
                branchName: branch.branchName,
                branchCommit: branch.branchCommit,
                grade: grade,
                dependsOnHistory: true
            )
        }
    }

    func requiredTree(
        commit: OpaquePointer,
        repository: OpaquePointer
    ) -> Result<OpaquePointer, GitBranchIntegrationProofFailure> {
        var tree: OpaquePointer?
        let result = git_commit_tree(&tree, commit)
        guard result >= 0, let tree else {
            return .failure(Self.failureKind(for: result))
        }
        return .success(tree)
    }

    private func firstParentDelta(
        currentCommit: OpaquePointer,
        parentCommit: OpaquePointer,
        repository: OpaquePointer
    ) -> Result<GitBranchIntegrationDelta, GitBranchIntegrationProofFailure> {
        let currentTreeResult = requiredTree(commit: currentCommit, repository: repository)
        guard case .success(let currentTree) = currentTreeResult else {
            return .failure(Self.failureKind(for: currentTreeResult))
        }
        defer { git_tree_free(currentTree) }

        let parentTreeResult = requiredTree(commit: parentCommit, repository: repository)
        guard case .success(let parentTree) = parentTreeResult else {
            return .failure(Self.failureKind(for: parentTreeResult))
        }
        defer { git_tree_free(parentTree) }

        do {
            return .success(
                try deltaReader.read(oldTree: parentTree, newTree: currentTree, repository: repository)
            )
        } catch let failure {
            return .failure(failure)
        }
    }

}
