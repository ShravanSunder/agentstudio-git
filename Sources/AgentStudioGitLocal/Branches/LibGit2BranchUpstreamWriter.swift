import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Writes `branch.<name>.remote` and `branch.<name>.merge` together, as `git branch --track` does, into the
/// repository-wide configuration under one config lock. It never goes to a worktree's `config.worktree`, and it
/// does not require the remote-tracking ref to exist yet.
struct LibGit2BranchUpstreamWriter {
    let lockObserver: LibGit2BranchAttachLockObserver

    func write(
        _ upstream: GitBranchUpstream,
        branchName: String,
        repository: OpaquePointer
    ) throws(GitDataPlaneError) {
        var configuration: OpaquePointer?
        let configurationResult = git_repository_config(&configuration, repository)
        guard configurationResult >= 0, let configuration else {
            throw LibGit2ErrorCapture.failure(code: configurationResult)
        }
        defer { git_config_free(configuration) }
        var local: OpaquePointer?
        let levelResult = git_config_open_level(&local, configuration, GIT_CONFIG_LEVEL_LOCAL)
        guard levelResult >= 0, let local else {
            throw LibGit2ErrorCapture.failure(code: levelResult)
        }
        defer { git_config_free(local) }

        let configurationLock: GitLockFact
        do {
            configurationLock = try LibGit2LockPathResolver.fact(for: .config, repository: repository)
        } catch let error as GitDataPlaneError {
            throw error
        } catch {
            throw .unsupported(message: String(describing: error))
        }
        lockObserver.attempting([configurationLock])
        var transaction: OpaquePointer?
        errno = 0
        let lockResult = git_config_lock(&transaction, local)
        let lockErrorNumber = errno
        guard lockResult >= 0, let transactionHandle = transaction else {
            lockObserver.failed([configurationLock])
            throw LibGit2ErrorCapture.failure(
                code: lockResult, lockFacts: [configurationLock], systemErrorCode: lockErrorNumber)
        }
        defer {
            if let transaction {
                git_transaction_free(transaction)
            }
        }
        lockObserver.acquired(configurationLock)
        for (key, value) in [
            ("branch.\(branchName).remote", upstream.remoteName),
            ("branch.\(branchName).merge", "refs/heads/\(upstream.branchName)"),
        ] {
            let setResult = key.withCString { keyPointer in
                value.withCString { git_config_set_string(local, keyPointer, $0) }
            }
            guard setResult >= 0 else {
                throw LibGit2ErrorCapture.failure(code: setResult)
            }
        }
        errno = 0
        let commitResult = git_transaction_commit(transactionHandle)
        let commitErrorNumber = errno
        guard commitResult >= 0 else {
            lockObserver.failed([configurationLock])
            throw LibGit2ErrorCapture.failure(
                code: commitResult, lockFacts: [configurationLock], systemErrorCode: commitErrorNumber)
        }
        git_transaction_free(transactionHandle)
        transaction = nil
    }
}
