import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree integration", .serialized)
struct GitWorktreeIntegrationTests {
    @Test("fixture Git commands disable implicit maintenance before returning")
    func fixtureGitCommandsDisableImplicitMaintenance() throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-fixture-maintenance")
        defer { fixture.remove() }
        let automaticMaintenance = try fixture.git.run("config", "--get", "--bool", "maintenance.auto")
        #expect(automaticMaintenance.trimmingCharacters(in: .whitespacesAndNewlines) == "false")
        #expect(try fixture.git.succeeds("config", "--get", "--bool", "maintenance.auto"))
    }

    @Test("discovery filesystem snapshots reject incomplete enumeration")
    func discoveryFilesystemSnapshotsRejectIncompleteEnumeration() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-discovery-snapshot-errors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let unreadableDirectory = fixtureRoot.appending(path: "unreadable")
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try Data("hidden\n".utf8).write(to: unreadableDirectory.appending(path: "hidden.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadableDirectory.path
            )
        }
        let missingRoot = fixtureRoot.appending(path: "missing")

        #expect(throws: (any Error).self) {
            _ = try GitDiscoveryFilesystemSnapshot.capture(root: missingRoot)
        }
        #expect(throws: (any Error).self) {
            _ = try GitDiscoveryFilesystemSnapshot.capture(root: fixtureRoot)
        }
    }

    @Test("discovery filesystem mutation monitor observes a synchronized control write")
    func discoveryFilesystemMutationMonitorObservesSynchronizedControlWrite() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-discovery-monitor-control-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let controlFile = fixtureRoot.appending(path: "control.txt")
        try Data("before\n".utf8).write(to: controlFile)
        let mutationMonitor = try GitDiscoveryFilesystemMutationMonitor.startAndWaitUntilReady(
            scopeRoot: fixtureRoot,
            watchedRoots: [fixtureRoot]
        )
        defer { mutationMonitor.stop() }

        let fileHandle = try FileHandle(forWritingTo: controlFile)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data("after\n".utf8))
        try fileHandle.synchronize()
        try fileHandle.close()
        let mutations = try mutationMonitor.flushAndDrain()
        mutationMonitor.stop()

        #expect(
            mutations.contains {
                $0.path == controlFile.standardizedFileURL.path
                    && ($0.kinds.contains(.write) || $0.kinds.contains(.extend))
            },
            "expected synchronized control write to be observed, got \(mutations)"
        )
    }

    @Test("discovery read opens only the exact submitted candidate")
    func discoveryReadOpensOnlyExactSubmittedCandidate() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-discovery-exact")
        defer { fixture.remove() }
        let nestedDirectory = fixture.repositoryPath.appending(path: "Sources/Feature")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: nestedDirectory)
        )

        #expect(outcome == .notRepository(.exactCandidateIsNotRepository))
    }

    @Test("discovery read reports a malformed exact repository as invalid")
    func discoveryReadReportsMalformedExactRepositoryAsInvalid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-discovery-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a git directory pointer\n".utf8).write(to: root.appending(path: ".git"))
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: root)
        )

        #expect(outcome == .notRepository(.invalidRepository))
    }

    @Test("discovery read returns main-worktree evidence without mutating read-only Git state")
    func discoveryReadReturnsMainWorktreeEvidenceWithoutMutation() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-discovery-main")
        defer { fixture.remove() }
        let gitDirectory = fixture.repositoryPath.appending(path: ".git")
        let lockSentinel = gitDirectory.appending(path: "index.lock")
        try Data("pre-existing-lock\n".utf8).write(to: lockSentinel)
        let before = try GitDiscoveryFilesystemSnapshot.capture(root: gitDirectory)
        let permissionGuard = try GitDiscoveryWritePermissionGuard.removeWritePermissions(from: gitDirectory)
        defer { permissionGuard.restore() }
        let mutationMonitor = try GitDiscoveryFilesystemMutationMonitor.startAndWaitUntilReady(
            scopeRoot: fixture.root,
            watchedRoots: [fixture.repositoryPath, gitDirectory]
        )
        defer { mutationMonitor.stop() }
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: fixture.repositoryPath)
        )
        let mutations = try mutationMonitor.flushAndDrain()
        mutationMonitor.stop()
        permissionGuard.restore()
        let after = try GitDiscoveryFilesystemSnapshot.capture(root: gitDirectory)

        guard case .validated(let evidence) = outcome else {
            Issue.record("expected validated discovery evidence, got \(outcome)")
            return
        }
        #expect(evidence.canonicalCandidatePath.path == fixture.repositoryPath.standardizedFileURL.path)
        #expect(evidence.canonicalWorktreePath.path == fixture.repositoryPath.standardizedFileURL.path)
        #expect(evidence.canonicalGitDirectory.path == gitDirectory.standardizedFileURL.path)
        #expect(evidence.canonicalCommonDirectory.path == gitDirectory.standardizedFileURL.path)
        #expect(evidence.repositoryIdentity.canonicalCommonDirectory.path == gitDirectory.standardizedFileURL.path)
        #expect(evidence.registration == .main)
        #expect(mutations.isEmpty, "discovery read emitted transient filesystem mutations: \(mutations)")
        #expect(after == before)
        #expect(try Data(contentsOf: lockSentinel) == Data("pre-existing-lock\n".utf8))
    }

    @Test("discovery read reports linked-worktree registration and preserves its lock")
    func discoveryReadReportsLinkedWorktreeRegistrationAndPreservesLock() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-discovery-linked")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked", branch: "feature/discovery-linked")
        try fixture.git.run("worktree", "lock", "--reason", "external volume", linkedPath.path)
        let commonGitDirectory = fixture.repositoryPath.appending(path: ".git")
        let linkedGitFile = linkedPath.appending(path: ".git")
        let linkedAdministrativeDirectory = commonGitDirectory.appending(path: "worktrees/linked")
        let before = try GitDiscoveryFilesystemSnapshot.capture(root: commonGitDirectory)
        let mutationMonitor = try GitDiscoveryFilesystemMutationMonitor.startAndWaitUntilReady(
            scopeRoot: fixture.root,
            watchedRoots: [
                fixture.repositoryPath,
                commonGitDirectory,
                linkedPath,
                linkedGitFile,
                linkedAdministrativeDirectory,
            ]
        )
        defer { mutationMonitor.stop() }
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: linkedPath)
        )
        let mutations = try mutationMonitor.flushAndDrain()
        mutationMonitor.stop()
        let after = try GitDiscoveryFilesystemSnapshot.capture(root: commonGitDirectory)

        guard case .validated(let evidence) = outcome else {
            Issue.record("expected linked discovery evidence, got \(outcome)")
            return
        }
        #expect(evidence.canonicalWorktreePath.path == linkedPath.standardizedFileURL.path)
        #expect(evidence.canonicalCommonDirectory.path == commonGitDirectory.standardizedFileURL.path)
        #expect(evidence.registration == .linked(name: "linked", lockState: .locked(reason: "external volume")))
        #expect(mutations.isEmpty, "linked discovery read emitted transient filesystem mutations: \(mutations)")
        #expect(after == before)
    }

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
