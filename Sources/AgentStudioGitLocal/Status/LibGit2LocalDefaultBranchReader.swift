import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2LocalDefaultBranchReader: Sendable {
    private static let originHeadReferenceName = "refs/remotes/origin/HEAD"
    private static let originBranchPrefix = "refs/remotes/origin/"
    private static let localBranchPrefix = "refs/heads/"
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func localDefaultBranch(for repositoryPath: URL) throws -> GitLocalDefaultBranch? {
        try withRepository(at: repositoryPath) { repository in
            try localDefaultBranch(repository: repository)
        }
    }

    private func localDefaultBranch(repository: OpaquePointer) throws -> GitLocalDefaultBranch? {
        var originHeadReference: OpaquePointer?
        let lookupResult = Self.originHeadReferenceName.withCString { referenceNamePointer in
            git_reference_lookup(&originHeadReference, repository, referenceNamePointer)
        }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return nil
        }
        guard lookupResult >= 0, let originHeadReference else {
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_reference_free(originHeadReference) }

        guard git_reference_type(originHeadReference) == GIT_REFERENCE_SYMBOLIC,
            let symbolicTargetPointer = git_reference_symbolic_target(originHeadReference)
        else {
            return nil
        }

        let symbolicTarget = String(cString: symbolicTargetPointer)
        guard symbolicTarget.hasPrefix(Self.originBranchPrefix) else {
            return nil
        }
        let branchName = String(symbolicTarget.dropFirst(Self.originBranchPrefix.count))
        guard !branchName.isEmpty, branchName != "HEAD" else {
            return nil
        }

        let localReferenceName = "\(Self.localBranchPrefix)\(branchName)"
        var localBranchReference: OpaquePointer?
        let localLookupResult = localReferenceName.withCString { referenceNamePointer in
            git_reference_lookup(&localBranchReference, repository, referenceNamePointer)
        }
        if localLookupResult == GIT_ENOTFOUND.rawValue {
            return nil
        }
        guard localLookupResult >= 0, let localBranchReference else {
            throw LibGit2ErrorCapture.failure(code: localLookupResult)
        }
        defer { git_reference_free(localBranchReference) }

        var localBranchCommit: OpaquePointer?
        let peelResult = git_reference_peel(&localBranchCommit, localBranchReference, GIT_OBJECT_COMMIT)
        if [GIT_ENOTFOUND.rawValue, GIT_EINVALIDSPEC.rawValue, GIT_EPEEL.rawValue].contains(peelResult) {
            return nil
        }
        guard peelResult >= 0, let localBranchCommit else {
            throw LibGit2ErrorCapture.failure(code: peelResult)
        }
        git_object_free(localBranchCommit)

        return GitLocalDefaultBranch(name: branchName)
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }

        return try body(repository)
    }
}
