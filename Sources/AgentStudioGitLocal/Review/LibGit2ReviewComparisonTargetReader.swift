import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2ReviewComparisonTargetReader: Sendable {
    private static let originHeadReferenceName = "refs/remotes/origin/HEAD"
    private static let localBranchPrefix = "refs/heads/"
    private static let remoteTrackingBranchPrefix = "refs/remotes/"

    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func targets(for repositoryPath: URL) throws -> GitReviewComparisonTargetCatalog {
        try withRepository(at: repositoryPath) { repository in
            let branches = try branchTargets(repository: repository)
            let defaultReferenceName = try originDefaultReferenceName(repository: repository)
            return GitReviewComparisonTargetCatalog(
                defaultTarget: branches.first { $0.referenceName == defaultReferenceName },
                branches: branches
            )
        }
    }

    private func branchTargets(repository: OpaquePointer) throws -> [GitReviewComparisonBranchTarget] {
        var iterator: OpaquePointer?
        let iteratorResult = git_branch_iterator_new(&iterator, repository, GIT_BRANCH_ALL)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_branch_iterator_free(iterator) }

        var targets: [GitReviewComparisonBranchTarget] = []
        while true {
            var reference: OpaquePointer?
            var branchType = git_branch_t(rawValue: 0)
            let nextResult = git_branch_next(&reference, &branchType, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                break
            }
            guard nextResult >= 0, let reference else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }
            defer { git_reference_free(reference) }

            guard let target = try branchTarget(reference: reference, branchType: branchType) else {
                continue
            }
            targets.append(target)
        }

        return targets.sorted {
            if $0.displayName == $1.displayName {
                return $0.referenceName < $1.referenceName
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func branchTarget(
        reference: OpaquePointer,
        branchType: git_branch_t
    ) throws -> GitReviewComparisonBranchTarget? {
        guard let referenceNamePointer = git_reference_name(reference) else {
            return nil
        }
        let referenceName = String(cString: referenceNamePointer)

        var commitObject: OpaquePointer?
        let peelResult = git_reference_peel(&commitObject, reference, GIT_OBJECT_COMMIT)
        if [GIT_ENOTFOUND.rawValue, GIT_EINVALIDSPEC.rawValue, GIT_EPEEL.rawValue].contains(peelResult) {
            return nil
        }
        guard peelResult >= 0, let commitObject else {
            throw LibGit2ErrorCapture.failure(code: peelResult)
        }
        defer { git_object_free(commitObject) }
        guard let commitOID = git_commit_id(commitObject) else {
            return nil
        }
        let oid = LibGit2ReviewSupport.oidString(commitOID)

        if branchType == GIT_BRANCH_LOCAL,
            referenceName.hasPrefix(Self.localBranchPrefix)
        {
            let branchName = String(referenceName.dropFirst(Self.localBranchPrefix.count))
            return branchName.isEmpty ? nil : .local(branchName: branchName, oid: oid)
        }

        guard branchType == GIT_BRANCH_REMOTE,
            referenceName.hasPrefix(Self.remoteTrackingBranchPrefix)
        else {
            return nil
        }
        let remoteAndBranch = String(referenceName.dropFirst(Self.remoteTrackingBranchPrefix.count))
        guard let separator = remoteAndBranch.firstIndex(of: "/") else {
            return nil
        }
        let remoteName = String(remoteAndBranch[..<separator])
        let branchName = String(remoteAndBranch[remoteAndBranch.index(after: separator)...])
        guard !remoteName.isEmpty, !branchName.isEmpty, branchName != "HEAD" else {
            return nil
        }
        return .remoteTracking(remoteName: remoteName, branchName: branchName, oid: oid)
    }

    private func originDefaultReferenceName(repository: OpaquePointer) throws -> String? {
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
        guard symbolicTarget.hasPrefix("\(Self.remoteTrackingBranchPrefix)origin/"),
            symbolicTarget != Self.originHeadReferenceName
        else {
            return nil
        }
        return symbolicTarget
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
