import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// The branch a new worktree ends up on, with the commits the caller pinned when it resolved the request.
enum LibGit2BranchAttachTarget: Equatable, Sendable {
    case newBranch(referenceName: String, commit: String)
    case existingBranch(referenceName: String, expectedTip: String, fastForwardTo: String?)

    var referenceName: String {
        switch self {
        case .newBranch(let referenceName, _), .existingBranch(let referenceName, _, _):
            referenceName
        }
    }
}

/// Why the locked attach changed nothing. Each caller maps these into its own error union.
enum LibGit2BranchAttachRefusal: Error, Equatable, Sendable {
    case checkedOut(worktreePath: URL)
    case moved
    case alreadyExists
    case gitFailure(GitDataPlaneError)
}

/// A reference change that landed, reported as soon as it is known so the caller can journal its undo.
enum LibGit2BranchAttachEffect: Equatable, Sendable {
    case created(referenceName: String, commit: String)
    case fastForwarded(referenceName: String, from: String, to: String)
}

/// Lock lifecycle callbacks, so a caller with lock residue accounting can classify the files this attach takes.
struct LibGit2BranchAttachLockObserver: Sendable {
    static let untracked = Self(attempting: { _ in }, acquired: { _ in }, failed: { _ in })

    let attempting: @Sendable ([GitLockFact]) -> Void
    let acquired: @Sendable (GitLockFact) -> Void
    let failed: @Sendable ([GitLockFact]) -> Void
}

struct LibGit2BranchAttachRequest {
    /// Any worktree of the repository; branch use is read across every worktree it has.
    let repositoryPath: URL
    /// The repository whose ref database takes the transaction. With `attachingHead`, its own `HEAD` is pointed at
    /// the branch in the same transaction.
    let transactionRepository: OpaquePointer
    let target: LibGit2BranchAttachTarget
    let attachingHead: Bool
}

/// The one branch attach both worktree creators share. Under the branch's native ref lock it re-reads branch
/// use, compares the tip with the pinned expectation (or proves a new name is free), writes the creation or
/// fast-forward, optionally points a worktree `HEAD` at the branch, and commits. The writer lane only orders
/// callers inside one process; this lock is what orders two processes attaching the same branch.
struct LibGit2BranchAttach {
    let request: LibGit2BranchAttachRequest
    let lockObserver: LibGit2BranchAttachLockObserver

    func run<Failure: Error>(
        refusal: (LibGit2BranchAttachRefusal) -> Failure,
        afterReferenceLocked: (String) throws(Failure) -> Void,
        landed: (LibGit2BranchAttachEffect) -> Void
    ) throws(Failure) {
        let repository = request.transactionRepository
        let referenceName = request.target.referenceName
        let referenceLock = try lockFact(.reference(name: referenceName), refusal: refusal)
        var transaction: OpaquePointer?
        let transactionResult = git_transaction_new(&transaction, repository)
        guard transactionResult >= 0, let transactionHandle = transaction else {
            throw refusal(.gitFailure(LibGit2ErrorCapture.failure(code: transactionResult)))
        }
        defer {
            if let transaction {
                git_transaction_free(transaction)
            }
        }
        try lock(referenceName, fact: referenceLock, transaction: transactionHandle, refusal: refusal)
        try afterReferenceLocked(referenceName)

        let use: GitBranchUse
        do {
            use = try LibGit2BranchUseReader().branchUse(
                GitBranchUseRequest(
                    repositoryPath: request.repositoryPath,
                    branchName: String(referenceName.dropFirst("refs/heads/".count))))
        } catch let error as GitDataPlaneError {
            throw refusal(.gitFailure(error))
        } catch {
            throw refusal(.gitFailure(.unsupported(message: String(describing: error))))
        }
        if case .inUse(let worktreePath) = use {
            throw refusal(.checkedOut(worktreePath: worktreePath))
        }

        let effect = try stageReferenceChange(transactionHandle, refusal: refusal)
        var heldLocks = [referenceLock]
        if request.attachingHead {
            let headLock = try lockFact(.reference(name: "HEAD"), refusal: refusal)
            try lock("HEAD", fact: headLock, transaction: transactionHandle, refusal: refusal)
            heldLocks.append(headLock)
            let message = "agentstudio worktree: attach \(referenceName)"
            let headResult = message.withCString { messagePointer in
                referenceName.withCString { targetPointer in
                    git_transaction_set_symbolic_target(transactionHandle, "HEAD", targetPointer, nil, messagePointer)
                }
            }
            guard headResult >= 0 else {
                throw refusal(.gitFailure(LibGit2ErrorCapture.failure(code: headResult)))
            }
        }

        errno = 0
        let commitResult = git_transaction_commit(transactionHandle)
        let commitErrorNumber = errno
        guard commitResult >= 0 else {
            if let effect, referencePoints(referenceName, at: effect.newTip) {
                landed(effect.value)
            }
            lockObserver.failed(heldLocks)
            throw refusal(
                .gitFailure(
                    LibGit2ErrorCapture.failure(
                        code: commitResult, lockFacts: heldLocks, systemErrorCode: commitErrorNumber)))
        }
        if let effect {
            landed(effect.value)
        }
        git_transaction_free(transactionHandle)
        transaction = nil
    }

    /// Reads the branch under its lock and stages the creation or fast-forward. Returns nil when the branch is
    /// already at its target and only the lock-guarded checks were needed.
    private func stageReferenceChange<Failure: Error>(
        _ transaction: OpaquePointer,
        refusal: (LibGit2BranchAttachRefusal) -> Failure
    ) throws(Failure) -> StagedReferenceChange? {
        let repository = request.transactionRepository
        let referenceName = request.target.referenceName
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString { git_reference_lookup(&reference, repository, $0) }
        defer {
            if let reference {
                git_reference_free(reference)
            }
        }
        guard lookupResult >= 0 || lookupResult == GIT_ENOTFOUND.rawValue else {
            throw refusal(.gitFailure(LibGit2ErrorCapture.failure(code: lookupResult)))
        }
        let currentTip: String? =
            reference.flatMap { reference in
                git_reference_type(reference) == GIT_REFERENCE_DIRECT ? git_reference_target(reference) : nil
            }.map { oidString($0) }

        let message: String
        let staged: StagedReferenceChange
        switch request.target {
        case .newBranch(_, let commit):
            guard reference == nil else {
                throw refusal(.alreadyExists)
            }
            message = "branch: Created from \(commit)"
            staged = StagedReferenceChange(value: .created(referenceName: referenceName, commit: commit), newTip: commit)
        case .existingBranch(_, let expectedTip, let fastForwardTo):
            guard let currentTip, currentTip.lowercased() == expectedTip.lowercased() else {
                throw refusal(.moved)
            }
            guard let fastForwardTo else {
                return nil
            }
            message = "agentstudio worktree: fast-forward to \(fastForwardTo)"
            staged = StagedReferenceChange(
                value: .fastForwarded(referenceName: referenceName, from: expectedTip, to: fastForwardTo),
                newTip: fastForwardTo)
        }
        var newTip = git_oid()
        guard staged.newTip.withCString({ git_oid_fromstr(&newTip, $0) }) >= 0 else {
            throw refusal(.gitFailure(.unsupported(message: "attach target must be a full object identifier")))
        }
        errno = 0
        let setResult = referenceName.withCString { referencePointer in
            message.withCString { messagePointer in
                git_transaction_set_target(transaction, referencePointer, &newTip, nil, messagePointer)
            }
        }
        guard setResult >= 0 else {
            throw refusal(.gitFailure(LibGit2ErrorCapture.failure(code: setResult)))
        }
        return staged
    }

    private func lock<Failure: Error>(
        _ referenceName: String,
        fact: GitLockFact,
        transaction: OpaquePointer,
        refusal: (LibGit2BranchAttachRefusal) -> Failure
    ) throws(Failure) {
        lockObserver.attempting([fact])
        errno = 0
        let lockResult = referenceName.withCString { git_transaction_lock_ref(transaction, $0) }
        let lockErrorNumber = errno
        guard lockResult >= 0 else {
            lockObserver.failed([fact])
            throw refusal(
                .gitFailure(
                    LibGit2ErrorCapture.failure(code: lockResult, lockFacts: [fact], systemErrorCode: lockErrorNumber)))
        }
        lockObserver.acquired(fact)
    }

    private func lockFact<Failure: Error>(
        _ resource: GitLockResource,
        refusal: (LibGit2BranchAttachRefusal) -> Failure
    ) throws(Failure) -> GitLockFact {
        do {
            return try LibGit2LockPathResolver.fact(for: resource, repository: request.transactionRepository)
        } catch let error as GitDataPlaneError {
            throw refusal(.gitFailure(error))
        } catch {
            throw refusal(.gitFailure(.unsupported(message: String(describing: error))))
        }
    }

    private func referencePoints(_ referenceName: String, at commit: String) -> Bool {
        var reference: OpaquePointer?
        let lookupResult = referenceName.withCString {
            git_reference_lookup(&reference, request.transactionRepository, $0)
        }
        guard lookupResult >= 0, let reference else {
            return false
        }
        defer { git_reference_free(reference) }
        return git_reference_target(reference).map { oidString($0).lowercased() == commit.lowercased() } ?? false
    }
}

private struct StagedReferenceChange {
    let value: LibGit2BranchAttachEffect
    let newTip: String
}
