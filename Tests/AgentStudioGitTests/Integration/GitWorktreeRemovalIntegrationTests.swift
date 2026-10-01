import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git worktree removal integration", .serialized)
struct GitWorktreeRemovalIntegrationTests {
    @Test("remove refuses main, path mismatch, dirty, staged, untracked, and locked worktrees")
    func removeRefusesUnsafeWorktrees() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let mainSnapshot = try #require(
            try await client.worktrees(for: fixture.repositoryPath).first { $0.isMainWorktree })

        try await expectRemovalRefusal(.mainWorktree) {
            try await client.removeWorktree(
                GitRemoveWorktreeRequest(
                    worktreeID: mainSnapshot.id,
                    canonicalPath: mainSnapshot.canonicalPath,
                    removeWorkingDirectory: true,
                    forceDiscardChanges: false
                )
            )
        }

        let mismatchPath = try fixture.addLinkedWorktree(named: "mismatch", branch: "feature/mismatch")
        let mismatchSnapshot = try await snapshot(
            for: mismatchPath, using: client, repositoryPath: fixture.repositoryPath)
        try await expectRemovalRefusal(.pathMismatch) {
            try await client.removeWorktree(
                GitRemoveWorktreeRequest(
                    worktreeID: mismatchSnapshot.id,
                    canonicalPath: fixture.root.appending(path: "elsewhere"),
                    removeWorkingDirectory: true,
                    forceDiscardChanges: false
                )
            )
        }

        let dirtyPath = try fixture.addLinkedWorktree(named: "dirty", branch: "feature/dirty")
        try fixture.write("README.md", contents: "dirty\n", in: dirtyPath)
        try await expectRemovalRefusal(.dirtyTrackedChanges) {
            try await remove(linkedPath: dirtyPath, fixture: fixture, client: client, force: false)
        }

        let stagedPath = try fixture.addLinkedWorktree(named: "staged", branch: "feature/staged")
        try fixture.write("staged.txt", contents: "staged\n", in: stagedPath)
        try fixture.git.run("add", "staged.txt", currentDirectory: stagedPath)
        try await expectRemovalRefusal(.stagedChanges) {
            try await remove(linkedPath: stagedPath, fixture: fixture, client: client, force: false)
        }

        let untrackedPath = try fixture.addLinkedWorktree(named: "untracked", branch: "feature/untracked")
        try fixture.write("untracked.txt", contents: "untracked\n", in: untrackedPath)
        try await expectRemovalRefusal(.untrackedFiles) {
            try await remove(linkedPath: untrackedPath, fixture: fixture, client: client, force: false)
        }

        let lockedPath = try fixture.addLinkedWorktree(named: "remove-locked", branch: "feature/remove-locked")
        let lockedSnapshot = try await snapshot(for: lockedPath, using: client, repositoryPath: fixture.repositoryPath)
        _ = try await client.lockWorktree(
            GitLockWorktreeRequest(worktreeID: lockedSnapshot.id, reason: "do not remove"))
        try await expectRemovalRefusal(.locked) {
            try await remove(linkedPath: lockedPath, fixture: fixture, client: client, force: true)
        }
    }

    @Test("remove reports observed effects for clean and force-discarded worktrees")
    func removeReportsObservedCompleteRemoval() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let cleanPath = try fixture.addLinkedWorktree(named: "clean", branch: "feature/clean")
        let dirtyPath = try fixture.addLinkedWorktree(named: "force-dirty", branch: "feature/force-dirty")
        let cleanSnapshot = try await snapshot(for: cleanPath, using: client, repositoryPath: fixture.repositoryPath)
        let dirtySnapshot = try await snapshot(for: dirtyPath, using: client, repositoryPath: fixture.repositoryPath)
        try fixture.write("README.md", contents: "forced\n", in: dirtyPath)

        let cleanResult = try await remove(linkedPath: cleanPath, fixture: fixture, client: client, force: false)
        let dirtyResult = try await remove(linkedPath: dirtyPath, fixture: fixture, client: client, force: true)
        let worktreeList = try fixture.git.run("worktree", "list", "--porcelain")

        #expect(cleanResult.removedWorktreeID == cleanSnapshot.id)
        #expect(cleanResult.effects.administration == .removed)
        #expect(cleanResult.effects.workingDirectory == .removed)
        #expect(cleanResult.effects.failure == nil)
        #expect(cleanResult.effects.lockResidue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cleanSnapshot.gitDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: cleanPath.path))
        #expect(!worktreeList.contains("worktree \(cleanPath.path)\n"))

        #expect(dirtyResult.removedWorktreeID == dirtySnapshot.id)
        #expect(dirtyResult.effects.administration == .removed)
        #expect(dirtyResult.effects.workingDirectory == .removed)
        #expect(dirtyResult.effects.failure == nil)
        #expect(dirtyResult.effects.lockResidue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dirtySnapshot.gitDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: dirtyPath.path))
        #expect(!worktreeList.contains("worktree \(dirtyPath.path)\n"))
    }

    @Test("remove without directory deletion reports notRequested")
    func removeWithoutDirectoryDeletionReportsNotRequested() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedPath = try fixture.addLinkedWorktree(named: "metadata-only", branch: "feature/metadata-only")
        let linkedSnapshot = try await snapshot(
            for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)

        let result = try await remove(
            linkedPath: linkedPath,
            fixture: fixture,
            client: client,
            force: false,
            removeWorkingDirectory: false
        )

        #expect(result.effects.administration == .removed)
        #expect(result.effects.workingDirectory == .notRequested)
        #expect(result.effects.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: linkedSnapshot.gitDirectory.path))
        #expect(FileManager.default.fileExists(atPath: linkedPath.path))
    }

    @Test("remove reports a partial administration failure and retains the directory")
    func removeReportsPartialAdministrationFailure() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedPath = try fixture.addLinkedWorktree(named: "blocked-admin", branch: "feature/blocked-admin")
        let linkedSnapshot = try await snapshot(
            for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: linkedSnapshot.gitDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: linkedSnapshot.gitDirectory.path
            )
        }

        let result = try await remove(linkedPath: linkedPath, fixture: fixture, client: client, force: true)

        #expect(result.effects.administration == .partial)
        #expect(result.effects.workingDirectory == .retained)
        expectPruneFailure(result.effects.failure)
        #expect(FileManager.default.fileExists(atPath: linkedSnapshot.gitDirectory.path))
        #expect(FileManager.default.fileExists(atPath: linkedPath.path))
    }

    @Test("remove reports a partial directory failure after administration is removed")
    func removeReportsPartialDirectoryFailureAfterAdministrationRemoval() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedPath = try fixture.addLinkedWorktree(named: "blocked-directory", branch: "feature/blocked-directory")
        let linkedSnapshot = try await snapshot(
            for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        let blockedDirectory = linkedPath.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try fixture.write("blocked/file.txt", contents: "blocked\n", in: linkedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path)
        }

        let result = try await client.removeWorktree(
            GitRemoveWorktreeRequest(
                worktreeID: linkedSnapshot.id,
                canonicalPath: linkedSnapshot.canonicalPath,
                removeWorkingDirectory: true,
                forceDiscardChanges: true
            )
        )

        #expect(result.effects.administration == .removed)
        #expect(result.effects.workingDirectory == .partial)
        expectPruneFailure(result.effects.failure)
        #expect(!FileManager.default.fileExists(atPath: linkedSnapshot.gitDirectory.path))
        #expect(FileManager.default.fileExists(atPath: linkedPath.path))
    }

    @Test("remove marks an inaccessible post-prune observation unknown")
    func removeMarksInaccessibleObservationUnknown() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let setupClient = LibGit2AgentStudioGitLocalClient()
        let linkedPath = try fixture.addLinkedWorktree(named: "unknown-admin", branch: "feature/unknown-admin")
        let linkedSnapshot = try await snapshot(
            for: linkedPath, using: setupClient, repositoryPath: fixture.repositoryPath)
        let gitDirectory = linkedSnapshot.gitDirectory.standardizedFileURL
        let pathObserver = GitWorktreeRemovalPathObserver { path in
            guard path.standardizedFileURL == gitDirectory else {
                return inspectGitWorktreeRemovalPath(at: path)
            }
            return .inaccessible
        }
        let writer = LibGit2WorktreeWriter(removalPathObserver: pathObserver)
        let client = LibGit2AgentStudioGitLocalClient(worktreeWriter: writer)

        let result = try await remove(linkedPath: linkedPath, fixture: fixture, client: client, force: false)

        #expect(result.effects.administration == .unknown)
        #expect(result.effects.workingDirectory == .removed)
        #expect(result.effects.failure == .observationFailed)
        #expect(result.effects.lockResidue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: linkedSnapshot.gitDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: linkedPath.path))
    }

    @Test("remove reports a retained directory when libgit2 skips a missing gitlink")
    func removeReportsObservedDirectoryWhenGitlinkIsMissing() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedPath = try fixture.addLinkedWorktree(named: "missing-gitlink", branch: "feature/missing-gitlink")
        let linkedSnapshot = try await snapshot(
            for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        let gitlinkPath = linkedPath.appending(path: ".git")
        try FileManager.default.removeItem(at: gitlinkPath)

        let result = try await client.removeWorktree(
            GitRemoveWorktreeRequest(
                worktreeID: linkedSnapshot.id,
                canonicalPath: linkedSnapshot.canonicalPath,
                removeWorkingDirectory: true,
                forceDiscardChanges: true
            )
        )

        #expect(result.effects.administration == .removed)
        #expect(result.effects.workingDirectory == .retained)
        #expect(result.effects.failure == .removalIncomplete)
        #expect(!FileManager.default.fileExists(atPath: linkedSnapshot.gitDirectory.path))
        #expect(FileManager.default.fileExists(atPath: linkedPath.path))
        #expect(!FileManager.default.fileExists(atPath: gitlinkPath.path))
    }

    private func snapshot(
        for linkedPath: URL,
        using client: LibGit2AgentStudioGitLocalClient,
        repositoryPath: URL
    ) async throws -> GitWorktreeSnapshot {
        try #require(
            try await client.worktrees(for: repositoryPath).first {
                normalizedPath($0.canonicalPath) == normalizedPath(linkedPath)
            })
    }

    private func remove(
        linkedPath: URL,
        fixture: GitFixtureRepository,
        client: LibGit2AgentStudioGitLocalClient,
        force: Bool,
        removeWorkingDirectory: Bool = true
    ) async throws -> GitWorktreeRemovalResult {
        let linkedSnapshot = try await snapshot(for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        return try await client.removeWorktree(
            GitRemoveWorktreeRequest(
                worktreeID: linkedSnapshot.id,
                canonicalPath: linkedSnapshot.canonicalPath,
                removeWorkingDirectory: removeWorkingDirectory,
                forceDiscardChanges: force
            )
        )
    }

    private func expectRemovalRefusal(
        _ reason: GitWorktreeRemovalRefusalReason,
        operation: () async throws -> GitWorktreeRemovalResult
    ) async throws {
        do {
            _ = try await operation()
            Issue.record("expected removal refusal \(reason)")
        } catch let error as GitDataPlaneError {
            #expect(error == .unsafeWorktreeRemoval(reason: reason))
        } catch {
            Issue.record("expected GitDataPlaneError refusal, got \(error)")
        }
    }

    private func expectPruneFailure(_ failure: GitWorktreeRemovalFailureKind?) {
        guard let failure else {
            Issue.record("expected a typed prune failure")
            return
        }
        if case .pruneFailed = failure {
            return
        }
        Issue.record("expected pruneFailed, got \(failure)")
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
