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

    func resolveDefaultTarget(for repositoryPath: URL) throws -> GitReviewComparisonBranchTarget? {
        try LibGit2ReviewSupport.withRepository(at: repositoryPath, runtime: runtime) { repository in
            guard
                let reference = try lookupReference(
                    named: Self.originHeadReferenceName,
                    repository: repository
                )
            else {
                return nil
            }
            defer { git_reference_free(reference) }

            guard let symbolicTargetName = symbolicTargetName(reference),
                Self.remoteTrackingBranchName(
                    from: symbolicTargetName,
                    requiredRemote: "origin"
                ) != nil
            else {
                return nil
            }
            guard let targetReference = try lookupReference(named: symbolicTargetName, repository: repository) else {
                return nil
            }
            defer { git_reference_free(targetReference) }
            guard
                let candidate = try row(
                    reference: targetReference,
                    referenceName: symbolicTargetName,
                    branchType: GIT_BRANCH_REMOTE
                )
            else {
                return nil
            }
            return candidate.target
        }
    }

    func capture(_ request: GitReviewComparisonTargetCaptureRequest) throws -> GitReviewComparisonTargetCapture {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath, runtime: runtime) { repository in
            let defaultReferenceName = try resolveDefaultReferenceName(repository: repository)
            let defaultRow = try resolveMandatoryRow(
                referenceName: defaultReferenceName,
                repository: repository
            )
            let currentReferenceName = try resolveCurrentBranchReferenceName(
                request.currentBranchReference,
                repository: repository
            )
            let currentRow = try resolveMandatoryRow(
                referenceName: currentReferenceName,
                repository: repository
            )

            var rowsByReferenceName: [String: GitReviewComparisonTargetRow] = [:]
            if let defaultRow {
                rowsByReferenceName[defaultRow.canonicalReferenceName] = defaultRow
            }
            if let currentRow {
                rowsByReferenceName[currentRow.canonicalReferenceName] = currentRow
            }

            for row in try branchRows(repository: repository) {
                rowsByReferenceName[row.canonicalReferenceName] = row
            }

            let defaultReference = defaultRow?.canonicalReferenceName
            let currentReference = currentRow?.canonicalReferenceName
            let eligibleRows = rowsByReferenceName.values.filter { row in
                row.canonicalReferenceName == defaultReference
                    || row.canonicalReferenceName == currentReference
                    || (row.tipCommittedAt >= request.cutoff && row.tipCommittedAt <= request.capturedAt)
            }

            let orderedRows = eligibleRows.sorted { left, right in
                let leftPriority = rolePriority(
                    referenceName: left.canonicalReferenceName,
                    defaultReferenceName: defaultReference,
                    currentReferenceName: currentReference
                )
                let rightPriority = rolePriority(
                    referenceName: right.canonicalReferenceName,
                    defaultReferenceName: defaultReference,
                    currentReferenceName: currentReference
                )
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                if left.tipCommittedAt != right.tipCommittedAt {
                    return left.tipCommittedAt > right.tipCommittedAt
                }
                return left.canonicalReferenceName < right.canonicalReferenceName
            }

            let maximumRows = max(0, request.maximumRows)
            let rows = Array(orderedRows.prefix(maximumRows))
            let retainedReferenceNames = Set(rows.map(\.canonicalReferenceName))
            return GitReviewComparisonTargetCapture(
                capturedAt: request.capturedAt,
                cutoff: request.cutoff,
                isTruncated: orderedRows.count > rows.count,
                defaultReferenceName: defaultReference.flatMap {
                    retainedReferenceNames.contains($0) ? $0 : nil
                },
                currentReferenceName: currentReference.flatMap {
                    retainedReferenceNames.contains($0) ? $0 : nil
                },
                rows: rows
            )
        }
    }

    private func branchRows(repository: OpaquePointer) throws -> [GitReviewComparisonTargetRow] {
        var iterator: OpaquePointer?
        let iteratorResult = git_branch_iterator_new(&iterator, repository, GIT_BRANCH_ALL)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_branch_iterator_free(iterator) }

        var rows: [GitReviewComparisonTargetRow] = []
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

            guard let referenceNamePointer = git_reference_name(reference) else {
                continue
            }
            let referenceName = String(cString: referenceNamePointer)
            guard git_reference_type(reference) != GIT_REFERENCE_SYMBOLIC else {
                continue
            }
            guard
                Self.isBranchReference(
                    referenceName: referenceName,
                    branchType: branchType
                ),
                let row = try row(
                    reference: reference,
                    referenceName: referenceName,
                    branchType: branchType
                )
            else {
                continue
            }
            rows.append(row)
        }
        return rows
    }

    private func resolveCurrentBranchReferenceName(
        _ currentBranchReference: String?,
        repository: OpaquePointer
    ) throws -> String? {
        guard let currentBranchReference else {
            return nil
        }
        if let canonicalReferenceName = Self.validBranchReferenceName(currentBranchReference) {
            return canonicalReferenceName
        }

        var reference: OpaquePointer?
        let result = currentBranchReference.withCString { referenceNamePointer in
            git_reference_dwim(&reference, repository, referenceNamePointer)
        }
        if [GIT_ENOTFOUND.rawValue, GIT_EINVALIDSPEC.rawValue].contains(result) {
            return nil
        }
        guard result >= 0, let reference else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        defer { git_reference_free(reference) }
        guard let referenceNamePointer = git_reference_name(reference) else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 resolved a shorthand without a reference name"
            )
        }
        return Self.validBranchReferenceName(String(cString: referenceNamePointer))
    }

    private func resolveMandatoryRow(
        referenceName: String?,
        repository: OpaquePointer
    ) throws -> GitReviewComparisonTargetRow? {
        guard let referenceName, Self.validBranchReferenceName(referenceName) != nil else {
            return nil
        }
        guard let reference = try lookupReference(named: referenceName, repository: repository) else {
            return nil
        }
        defer { git_reference_free(reference) }
        return try row(
            reference: reference,
            referenceName: referenceName,
            branchType: Self.branchType(for: referenceName)
        )
    }

    private func row(
        reference: OpaquePointer,
        referenceName: String,
        branchType: git_branch_t
    ) throws -> GitReviewComparisonTargetRow? {
        guard git_reference_type(reference) != GIT_REFERENCE_SYMBOLIC else {
            return nil
        }
        guard
            let target = Self.makeTarget(
                referenceName: referenceName,
                branchType: branchType
            )
        else {
            return nil
        }
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
        return GitReviewComparisonTargetRow(
            canonicalReferenceName: referenceName,
            target: target.withOID(LibGit2ReviewSupport.oidString(commitOID)),
            tipCommittedAt: Int64(git_commit_time(commitObject)) * 1000
        )
    }

    private func resolveDefaultReferenceName(repository: OpaquePointer) throws -> String? {
        guard
            let reference = try lookupReference(
                named: Self.originHeadReferenceName,
                repository: repository
            )
        else {
            return nil
        }
        defer { git_reference_free(reference) }
        guard let symbolicTarget = symbolicTargetName(reference) else {
            return nil
        }
        guard Self.remoteTrackingBranchName(from: symbolicTarget, requiredRemote: "origin") != nil else {
            return nil
        }
        return symbolicTarget
    }

    private func lookupReference(named name: String, repository: OpaquePointer) throws -> OpaquePointer? {
        var reference: OpaquePointer?
        let result = name.withCString { namePointer in
            git_reference_lookup(&reference, repository, namePointer)
        }
        if result == GIT_ENOTFOUND.rawValue {
            return nil
        }
        guard result >= 0, let reference else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return reference
    }

    private func symbolicTargetName(_ reference: OpaquePointer) -> String? {
        guard git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC,
            let symbolicTargetPointer = git_reference_symbolic_target(reference)
        else {
            return nil
        }
        return String(cString: symbolicTargetPointer)
    }

    private static func isBranchReference(referenceName: String, branchType: git_branch_t) -> Bool {
        guard branchType == GIT_BRANCH_LOCAL || branchType == GIT_BRANCH_REMOTE else {
            return false
        }
        return validBranchReferenceName(referenceName) != nil
    }

    private static func validBranchReferenceName(_ referenceName: String?) -> String? {
        guard let referenceName,
            referenceName.hasPrefix(localBranchPrefix) || referenceName.hasPrefix(remoteTrackingBranchPrefix),
            referenceName != originHeadReferenceName
        else {
            return nil
        }
        if referenceName.hasPrefix(remoteTrackingBranchPrefix) {
            let remoteAndBranch = String(referenceName.dropFirst(remoteTrackingBranchPrefix.count))
            guard let separator = remoteAndBranch.firstIndex(of: "/"),
                !remoteAndBranch[remoteAndBranch.index(after: separator)...].isEmpty,
                remoteAndBranch[remoteAndBranch.index(after: separator)...] != "HEAD"
            else {
                return nil
            }
        }
        return referenceName
    }

    private static func remoteTrackingBranchName(from referenceName: String, requiredRemote: String) -> String? {
        let prefix = "\(Self.remoteTrackingBranchPrefix)\(requiredRemote)/"
        guard referenceName.hasPrefix(prefix) else {
            return nil
        }
        let branchName = String(referenceName.dropFirst(prefix.count))
        guard !branchName.isEmpty, branchName != "HEAD" else {
            return nil
        }
        return branchName
    }

    private static func makeTarget(
        referenceName: String,
        branchType: git_branch_t
    ) -> GitReviewComparisonBranchTarget? {
        if branchType == GIT_BRANCH_LOCAL, referenceName.hasPrefix(localBranchPrefix) {
            let branchName = String(referenceName.dropFirst(localBranchPrefix.count))
            guard !branchName.isEmpty else { return nil }
            return .local(branchName: branchName, oid: "")
        }
        guard branchType == GIT_BRANCH_REMOTE,
            referenceName.hasPrefix(remoteTrackingBranchPrefix)
        else {
            return nil
        }
        let remoteAndBranch = String(referenceName.dropFirst(remoteTrackingBranchPrefix.count))
        guard let separator = remoteAndBranch.firstIndex(of: "/") else { return nil }
        let remoteName = String(remoteAndBranch[..<separator])
        let branchName = String(remoteAndBranch[remoteAndBranch.index(after: separator)...])
        guard !remoteName.isEmpty, !branchName.isEmpty, branchName != "HEAD" else { return nil }
        return .remoteTracking(remoteName: remoteName, branchName: branchName, oid: "")
    }

    private static func branchType(for referenceName: String) -> git_branch_t {
        referenceName.hasPrefix(localBranchPrefix) ? GIT_BRANCH_LOCAL : GIT_BRANCH_REMOTE
    }

    private func rolePriority(
        referenceName: String,
        defaultReferenceName: String?,
        currentReferenceName: String?
    ) -> Int {
        if referenceName == defaultReferenceName { return 0 }
        if referenceName == currentReferenceName { return 1 }
        return 2
    }
}

extension GitReviewComparisonBranchTarget {
    fileprivate func withOID(_ oid: String) -> Self {
        switch self {
        case .local(let branchName, _):
            return .local(branchName: branchName, oid: oid)
        case .remoteTracking(let remoteName, let branchName, _):
            return .remoteTracking(remoteName: remoteName, branchName: branchName, oid: oid)
        }
    }
}
