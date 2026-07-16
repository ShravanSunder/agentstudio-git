import AgentStudioGitContracts
import CLibGit2Local
import Foundation

public struct LibGit2AgentStudioGitDiscoveryReadClient: AgentStudioGitDiscoveryReadClient {
    private let runtime: LibGit2Runtime

    public init() {
        self.init(runtime: .shared)
    }

    init(runtime: LibGit2Runtime) {
        self.runtime = runtime
    }

    public func readDiscoveryCandidate(_ request: GitDiscoveryReadRequest) async -> GitDiscoveryReadOutcome {
        await performDiscoveryRead(request)
    }

    @concurrent
    private nonisolated func performDiscoveryRead(_ request: GitDiscoveryReadRequest) async -> GitDiscoveryReadOutcome {
        do {
            try runtime.ensureInitialized()
        } catch {
            return .failed(discoveryFailure(from: error))
        }

        var repository: OpaquePointer?
        let openResult = request.candidatePath.path.withCString { pathPointer in
            git_repository_open_ext(
                &repository,
                pathPointer,
                GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue,
                nil
            )
        }
        guard openResult >= 0, let repository else {
            return discoveryOpenFailure(code: openResult)
        }
        defer { git_repository_free(repository) }

        do {
            return try discoveryOutcome(repository: repository, request: request)
        } catch {
            return .failed(discoveryFailure(from: error))
        }
    }

    private nonisolated func discoveryOutcome(
        repository: OpaquePointer,
        request: GitDiscoveryReadRequest
    ) throws -> GitDiscoveryReadOutcome {
        guard git_repository_is_bare(repository) == 0 else {
            return .notRepository(.bareRepository)
        }

        let canonicalGitDirectory = try requiredGitURL(
            git_repository_path(repository),
            label: "discovery Git directory"
        )
        let canonicalCommonDirectory = try requiredGitURL(
            git_repository_commondir(repository),
            label: "discovery common directory"
        )
        let canonicalWorktreePath = canonicalWorktreeURL(
            for: try requiredGitURL(
                git_repository_workdir(repository),
                label: "discovery worktree directory"
            )
        )
        let canonicalCandidatePath = canonicalWorktreeURL(for: request.candidatePath)
        let mainWorktreePath =
            canonicalCommonDirectory.lastPathComponent == ".git"
            ? canonicalCommonDirectory.deletingLastPathComponent()
            : nil
        let repositoryIdentity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "common:\(canonicalCommonDirectory.path)"),
            canonicalCommonDirectory: canonicalCommonDirectory,
            mainWorktreePath: mainWorktreePath
        )
        let registration: GitDiscoveryWorktreeRegistration
        do {
            registration = try discoveryRegistration(repository: repository)
        } catch is GitDiscoveryInvalidWorktreeRegistration {
            return .notRepository(.invalidWorktreeRegistration)
        }

        return .validated(
            GitDiscoveryReadEvidence(
                canonicalCandidatePath: canonicalCandidatePath,
                canonicalWorktreePath: canonicalWorktreePath,
                canonicalGitDirectory: canonicalGitDirectory,
                canonicalCommonDirectory: canonicalCommonDirectory,
                repositoryIdentity: repositoryIdentity,
                registration: registration
            )
        )
    }

    private nonisolated func discoveryRegistration(
        repository: OpaquePointer
    ) throws -> GitDiscoveryWorktreeRegistration {
        guard git_repository_is_worktree(repository) != 0 else {
            return .main
        }

        var worktree: OpaquePointer?
        let openResult = git_worktree_open_from_repository(&worktree, repository)
        guard openResult >= 0, let worktree else {
            throw LibGit2ErrorCapture.failure(code: openResult)
        }
        defer { git_worktree_free(worktree) }

        let validationResult = git_worktree_validate(worktree)
        guard validationResult >= 0 else {
            throw GitDiscoveryInvalidWorktreeRegistration()
        }
        let name = try requiredGitString(git_worktree_name(worktree), label: "discovery worktree name")
        return .linked(name: name, lockState: try discoveryLockState(worktree: worktree))
    }

    private nonisolated func discoveryLockState(
        worktree: OpaquePointer
    ) throws -> GitDiscoveryLinkedWorktreeLockState {
        var reasonBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
        let lockResult = git_worktree_is_locked(&reasonBuffer, worktree)
        defer { git_buf_dispose(&reasonBuffer) }
        guard lockResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: lockResult)
        }
        guard lockResult > 0 else {
            return .unlocked
        }
        guard let reasonPointer = reasonBuffer.ptr else {
            return .lockedWithoutReason
        }
        let reason = String(cString: reasonPointer).trimmingCharacters(in: .newlines)
        return reason.isEmpty ? .lockedWithoutReason : .locked(reason: reason)
    }

    private nonisolated func discoveryOpenFailure(code: Int32) -> GitDiscoveryReadOutcome {
        if code == GIT_ENOTFOUND.rawValue {
            return .notRepository(.exactCandidateIsNotRepository)
        }
        let capturedError = LibGit2ErrorCapture.capture(code: code)
        if code == GIT_EINVALID.rawValue || capturedError.klass == GIT_ERROR_REPOSITORY.rawValue {
            return .notRepository(.invalidRepository)
        }
        return .failed(
            GitDiscoveryReadFailure(
                code: capturedError.code,
                errorClass: capturedError.klass,
                message: capturedError.message
            )
        )
    }

    private nonisolated func discoveryFailure(from error: Error) -> GitDiscoveryReadFailure {
        guard case GitDataPlaneError.libgit2Failure(let code, let errorClass, let message) = error else {
            return GitDiscoveryReadFailure(code: -1, errorClass: 0, message: String(describing: error))
        }
        return GitDiscoveryReadFailure(code: code, errorClass: errorClass, message: message)
    }
}

private struct GitDiscoveryInvalidWorktreeRegistration: Error {}
