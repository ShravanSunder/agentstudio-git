import AgentStudioGitContracts
import AgentStudioGitLockSupport
import CLibGit2Local
import Darwin
import Foundation

struct LibGit2LocalBranchDeletionWriter: Sendable {
    private let runtime: LibGit2Runtime
    private let worktreeReader: LibGit2WorktreeReader
    private let metadataCleaner: LibGit2BranchMetadataCleaner
    private let transactionControl: GitBranchDeletionTransactionControl
    private let lockResidueObserver: GitLockResidueObserver

    init(
        runtime: LibGit2Runtime = .shared,
        worktreeReader: LibGit2WorktreeReader = LibGit2WorktreeReader(),
        metadataCleaner: LibGit2BranchMetadataCleaner = LibGit2BranchMetadataCleaner(),
        transactionControl: GitBranchDeletionTransactionControl = .live,
        lockResidueObserver: GitLockResidueObserver = .live
    ) {
        self.runtime = runtime
        self.worktreeReader = worktreeReader
        self.metadataCleaner = metadataCleaner
        self.transactionControl = transactionControl
        self.lockResidueObserver = lockResidueObserver
    }

    func deleteLocalBranch(
        _ request: GitDeleteLocalBranchRequest
    ) throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitDeleteLocalBranchResult {
        do {
            try runtime.ensureInitialized()
        } catch let error as GitDataPlaneError {
            throw failure(.gitFailure(error))
        } catch {
            throw failure(.gitFailure(.unsupported(message: "libgit2 initialization failed")))
        }

        let referenceName = "refs/heads/\(request.branchName)"
        guard isValidBranchReferenceName(referenceName) else {
            throw failure(.invalidBranchName)
        }

        var expectedCommitOID = git_oid()
        let parseExpectedCommitResult = request.expectedCommit.withCString {
            git_oid_fromstr(&expectedCommitOID, $0)
        }
        guard parseExpectedCommitResult >= 0 else {
            throw failure(.gitFailure(.unsupported(message: "expectedCommit must be a full object identifier")))
        }

        var repository: OpaquePointer?
        let openResult = request.repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw failure(.gitFailure(repositoryOpenFailure(code: openResult, path: request.repositoryPath)))
        }
        defer { git_repository_free(repository) }

        return try deleteFromOpenRepository(
            request,
            referenceName: referenceName,
            expectedCommitOID: &expectedCommitOID,
            repository: repository
        )
    }

    private func deleteFromOpenRepository(
        _ request: GitDeleteLocalBranchRequest,
        referenceName: String,
        expectedCommitOID: inout git_oid,
        repository: OpaquePointer
    ) throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitDeleteLocalBranchResult {
        let lockFacts: [GitLockFact]
        do {
            lockFacts = [
                try LibGit2LockPathResolver.fact(for: .reference(name: referenceName), repository: repository),
                try LibGit2LockPathResolver.fact(for: .packedRefs, repository: repository),
                try LibGit2LockPathResolver.fact(for: .config, repository: repository),
            ]
        } catch let error as GitDataPlaneError {
            throw failure(.gitFailure(error))
        } catch {
            throw failure(.gitFailure(.unsupported(message: "branch lock paths are unavailable")))
        }

        let outcome: GitBranchDeletionOutcome
        do throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) {
            outcome = try deleteUnderReferenceLock(
                request,
                referenceName: referenceName,
                expectedCommitOID: &expectedCommitOID,
                referenceLockFact: lockFacts[0],
                packedReferencesLockFact: lockFacts[1],
                repository: repository
            )
        } catch {
            throw failure(error.reason, lockResidue: lockResidueObserver.residue(for: lockFacts.map(\.path)))
        }

        return outcome.result(lockResidue: lockResidueObserver.residue(for: lockFacts.map(\.path)))
    }

    private func deleteUnderReferenceLock(
        _ request: GitDeleteLocalBranchRequest,
        referenceName: String,
        expectedCommitOID: inout git_oid,
        referenceLockFact: GitLockFact,
        packedReferencesLockFact: GitLockFact,
        repository: OpaquePointer
    ) throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitBranchDeletionOutcome {
        var transaction: OpaquePointer?
        let transactionResult = git_transaction_new(&transaction, repository)
        guard transactionResult >= 0, let transactionHandle = transaction else {
            throw failure(.gitFailure(LibGit2ErrorCapture.failure(code: transactionResult)))
        }
        defer {
            if let transaction {
                git_transaction_free(transaction)
            }
        }

        // Lock before reading so the expected-commit comparison and removal share the same ref state.
        transactionControl.reachCheckpoint(.beforeReferenceLock)
        errno = 0
        let lockResult = referenceName.withCString { git_transaction_lock_ref(transactionHandle, $0) }
        let lockSystemErrorCode = errno
        guard lockResult >= 0 else {
            let lockError = LibGit2ErrorCapture.failure(
                code: lockResult,
                lockFact: referenceLockFact,
                systemErrorCode: lockSystemErrorCode
            )
            if case .lockHeld = lockError {
                throw failure(.refLockContended)
            }
            throw failure(.gitFailure(lockError))
        }
        transactionControl.reachCheckpoint(.afterReferenceLock)

        switch try assessLockedReference(
            referenceName,
            expectedCommitOID: &expectedCommitOID,
            repository: repository
        ) {
        case .notFound:
            return .retained(.notFound)
        case .moved(let currentCommit):
            return .retained(.moved(currentCommit: currentCommit))
        case .matchesExpectedCommit:
            break
        }

        let checkedOutPaths: [URL]
        do {
            checkedOutPaths = try worktreeReader.worktrees(for: request.repositoryPath)
                .filter { snapshot in
                    snapshot.head?.kind == .branch && snapshot.head?.shortName == request.branchName
                }
                .map(\.canonicalPath)
                .sorted { $0.path < $1.path }
        } catch {
            throw failure(.checkoutUnreadable(worktreePath: nil))
        }
        guard checkedOutPaths.isEmpty else {
            return .retained(.checkedOut(worktreePaths: checkedOutPaths))
        }

        let removeResult = referenceName.withCString { git_transaction_remove(transactionHandle, $0) }
        guard removeResult >= 0 else {
            throw failure(.gitFailure(LibGit2ErrorCapture.failure(code: removeResult)))
        }

        errno = 0
        let commitResult = git_transaction_commit(transactionHandle)
        let commitSystemErrorCode = errno
        let commitError =
            commitResult < 0
            ? deletionCommitFailure(
                code: commitResult,
                referenceLockFact: referenceLockFact,
                packedReferencesLockFact: packedReferencesLockFact,
                systemErrorCode: commitSystemErrorCode
            )
            : nil
        git_transaction_free(transactionHandle)
        transaction = nil

        switch probeReference(referenceName, at: request.repositoryPath) {
        case .absent:
            return .deleted(
                cleanup: cleanAfterDeletion(
                    branchName: request.branchName,
                    referenceName: referenceName,
                    repositoryPath: request.repositoryPath
                ))
        case .present(let reference):
            if let commitError {
                if reference.isDirect, let currentCommit = reference.commitOID,
                    !isEqual(currentCommit, expectedCommitOID)
                {
                    return .retained(.moved(currentCommit: currentCommit))
                }
                return .uncertain(commitError)
            }
            return .deleted(
                cleanup: GitBranchMetadataCleanup(
                    configuration: .leftInPlace(.recreatedMeanwhile),
                    reflog: .leftInPlace(.recreatedMeanwhile)
                ))
        case .failed(let probeError):
            return .uncertain(commitError ?? probeError)
        }
    }

    private func assessLockedReference(
        _ referenceName: String,
        expectedCommitOID: inout git_oid,
        repository: OpaquePointer
    ) throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> LockedBranchAssessment {
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return .notFound
        }
        guard lookupResult >= 0, let reference else {
            throw failure(.gitFailure(LibGit2ErrorCapture.failure(code: lookupResult)))
        }
        defer { git_reference_free(reference) }

        guard git_reference_type(reference) == GIT_REFERENCE_DIRECT,
            let currentCommitOID = git_reference_target(reference)
        else {
            throw failure(.notADirectCommitReference)
        }

        let currentCommit = LibGit2ReviewSupport.oidString(currentCommitOID)
        guard isEqual(currentCommitOID, expectedCommitOID) else {
            return .moved(currentCommit)
        }

        var commitObject: OpaquePointer?
        let objectLookupResult = git_object_lookup(&commitObject, repository, currentCommitOID, GIT_OBJECT_ANY)
        guard objectLookupResult >= 0, let commitObject else {
            if objectLookupResult == GIT_ENOTFOUND.rawValue {
                throw failure(.gitFailure(.requiredObjectNotFound(oid: currentCommit)))
            }
            throw failure(.gitFailure(LibGit2ErrorCapture.failure(code: objectLookupResult)))
        }
        defer { git_object_free(commitObject) }
        guard git_object_type(commitObject) == GIT_OBJECT_COMMIT else {
            throw failure(.notADirectCommitReference)
        }
        return .matchesExpectedCommit
    }

    private func cleanAfterDeletion(
        branchName: String,
        referenceName: String,
        repositoryPath: URL
    ) -> GitBranchMetadataCleanup {
        transactionControl.reachCheckpoint(.beforeCleanupReservation)

        var repository: OpaquePointer?
        let openResult = repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            let deferred = GitBranchMetadataDisposition.leftInPlace(.reservationUnavailable)
            return GitBranchMetadataCleanup(configuration: deferred, reflog: deferred)
        }
        defer { git_repository_free(repository) }

        var reservation: OpaquePointer?
        let transactionResult = git_transaction_new(&reservation, repository)
        guard transactionResult >= 0, let reservationHandle = reservation else {
            let deferred = GitBranchMetadataDisposition.leftInPlace(.reservationUnavailable)
            return GitBranchMetadataCleanup(configuration: deferred, reflog: deferred)
        }
        defer {
            if let reservation {
                git_transaction_free(reservation)
            }
        }

        // The refdb creates this lock path even when the branch is absent; it reserves the name during cleanup.
        let lockResult = referenceName.withCString { git_transaction_lock_ref(reservationHandle, $0) }
        guard lockResult >= 0 else {
            return cleanupDeferredBecauseReferenceExistsOrCouldNotBeReserved(
                referenceName: referenceName,
                repositoryPath: repositoryPath
            )
        }

        transactionControl.reachCheckpoint(.afterCleanupReservation)
        switch probeReference(referenceName, at: repositoryPath) {
        case .absent:
            break
        case .present:
            let deferred = GitBranchMetadataDisposition.leftInPlace(.recreatedMeanwhile)
            return GitBranchMetadataCleanup(configuration: deferred, reflog: deferred)
        case .failed:
            let deferred = GitBranchMetadataDisposition.leftInPlace(.reservationUnavailable)
            return GitBranchMetadataCleanup(configuration: deferred, reflog: deferred)
        }

        return metadataCleaner.clean(
            branchName: branchName,
            referenceName: referenceName,
            repository: repository
        )
    }

    private func cleanupDeferredBecauseReferenceExistsOrCouldNotBeReserved(
        referenceName: String,
        repositoryPath: URL
    ) -> GitBranchMetadataCleanup {
        let reason: GitBranchMetadataLeftInPlaceReason
        switch probeReference(referenceName, at: repositoryPath) {
        case .present:
            reason = .recreatedMeanwhile
        case .absent, .failed:
            reason = .reservationUnavailable
        }
        let deferred = GitBranchMetadataDisposition.leftInPlace(reason)
        return GitBranchMetadataCleanup(configuration: deferred, reflog: deferred)
    }

    private func probeReference(_ referenceName: String, at repositoryPath: URL) -> BranchReferenceProbe {
        var repository: OpaquePointer?
        let openResult = repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            return .failed(repositoryOpenFailure(code: openResult, path: repositoryPath))
        }
        defer { git_repository_free(repository) }

        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        if lookupResult == GIT_ENOTFOUND.rawValue {
            return .absent
        }
        guard lookupResult >= 0, let reference else {
            return .failed(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_reference_free(reference) }

        let isDirect = git_reference_type(reference) == GIT_REFERENCE_DIRECT
        let commitOID = isDirect ? git_reference_target(reference).map(LibGit2ReviewSupport.oidString) : nil
        return .present(BranchReferenceSnapshot(isDirect: isDirect, commitOID: commitOID))
    }

    private func isValidBranchReferenceName(_ referenceName: String) -> Bool {
        guard !referenceName.utf8.contains(0) else {
            return false
        }
        var isValid: Int32 = 0
        let result = referenceName.withCString { git_reference_name_is_valid(&isValid, $0) }
        return result >= 0 && isValid != 0
    }

    private func deletionCommitFailure(
        code: Int32,
        referenceLockFact: GitLockFact,
        packedReferencesLockFact: GitLockFact,
        systemErrorCode: Int32
    ) -> GitDataPlaneError {
        if code == GIT_ELOCKED.rawValue {
            if lockResidueObserver.status(of: packedReferencesLockFact.path) == .present {
                return .lockHeld(packedReferencesLockFact)
            }
            if systemErrorCode == EACCES {
                return .permissionDenied(path: deniedDirectory(for: [packedReferencesLockFact, referenceLockFact]))
            }
            return .lockUnidentified(.packedRefs)
        }

        guard systemErrorCode == EACCES else {
            return LibGit2ErrorCapture.failure(code: code)
        }
        return .permissionDenied(path: deniedDirectory(for: [packedReferencesLockFact, referenceLockFact]))
    }

    private func deniedDirectory(for lockFacts: [GitLockFact]) -> URL? {
        for lockFact in lockFacts {
            let directory = lockFact.path.deletingLastPathComponent()
            let accessResult = directory.path.withCString { access($0, W_OK | X_OK) }
            if accessResult != 0, errno == EACCES {
                return directory
            }
        }
        return nil
    }

    private func isEqual(_ currentCommitOID: UnsafePointer<git_oid>, _ expectedCommitOID: git_oid) -> Bool {
        var mutableExpectedCommitOID = expectedCommitOID
        return withUnsafePointer(to: &mutableExpectedCommitOID) { git_oid_cmp(currentCommitOID, $0) == 0 }
    }

    private func isEqual(_ currentCommit: String, _ expectedCommitOID: git_oid) -> Bool {
        var parsedCurrentCommitOID = git_oid()
        let parseResult = currentCommit.withCString { git_oid_fromstr(&parsedCurrentCommitOID, $0) }
        guard parseResult >= 0 else {
            return false
        }
        return isEqual(&parsedCurrentCommitOID, expectedCommitOID)
    }

    private func isEqual(_ currentCommitOID: inout git_oid, _ expectedCommitOID: git_oid) -> Bool {
        var mutableExpectedCommitOID = expectedCommitOID
        return withUnsafePointer(to: &currentCommitOID) { currentPointer in
            withUnsafePointer(to: &mutableExpectedCommitOID) { expectedPointer in
                git_oid_cmp(currentPointer, expectedPointer) == 0
            }
        }
    }

    private func failure(
        _ reason: GitDeleteLocalBranchErrorReason,
        lockResidue: [URL] = []
    ) -> GitLockedOperationFailure<GitDeleteLocalBranchErrorReason> {
        GitLockedOperationFailure(reason: reason, lockResidue: lockResidue)
    }

}

private enum LockedBranchAssessment {
    case notFound
    case moved(String)
    case matchesExpectedCommit
}

private enum BranchReferenceProbe {
    case absent
    case present(BranchReferenceSnapshot)
    case failed(GitDataPlaneError)
}

private struct BranchReferenceSnapshot {
    let isDirect: Bool
    let commitOID: String?
}

private enum GitBranchDeletionOutcome {
    case deleted(cleanup: GitBranchMetadataCleanup)
    case retained(GitBranchRetentionReason)
    case uncertain(GitDataPlaneError)

    func result(lockResidue: [URL]) -> GitDeleteLocalBranchResult {
        switch self {
        case .deleted(let cleanup):
            .deleted(cleanup: cleanup, lockResidue: lockResidue)
        case .retained(let reason):
            .retained(reason: reason, lockResidue: lockResidue)
        case .uncertain(let error):
            .uncertain(error: error, lockResidue: lockResidue)
        }
    }
}
