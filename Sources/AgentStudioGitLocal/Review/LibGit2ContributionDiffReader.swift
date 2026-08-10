import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2ContributionDiffReader: Sendable {
    func contributionDiff(_ request: GitContributionDiffRequest) throws -> GitContributionDiffSnapshot {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let resolvedTarget = try resolveTargetCommit(request.target, repository: repository)
            defer { git_commit_free(resolvedTarget.commit) }
            let reviewedHead = try resolveReviewedHead(repository: repository)
            defer { git_commit_free(reviewedHead.commit) }

            let targetOID = try requiredCommitOID(resolvedTarget.commit)
            let headOID = try requiredCommitOID(reviewedHead.commit)
            let contributionBaseOID = try uniqueContributionBase(
                targetOID: targetOID,
                headOID: headOID,
                repository: repository
            )
            let contributionBase = try lookupRequiredCommit(oid: contributionBaseOID, repository: repository)
            defer { git_commit_free(contributionBase) }
            let contributionBaseTree = try requiredTree(commit: contributionBase)
            defer { git_tree_free(contributionBaseTree) }

            let diff = try LibGit2DiffReader().diff(baseTree: contributionBaseTree, repository: repository)
            return GitContributionDiffSnapshot(
                resolvedTarget: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(targetOID),
                    shortName: resolvedTarget.shortName
                ),
                reviewedHead: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(headOID),
                    shortName: reviewedHead.shortName
                ),
                contributionBase: GitResolvedRevision(
                    oid: LibGit2ReviewSupport.oidString(contributionBaseOID),
                    shortName: nil
                ),
                diff: diff
            )
        }
    }

    func resolveTargetCommit(
        _ target: GitRevisionTarget,
        repository: OpaquePointer
    ) throws -> (commit: OpaquePointer, shortName: String?) {
        var object: OpaquePointer?
        var reference: OpaquePointer?
        let revparseResult = target.name.withCString { targetPointer in
            git_revparse_ext(&object, &reference, repository, targetPointer)
        }
        if revparseResult >= 0 {
            guard let object else {
                throw LibGit2ErrorCapture.fallbackFailure(
                    code: -1,
                    message: "libgit2 resolved a revision without an object"
                )
            }
            defer { git_object_free(object) }
            defer { git_reference_free(reference) }

            return (
                commit: try peelCommit(object, target: target),
                shortName: reference == nil ? nil : target.name
            )
        }
        guard revparseResult == GIT_ENOTFOUND.rawValue else {
            if [GIT_EAMBIGUOUS.rawValue, GIT_EINVALIDSPEC.rawValue].contains(revparseResult) {
                throw GitDataPlaneError.revisionUnavailable(target: target)
            }
            throw LibGit2ErrorCapture.failure(code: revparseResult)
        }

        reference = nil
        let referenceResult = target.name.withCString { targetPointer in
            git_reference_dwim(&reference, repository, targetPointer)
        }
        guard referenceResult >= 0 else {
            if [GIT_ENOTFOUND.rawValue, GIT_EINVALIDSPEC.rawValue].contains(referenceResult) {
                throw GitDataPlaneError.revisionUnavailable(target: target)
            }
            throw LibGit2ErrorCapture.failure(code: referenceResult)
        }
        guard let reference else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 resolved a reference without a reference object"
            )
        }
        defer { git_reference_free(reference) }

        guard let targetOIDPointer = git_reference_target(reference) else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 resolved a reference without a direct object ID"
            )
        }
        let targetOID = targetOIDPointer.pointee
        var mutableTargetOID = targetOID
        object = nil
        let lookupResult = git_object_lookup(&object, repository, &mutableTargetOID, GIT_OBJECT_ANY)
        guard lookupResult >= 0, let object else {
            if lookupResult == GIT_ENOTFOUND.rawValue {
                throw GitDataPlaneError.requiredObjectNotFound(
                    oid: LibGit2ReviewSupport.oidString(targetOID)
                )
            }
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_object_free(object) }

        return (commit: try peelCommit(object, target: target), shortName: target.name)
    }

    private func peelCommit(_ object: OpaquePointer, target: GitRevisionTarget) throws -> OpaquePointer {
        var commit: OpaquePointer?
        let peelResult = git_object_peel(&commit, object, GIT_OBJECT_COMMIT)
        guard peelResult >= 0, let commit else {
            if [GIT_ENOTFOUND.rawValue, GIT_EINVALIDSPEC.rawValue, GIT_EPEEL.rawValue].contains(peelResult) {
                throw GitDataPlaneError.revisionUnavailable(target: target)
            }
            throw LibGit2ErrorCapture.failure(code: peelResult)
        }
        return commit
    }

    func resolveReviewedHead(repository: OpaquePointer) throws -> (commit: OpaquePointer, shortName: String?) {
        var headReference: OpaquePointer?
        let headResult = git_repository_head(&headReference, repository)
        guard headResult >= 0, let headReference else {
            if [GIT_ENOTFOUND.rawValue, GIT_EUNBORNBRANCH.rawValue].contains(headResult) {
                throw GitDataPlaneError.headUnavailable
            }
            throw LibGit2ErrorCapture.failure(code: headResult)
        }
        defer { git_reference_free(headReference) }

        guard let headOIDPointer = git_reference_target(headReference) else {
            throw GitDataPlaneError.headUnavailable
        }
        let headOID = headOIDPointer.pointee
        let commit = try lookupRequiredCommit(oid: headOID, repository: repository)
        let shortName = git_reference_shorthand(headReference).map { String(cString: $0) }
        return (commit, shortName)
    }

    private func uniqueContributionBase(
        targetOID: git_oid,
        headOID: git_oid,
        repository: OpaquePointer
    ) throws -> git_oid {
        var targetOID = targetOID
        var headOID = headOID
        var mergeBases = git_oidarray(ids: nil, count: 0)
        let mergeBaseResult = git_merge_bases(&mergeBases, repository, &targetOID, &headOID)
        defer { git_oidarray_dispose(&mergeBases) }

        let targetOIDString = LibGit2ReviewSupport.oidString(targetOID)
        let headOIDString = LibGit2ReviewSupport.oidString(headOID)
        if mergeBaseResult == GIT_ENOTFOUND.rawValue {
            throw GitDataPlaneError.noSharedHistory(targetOID: targetOIDString, headOID: headOIDString)
        }
        guard mergeBaseResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: mergeBaseResult)
        }
        let mergeBaseCount = mergeBases.count
        guard mergeBaseCount > 0 else {
            throw GitDataPlaneError.noSharedHistory(targetOID: targetOIDString, headOID: headOIDString)
        }
        guard mergeBaseCount == 1 else {
            throw GitDataPlaneError.multipleBestMergeBases(
                targetOID: targetOIDString,
                headOID: headOIDString,
                count: mergeBaseCount
            )
        }
        guard let mergeBaseIDs = mergeBases.ids else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned one merge base without an object ID"
            )
        }
        return mergeBaseIDs.pointee
    }

    private func lookupRequiredCommit(oid: git_oid, repository: OpaquePointer) throws -> OpaquePointer {
        var oid = oid
        var commit: OpaquePointer?
        let lookupResult = git_commit_lookup(&commit, repository, &oid)
        guard lookupResult >= 0, let commit else {
            if lookupResult == GIT_ENOTFOUND.rawValue {
                throw GitDataPlaneError.requiredObjectNotFound(oid: LibGit2ReviewSupport.oidString(oid))
            }
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        return commit
    }

    func requiredTree(commit: OpaquePointer) throws -> OpaquePointer {
        guard let treeOIDPointer = git_commit_tree_id(commit) else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned a commit without a tree object ID"
            )
        }
        let treeOID = treeOIDPointer.pointee
        var tree: OpaquePointer?
        let treeResult = git_commit_tree(&tree, commit)
        guard treeResult >= 0, let tree else {
            if treeResult == GIT_ENOTFOUND.rawValue {
                throw GitDataPlaneError.requiredObjectNotFound(oid: LibGit2ReviewSupport.oidString(treeOID))
            }
            throw LibGit2ErrorCapture.failure(code: treeResult)
        }
        return tree
    }

    func requiredCommitOID(_ commit: OpaquePointer) throws -> git_oid {
        guard let oidPointer = git_commit_id(commit) else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned a commit without an object ID"
            )
        }
        return oidPointer.pointee
    }
}
