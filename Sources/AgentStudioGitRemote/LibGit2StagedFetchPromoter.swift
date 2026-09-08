import AgentStudioGitContracts
import CLibGit2Local
import Foundation

enum LibGit2StagedFetchPromoter {
    private enum ExpectedReference: Equatable {
        case absent
        case oid(String)
    }

    @concurrent nonisolated static func promote(
        _ stagedFetch: GitStagedFetchResult
    ) async throws(GitDataPlaneError) {
        let initializationResult = git_libgit2_init()
        guard initializationResult >= 0 else {
            throw libGit2Failure(code: initializationResult, fallback: "could not initialize libgit2")
        }
        defer { git_libgit2_shutdown() }

        var repository: OpaquePointer?
        let openResult = stagedFetch.snapshot.repositoryCommonDirectory.path.withCString { path in
            git_repository_open_bare(&repository, path)
        }
        guard openResult >= 0, let repository else {
            throw libGit2Failure(code: openResult, fallback: "could not open repository common directory")
        }
        defer { git_repository_free(repository) }

        var transaction: OpaquePointer?
        let transactionResult = git_transaction_new(&transaction, repository)
        guard transactionResult >= 0, let transaction else {
            throw libGit2Failure(code: transactionResult, fallback: "could not create ref transaction")
        }
        defer { git_transaction_free(transaction) }

        let plan = try makePlan(stagedFetch)
        for refName in plan.lockedRefNames {
            let lockResult = refName.withCString { git_transaction_lock_ref(transaction, $0) }
            guard lockResult >= 0 else {
                throw libGit2Failure(code: lockResult, fallback: "could not lock ref for promotion")
            }
        }
        for (refName, expectedReference) in plan.expectedReferences {
            try requireExpectedReference(
                repository: repository,
                refName: refName,
                expectedReference: expectedReference
            )
        }
        for (refName, targetOID) in plan.targets.sorted(by: { $0.key < $1.key }) {
            var oid = try parseOID(targetOID)
            let setResult = refName.withCString { refNamePointer in
                git_transaction_set_target(transaction, refNamePointer, &oid, nil, nil)
            }
            guard setResult >= 0 else {
                throw libGit2Failure(code: setResult, fallback: "could not stage ref target")
            }
        }
        for refName in plan.removedRefNames {
            let removeResult = refName.withCString { git_transaction_remove(transaction, $0) }
            guard removeResult >= 0 else {
                throw libGit2Failure(code: removeResult, fallback: "could not stage ref deletion")
            }
        }
        let commitResult = git_transaction_commit(transaction)
        guard commitResult >= 0 else {
            throw libGit2Failure(code: commitResult, fallback: "could not commit ref promotion")
        }
    }

    private struct PromotionPlan {
        let expectedReferences: [(String, ExpectedReference)]
        let targets: [String: String]
        let removedRefNames: [String]

        var lockedRefNames: [String] {
            Array(
                Set(expectedReferences.map(\.0))
                    .union(targets.keys)
                    .union(removedRefNames)
            ).sorted()
        }
    }

    private static func makePlan(
        _ stagedFetch: GitStagedFetchResult
    ) throws(GitDataPlaneError) -> PromotionPlan {
        var expectedReferences: [String: ExpectedReference] = [:]
        var targets: [String: String] = [:]
        var removedRefNames = Set<String>()

        func require(_ refName: String, _ expectedReference: ExpectedReference) throws(GitDataPlaneError) {
            if let current = expectedReferences[refName], current != expectedReference {
                throw GitDataPlaneError.unsupported(message: "promotion plan contains conflicting ref evidence")
            }
            expectedReferences[refName] = expectedReference
        }

        if let promotionGuard = stagedFetch.promotionGuard {
            try require(promotionGuard.refName, .oid(promotionGuard.expectedOID))
            removedRefNames.insert(promotionGuard.refName)
        }
        for update in stagedFetch.updates {
            try require(
                update.canonicalRefName,
                update.expectedOldOID.map(ExpectedReference.oid) ?? .absent
            )
            try require(update.stagingRefName, .oid(update.newOID))
            targets[update.canonicalRefName] = update.newOID
            removedRefNames.insert(update.stagingRefName)
        }
        for verification in stagedFetch.verifications {
            try require(verification.canonicalRefName, .oid(verification.expectedOID))
            try require(verification.stagingRefName, .oid(verification.expectedOID))
            removedRefNames.insert(verification.stagingRefName)
        }
        for deletion in stagedFetch.deletions {
            try require(deletion.canonicalRefName, .oid(deletion.expectedOldOID))
            removedRefNames.insert(deletion.canonicalRefName)
        }
        return PromotionPlan(
            expectedReferences: expectedReferences.sorted(by: { $0.key < $1.key }),
            targets: targets,
            removedRefNames: removedRefNames.sorted()
        )
    }

    private static func requireExpectedReference(
        repository: OpaquePointer,
        refName: String,
        expectedReference: ExpectedReference
    ) throws(GitDataPlaneError) {
        var reference: OpaquePointer?
        let lookupResult = refName.withCString { git_reference_lookup(&reference, repository, $0) }
        switch expectedReference {
        case .absent:
            guard lookupResult == GIT_ENOTFOUND.rawValue else {
                if lookupResult >= 0, let reference { git_reference_free(reference) }
                if lookupResult < 0 {
                    throw libGit2Failure(code: lookupResult, fallback: "could not verify absent ref")
                }
                throw GitDataPlaneError.unsupported(message: "canonical ref appeared before promotion")
            }
        case .oid(let expectedOID):
            guard lookupResult >= 0, let reference else {
                throw libGit2Failure(code: lookupResult, fallback: "required ref disappeared before promotion")
            }
            defer { git_reference_free(reference) }
            guard let actualOID = git_reference_target(reference) else {
                throw GitDataPlaneError.unsupported(message: "promotion requires direct refs")
            }
            var parsedExpectedOID = try parseOID(expectedOID)
            guard git_oid_equal(actualOID, &parsedExpectedOID) == 1 else {
                throw GitDataPlaneError.unsupported(message: "ref changed before promotion")
            }
        }
    }

    private static func parseOID(_ value: String) throws(GitDataPlaneError) -> git_oid {
        var oid = git_oid()
        let parseResult = value.withCString { git_oid_fromstr(&oid, $0) }
        guard parseResult >= 0 else {
            throw libGit2Failure(code: parseResult, fallback: "could not parse promotion OID")
        }
        return oid
    }

    private static func libGit2Failure(code: Int32, fallback: String) -> GitDataPlaneError {
        guard let error = git_error_last() else {
            return .libgit2Failure(code: code, klass: 0, message: fallback)
        }
        return .libgit2Failure(
            code: code,
            klass: Int32(error.pointee.klass),
            message: error.pointee.message.map { String(cString: $0) } ?? fallback
        )
    }
}
