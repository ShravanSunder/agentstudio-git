import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git native lock facts")
struct GitLockIntegrationTests {
    @Test("index write reports the observed worktree index lock")
    func indexWriteReportsTheObservedWorktreeIndexLock() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-index-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(
            for: .index(worktreePath: fixture.repositoryPath),
            repositoryPath: fixture.repositoryPath
        )
        try Data().write(to: lockFact.path)

        let error = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            var index: OpaquePointer?
            let openResult = git_repository_index(&index, repository)
            guard openResult >= 0, let index else {
                throw LibGit2ErrorCapture.failure(code: openResult)
            }
            defer { git_index_free(index) }

            let writeResult = git_index_write(index)
            #expect(writeResult == Int32(GIT_ELOCKED.rawValue))
            return LibGit2ErrorCapture.failure(code: writeResult, lockFact: lockFact)
        }

        #expect(error == .lockHeld(lockFact))
    }

    @Test("native ref transaction reports the observed loose ref lock")
    func refTransactionReportsTheObservedLooseRefLock() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ref-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(
            for: .reference(name: "refs/heads/main"),
            repositoryPath: fixture.repositoryPath
        )
        try Data().write(to: lockFact.path)

        let error = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            var transaction: OpaquePointer?
            let createResult = git_transaction_new(&transaction, repository)
            guard createResult >= 0, let transaction else {
                throw LibGit2ErrorCapture.failure(code: createResult)
            }
            defer { git_transaction_free(transaction) }

            let lockResult = "refs/heads/main".withCString { git_transaction_lock_ref(transaction, $0) }
            #expect(lockResult == Int32(GIT_ELOCKED.rawValue))
            return LibGit2ErrorCapture.failure(code: lockResult, lockFact: lockFact)
        }

        #expect(error == .lockHeld(lockFact))
    }

    @Test("native reference update reports the observed packed refs lock")
    func referenceUpdateReportsTheObservedPackedRefsLock() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-packed-refs-lock")
        defer { fixture.remove() }
        try fixture.git.run("pack-refs", "--all", "--prune")
        let lockFact = try repositoryLockFact(for: .packedRefs, repositoryPath: fixture.repositoryPath)
        try Data().write(to: lockFact.path)

        let error = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            var reference: OpaquePointer?
            let lookupResult = "refs/heads/main".withCString {
                git_reference_lookup(&reference, repository, $0)
            }
            guard lookupResult >= 0, let reference else {
                throw LibGit2ErrorCapture.failure(code: lookupResult)
            }
            defer { git_reference_free(reference) }

            let deleteResult = git_reference_delete(reference)
            #expect(deleteResult == Int32(GIT_ELOCKED.rawValue))
            return LibGit2ErrorCapture.failure(code: deleteResult, lockFact: lockFact)
        }

        #expect(error == .lockHeld(lockFact))
    }

    @Test("native config update reports the observed config lock")
    func configUpdateReportsTheObservedConfigLock() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-config-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(for: .config, repositoryPath: fixture.repositoryPath)
        try Data().write(to: lockFact.path)

        let error = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            var configuration: OpaquePointer?
            let openResult = git_repository_config(&configuration, repository)
            guard openResult >= 0, let configuration else {
                throw LibGit2ErrorCapture.failure(code: openResult)
            }
            defer { git_config_free(configuration) }

            let setResult = "worktreeLifecycle.lockTest".withCString { key in
                "value".withCString { value in
                    git_config_set_string(configuration, key, value)
                }
            }
            #expect(setResult == Int32(GIT_ELOCKED.rawValue))
            return LibGit2ErrorCapture.failure(code: setResult, lockFact: lockFact)
        }

        #expect(error == .lockHeld(lockFact))
    }

    @Test("ELOCKED without an inspectable exact file remains unidentified")
    func lockedResultWithoutAnInspectableFileRemainsUnidentified() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unidentified-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(
            for: .reference(name: "refs/heads/main"),
            repositoryPath: fixture.repositoryPath
        )

        let error = LibGit2ErrorCapture.failure(code: Int32(GIT_ELOCKED.rawValue), lockFact: lockFact)

        #expect(error == .lockUnidentified(.reference(name: "refs/heads/main")))
    }

    @Test("permission errors do not become removable lock facts")
    func permissionErrorDoesNotBecomeRemovableLockFact() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-permission-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(
            for: .index(worktreePath: fixture.repositoryPath),
            repositoryPath: fixture.repositoryPath
        )

        let error = LibGit2ErrorCapture.failure(
            code: Int32(GIT_ELOCKED.rawValue),
            lockFact: lockFact,
            systemErrorCode: EACCES
        )

        #expect(error == .permissionDenied(path: lockFact.path.deletingLastPathComponent()))
    }

    @Test("linked worktree index locks are per-worktree and branch locks are common")
    func linkedWorktreeIndexLocksArePerWorktreeAndBranchLocksAreCommon() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-linked-lock-paths")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-locks", branch: "feature/linked-locks")

        let paths = try LibGit2ReviewSupport.withRepository(at: linkedPath) { repository in
            guard let gitDirectoryPointer = git_repository_path(repository),
                let commonDirectoryPointer = git_repository_commondir(repository)
            else {
                throw GitDataPlaneError.unsupported(message: "linked repository directories unavailable")
            }
            let gitDirectory = URL(fileURLWithPath: String(cString: gitDirectoryPointer), isDirectory: true)
                .standardizedFileURL
            let commonDirectory = URL(fileURLWithPath: String(cString: commonDirectoryPointer), isDirectory: true)
                .standardizedFileURL
            let indexFact = try LibGit2LockPathResolver.fact(
                for: .index(worktreePath: linkedPath),
                repository: repository
            )
            let branchFact = try LibGit2LockPathResolver.fact(
                for: .reference(name: "refs/heads/feature/linked-locks"),
                repository: repository
            )
            return (
                gitDirectory: gitDirectory,
                commonDirectory: commonDirectory,
                indexFact: indexFact,
                branchFact: branchFact
            )
        }

        #expect(paths.indexFact.path == paths.gitDirectory.appending(path: "index.lock").standardizedFileURL)
        #expect(
            paths.branchFact.path
                == paths.commonDirectory.appending(path: "refs/heads/feature/linked-locks.lock").standardizedFileURL
        )
    }

    @Test("a denied directory write is reported as permission denied")
    func deniedDirectoryWriteIsReportedAsPermissionDenied() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-denied-lock")
        defer { fixture.remove() }
        let lockFact = try repositoryLockFact(for: .config, repositoryPath: fixture.repositoryPath)
        let gitDirectoryPath = lockFact.path.deletingLastPathComponent()
        var originalDirectoryStatus = stat()
        let statResult = gitDirectoryPath.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            Issue.record("could not stat the repository Git directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        let readOnlyMode = originalMode & ~mode_t(0o222)
        guard gitDirectoryPath.path.withCString({ chmod($0, readOnlyMode) }) == 0 else {
            Issue.record("could not make the repository Git directory read-only")
            return
        }
        defer { _ = gitDirectoryPath.path.withCString { chmod($0, originalMode) } }
        #expect(gitDirectoryPath.path.withCString { access($0, W_OK | X_OK) } != 0)
        #expect(errno == EACCES)

        let error = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            var configuration: OpaquePointer?
            let openResult = git_repository_config(&configuration, repository)
            guard openResult >= 0, let configuration else {
                throw LibGit2ErrorCapture.failure(code: openResult)
            }
            defer { git_config_free(configuration) }

            errno = 0
            let setResult = "worktreeLifecycle.permissionTest".withCString { key in
                "value".withCString { value in
                    git_config_set_string(configuration, key, value)
                }
            }
            let systemErrorCode = errno
            #expect(setResult < 0)
            return LibGit2ErrorCapture.failure(
                code: setResult,
                lockFact: lockFact,
                systemErrorCode: systemErrorCode
            )
        }

        #expect(error == .permissionDenied(path: gitDirectoryPath))
    }
}

private func repositoryLockFact(for resource: GitLockResource, repositoryPath: URL) throws -> GitLockFact {
    try LibGit2ReviewSupport.withRepository(at: repositoryPath) { repository in
        try LibGit2LockPathResolver.fact(for: resource, repository: repository)
    }
}
