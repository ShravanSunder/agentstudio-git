import AgentStudioGitContracts
import CLibGit2Local

struct LibGit2ResolvedBranchCommit {
    let commit: OpaquePointer
    let oid: git_oid
    let oidString: String
}

struct LibGit2BranchIntegrationLookupFailure: Error {
    let branchCommit: String?
    let reason: GitIntegrationUnknownReason
}

extension LibGit2BranchIntegrationReader {
    func lookupBranchCommit(
        _ branchName: String,
        repository: OpaquePointer
    ) -> Result<LibGit2ResolvedBranchCommit, LibGit2BranchIntegrationLookupFailure> {
        guard !branchName.utf8.contains(0) else {
            return .failure(.init(branchCommit: nil, reason: .branchNotFound))
        }

        var isValidBranchName: Int32 = 0
        let validationResult = branchName.withCString { branchNamePointer in
            git_branch_name_is_valid(&isValidBranchName, branchNamePointer)
        }
        guard validationResult >= 0 else {
            return .failure(.init(branchCommit: nil, reason: .readFailed))
        }
        guard isValidBranchName != 0 else {
            return .failure(.init(branchCommit: nil, reason: .branchNotFound))
        }

        let reference: OpaquePointer
        switch lookupBranchReference(branchName, repository: repository) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let resolvedReference):
            reference = resolvedReference
        }
        defer { git_reference_free(reference) }

        var directReference: OpaquePointer?
        let resolveResult = git_reference_resolve(&directReference, reference)
        guard resolveResult >= 0, let directReference else {
            return .failure(.init(branchCommit: nil, reason: .readFailed))
        }
        defer { git_reference_free(directReference) }

        guard let branchOIDPointer = git_reference_target(directReference) else {
            return .failure(.init(branchCommit: nil, reason: .readFailed))
        }
        let branchOID = branchOIDPointer.pointee
        let branchCommitString = Self.oidString(branchOID)
        var mutableBranchOID = branchOID
        var branchCommit: OpaquePointer?
        let commitResult = git_commit_lookup(&branchCommit, repository, &mutableBranchOID)
        guard commitResult >= 0, let branchCommit else {
            let reason: GitIntegrationUnknownReason =
                commitResult == GIT_ENOTFOUND.rawValue ? .missingObjects : .readFailed
            return .failure(.init(branchCommit: branchCommitString, reason: reason))
        }

        return .success(
            LibGit2ResolvedBranchCommit(
                commit: branchCommit,
                oid: branchOID,
                oidString: branchCommitString
            )
        )
    }

    private func lookupBranchReference(
        _ branchName: String,
        repository: OpaquePointer
    ) -> Result<OpaquePointer, LibGit2BranchIntegrationLookupFailure> {
        let referenceName = "refs/heads/\(branchName)"
        var reference: OpaquePointer?
        let result = referenceName.withCString { referenceNamePointer in
            git_reference_lookup(&reference, repository, referenceNamePointer)
        }
        guard result >= 0, let reference else {
            let reason: GitIntegrationUnknownReason = result == GIT_ENOTFOUND.rawValue ? .branchNotFound : .readFailed
            return .failure(.init(branchCommit: nil, reason: reason))
        }
        return .success(reference)
    }
}
