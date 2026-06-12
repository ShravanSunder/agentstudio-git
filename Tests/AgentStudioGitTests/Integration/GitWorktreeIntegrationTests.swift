import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree integration", .serialized)
struct GitWorktreeIntegrationTests {
    @Test("main, linked, and linked-name-main worktrees are listed")
    func mainLinkedAndLinkedNameMainWorktreesAreListed() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked", branch: "feature/linked")
        let linkedMainPath = try fixture.addLinkedWorktree(named: "main", branch: "feature/main-name")
        let client = LibGit2AgentStudioGitLocalClient()

        let snapshots = try await client.worktrees(for: fixture.repositoryPath)

        #expect(snapshots.count == 3)
        let mainSnapshot = try #require(snapshots.first { $0.isMainWorktree })
        let linkedSnapshot = try #require(snapshots.first { samePath($0.canonicalPath, linkedPath) })
        let linkedMainSnapshot = try #require(snapshots.first { samePath($0.canonicalPath, linkedMainPath) })
        #expect(mainSnapshot.displayName == "main")
        #expect(linkedSnapshot.displayName == "linked")
        #expect(linkedMainSnapshot.displayName == "main")
        #expect(Set(snapshots.map(\.id)).count == 3)
        #expect(!linkedMainSnapshot.isMainWorktree)
    }

    @Test("linked path listing resolves the real main worktree once")
    func linkedPathListingResolvesRealMainWorktreeOnce() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-context", branch: "feature/linked-context")
        let secondLinkedPath = try fixture.addLinkedWorktree(named: "second-linked", branch: "feature/second-linked")
        let client = LibGit2AgentStudioGitLocalClient()

        let snapshots = try await client.worktrees(for: linkedPath)

        let mainSnapshots = snapshots.filter(\.isMainWorktree)
        #expect(mainSnapshots.count == 1)
        #expect(mainSnapshots.first.map { samePath($0.canonicalPath, fixture.repositoryPath) } == true)
        #expect(snapshots.filter { samePath($0.canonicalPath, linkedPath) }.count == 1)
        #expect(snapshots.contains { samePath($0.canonicalPath, secondLinkedPath) })
        #expect(Set(snapshots.map(\.id)).count == snapshots.count)
    }

    @Test("/tmp worktree snapshots and repository identity share one writer lane")
    func tmpWorktreeSnapshotsAndRepositoryIdentityShareOneWriterLane() async throws {
        let tmpDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let fixture = try GitFixtureRepository.makeRepository(
            prefix: "agentstudio-git-tmp-identity",
            rootDirectory: tmpDirectory
        )
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let registry = GitRepositoryWriterRegistry()

        let privateRepositoryPath = URL(fileURLWithPath: "/private\(fixture.repositoryPath.path)", isDirectory: true)

        let identity = try await client.repositoryIdentity(for: privateRepositoryPath)
        let mainSnapshot = try #require(
            try await client.worktrees(for: fixture.repositoryPath).first { $0.isMainWorktree })
        let identityLane = await registry.writer(for: identity)
        let snapshotLane = await registry.writer(
            for: GitRepositoryIdentity(
                id: mainSnapshot.repositoryID,
                canonicalCommonDirectory: mainSnapshot.gitDirectory,
                mainWorktreePath: mainSnapshot.canonicalPath
            )
        )

        #expect(identity.id == mainSnapshot.repositoryID)
        #expect(identity.canonicalCommonDirectory == mainSnapshot.gitDirectory)
        #expect(identityLane.laneID == snapshotLane.laneID)
    }

    @Test("create supports existing branch, new branch, detached, and checked-out branch refusal")
    func createSupportsBranchModesAndCheckedOutBranchRefusal() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        try fixture.git.run("branch", "feature/existing")
        let client = LibGit2AgentStudioGitLocalClient()

        let existingSnapshot = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repositoryPath,
                destinationPath: fixture.linkedWorktreePath("existing"),
                mode: .existingBranch(name: "feature/existing")
            )
        )
        let newSnapshot = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repositoryPath,
                destinationPath: fixture.linkedWorktreePath("new-branch"),
                mode: .newBranch(name: "feature/new", startPoint: .named("HEAD"))
            )
        )
        let detachedSnapshot = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: fixture.repositoryPath,
                destinationPath: fixture.linkedWorktreePath("detached"),
                mode: .detached(startPoint: .named("HEAD"))
            )
        )

        #expect(existingSnapshot.head?.shortName == "feature/existing")
        #expect(newSnapshot.head?.shortName == "feature/new")
        #expect(detachedSnapshot.head?.kind == .detached)
        #expect(
            try fixture.git.run("rev-parse", "--verify", "feature/new").trimmingCharacters(in: .whitespacesAndNewlines)
                .count == 40)

        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: fixture.repositoryPath,
                    destinationPath: fixture.linkedWorktreePath("main-branch-again"),
                    mode: .existingBranch(name: "main")
                )
            )
        }
    }

    @Test("failed new-branch create rolls back the branch")
    func failedNewBranchCreateRollsBackTheBranch() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let destinationPath = fixture.linkedWorktreePath("preexisting-destination")
        try FileManager.default.createDirectory(at: destinationPath, withIntermediateDirectories: true)
        let client = LibGit2AgentStudioGitLocalClient()

        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.createWorktree(
                GitCreateWorktreeRequest(
                    repositoryPath: fixture.repositoryPath,
                    destinationPath: destinationPath,
                    mode: .newBranch(name: "feature/rollback", startPoint: .named("HEAD"))
                )
            )
        }

        let branchExists = try fixture.git.succeeds(
            "show-ref", "--verify", "--quiet", "refs/heads/feature/rollback")
        let worktreeList = try fixture.git.run("worktree", "list", "--porcelain")
        #expect(!branchExists)
        #expect(!worktreeList.contains("feature/rollback"))
    }

    @Test("validate distinguishes existing and missing worktrees")
    func validateDistinguishesExistingAndMissingWorktrees() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "validate", branch: "feature/validate")
        let client = LibGit2AgentStudioGitLocalClient()

        let valid = try await client.validateWorktree(GitValidateWorktreeRequest(worktreePath: linkedPath))
        try FileManager.default.removeItem(at: linkedPath)
        let missing = try await client.validateWorktree(GitValidateWorktreeRequest(worktreePath: linkedPath))

        #expect(valid.isValid)
        #expect(valid.snapshot.map { samePath($0.canonicalPath, linkedPath) } == true)
        #expect(!missing.isValid)
        #expect(missing.snapshot == nil)
    }

    @Test("lock and unlock preserve lock reason in snapshots")
    func lockAndUnlockPreserveLockReasonInSnapshots() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "locked", branch: "feature/locked")
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedSnapshot = try await snapshot(for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)

        let locked = try await client.lockWorktree(
            GitLockWorktreeRequest(worktreeID: linkedSnapshot.id, reason: "external disk unavailable")
        )
        let unlocked = try await client.unlockWorktree(GitUnlockWorktreeRequest(worktreeID: linkedSnapshot.id))

        #expect(locked.isLocked)
        #expect(locked.lockReason == "external disk unavailable")
        #expect(!unlocked.isLocked)
        #expect(unlocked.lockReason == nil)
    }

    @Test("stale prune removes metadata and refuses live worktrees")
    func stalePruneRemovesMetadataAndRefusesLiveWorktrees() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "stale", branch: "feature/stale")
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedSnapshot = try await snapshot(for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)

        try await expectPruneRefusal(.liveWorktree, worktreeID: linkedSnapshot.id) {
            try await client.pruneStaleWorktree(
                GitPruneStaleWorktreeRequest(repositoryPath: linkedPath, worktreeID: linkedSnapshot.id)
            )
        }
        #expect(FileManager.default.fileExists(atPath: linkedPath.path))

        try FileManager.default.removeItem(at: linkedPath)
        let result = try await client.pruneStaleWorktree(
            GitPruneStaleWorktreeRequest(repositoryPath: fixture.repositoryPath, worktreeID: linkedSnapshot.id)
        )
        let snapshots = try await client.worktrees(for: fixture.repositoryPath)

        #expect(result.prunedWorktreeID == linkedSnapshot.id)
        #expect(!snapshots.contains { $0.id == linkedSnapshot.id })
    }

    @Test("stale prune reports locked worktree metadata")
    func stalePruneReportsLockedWorktreeMetadata() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "locked-stale", branch: "feature/locked-stale")
        let client = LibGit2AgentStudioGitLocalClient()
        let linkedSnapshot = try await snapshot(for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        try fixture.git.run("worktree", "lock", "--reason", "portable disk missing", linkedPath.path)
        try FileManager.default.removeItem(at: linkedPath)

        do {
            _ = try await client.pruneStaleWorktree(
                GitPruneStaleWorktreeRequest(repositoryPath: fixture.repositoryPath, worktreeID: linkedSnapshot.id)
            )
            Issue.record("expected locked stale worktree refusal")
        } catch let error {
            #expect(error == .locked(message: "portable disk missing"))
        }
    }

    @Test("malformed git file is not reported as a missing repository")
    func malformedGitFileIsNotReportedAsMissingRepository() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let malformedPath = fixture.root.appending(path: "malformed")
        try FileManager.default.createDirectory(at: malformedPath, withIntermediateDirectories: true)
        try "not-a-gitdir\n".write(to: malformedPath.appending(path: ".git"), atomically: true, encoding: .utf8)
        let client = LibGit2AgentStudioGitLocalClient()

        do {
            _ = try await client.repositoryIdentity(for: malformedPath)
            Issue.record("expected malformed .git file to fail")
        } catch let error {
            guard case .libgit2Failure(_, _, let message) = error else {
                Issue.record("expected libgit2Failure for malformed .git file, got \(error)")
                return
            }
            #expect(message.contains("invalid .git file"))
        }
    }

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

    @Test("remove deletes clean worktree and force discards dirty worktree")
    func removeDeletesCleanWorktreeAndForceDiscardsDirtyWorktree() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let cleanPath = try fixture.addLinkedWorktree(named: "clean", branch: "feature/clean")
        let dirtyPath = try fixture.addLinkedWorktree(named: "force-dirty", branch: "feature/force-dirty")
        try fixture.write("README.md", contents: "forced\n", in: dirtyPath)

        let cleanResult = try await remove(linkedPath: cleanPath, fixture: fixture, client: client, force: false)
        let dirtyResult = try await remove(linkedPath: dirtyPath, fixture: fixture, client: client, force: true)

        #expect(cleanResult.removedWorkingDirectory)
        #expect(cleanResult.partialFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: cleanPath.path))
        #expect(dirtyResult.removedWorkingDirectory)
        #expect(dirtyResult.partialFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: dirtyPath.path))
    }

    @Test("remove reports partial failure when working-directory deletion is denied")
    func removeReportsPartialFailureWhenWorkingDirectoryDeletionIsDenied() async throws {
        let fixture = try GitFixtureRepository.makeRepository()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let partialPath = try fixture.addLinkedWorktree(named: "partial", branch: "feature/partial")
        let blockedDirectory = partialPath.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try fixture.write("blocked/file.txt", contents: "blocked\n", in: partialPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDirectory.path)
        }

        let result = try await remove(linkedPath: partialPath, fixture: fixture, client: client, force: true)

        #expect(!result.removedWorkingDirectory)
        #expect(result.partialFailure != nil)
    }

    private func snapshot(
        for linkedPath: URL,
        using client: LibGit2AgentStudioGitLocalClient,
        repositoryPath: URL
    ) async throws -> GitWorktreeSnapshot {
        try #require(
            try await client.worktrees(for: repositoryPath).first {
                samePath($0.canonicalPath, linkedPath)
            })
    }

    private func remove(
        linkedPath: URL,
        fixture: GitFixtureRepository,
        client: LibGit2AgentStudioGitLocalClient,
        force: Bool
    ) async throws -> GitWorktreeRemovalResult {
        let linkedSnapshot = try await snapshot(for: linkedPath, using: client, repositoryPath: fixture.repositoryPath)
        return try await client.removeWorktree(
            GitRemoveWorktreeRequest(
                worktreeID: linkedSnapshot.id,
                canonicalPath: linkedSnapshot.canonicalPath,
                removeWorkingDirectory: true,
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
        }
    }

    private func expectPruneRefusal(
        _ reason: GitWorktreePruneRefusalReason,
        worktreeID: GitWorktreeID,
        operation: () async throws -> GitWorktreePruneResult
    ) async throws {
        do {
            _ = try await operation()
            Issue.record("expected prune refusal \(reason)")
        } catch let error as GitDataPlaneError {
            #expect(error == .worktreeNotPrunable(id: worktreeID, reason: reason))
        }
    }

    private func samePath(_ first: URL, _ second: URL) -> Bool {
        normalizedPath(first) == normalizedPath(second)
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
