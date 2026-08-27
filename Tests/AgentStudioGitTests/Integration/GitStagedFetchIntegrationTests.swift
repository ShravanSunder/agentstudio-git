import AgentStudioGit
import Foundation
import Testing

@Suite("Git staged fetch integration", .serialized)
struct GitStagedFetchIntegrationTests {
    @Test("staged fetch leaves canonical refs unchanged until atomic promotion")
    func stagedFetchLeavesCanonicalRefsUnchangedUntilAtomicPromotion() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        try fixture.git.run("checkout", "-b", "feature/delete-me")
        try fixture.git.run("push", "-u", "origin", "feature/delete-me")
        try fixture.git.run("checkout", "main")
        try fixture.git.run("checkout", "-b", "stable")
        try fixture.git.run("push", "-u", "origin", "stable")
        try fixture.git.run("checkout", "main")
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        let canonicalBefore = try fixture.git.run("rev-parse", "refs/remotes/origin/main")
        let client = SystemGitRemoteClient(
            configuration: .init(allowedProtocols: [.file])
        )
        let captured = try await client.captureRemoteTrackingSnapshot(
            GitRemoteTrackingSnapshotRequest(
                repositoryPath: fixture.repositoryPath,
                remoteName: "origin"
            )
        )
        try fixture.git.run("config", "fetch.prune", "true")
        try fixture.git.run("config", "fetch.pruneTags", "true")
        let fetchHeadURL = captured.repositoryCommonDirectory.appending(path: "FETCH_HEAD")
        let fetchHeadSentinel = Data("preserve-fetch-head\n".utf8)
        try fetchHeadSentinel.write(to: fetchHeadURL)

        let peerPath = fixture.root.appending(path: "peer")
        try fixture.git.run("clone", remotePath.path, peerPath.path, currentDirectory: fixture.root)
        let peerGit = GitProcess(repositoryPath: peerPath)
        try peerGit.run("config", "user.name", "AgentStudio Git Tests")
        try peerGit.run("config", "user.email", "agentstudio-git-tests@example.invalid")
        try "remote change\n".write(
            to: peerPath.appending(path: "remote-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        try peerGit.run("add", "remote-change.txt")
        try peerGit.run("commit", "-m", "remote change")
        try peerGit.run("push", "origin", "main")
        try peerGit.run("push", "origin", ":refs/heads/feature/delete-me")
        try peerGit.run("tag", "staged-fetch-tag")
        try peerGit.run("push", "origin", "refs/tags/staged-fetch-tag")
        try fixture.git.run(
            "config",
            "--add",
            "remote.origin.fetch",
            "+refs/heads/*:refs/remotes/unrelated/*"
        )

        // Act
        let staged = try await client.stageFetch(
            GitStagedFetchRequest(snapshot: captured, stagingID: UUID())
        )

        // Assert
        #expect(try fixture.git.run("rev-parse", "refs/remotes/origin/main") == canonicalBefore)
        #expect(staged.updates.contains { $0.canonicalRefName == "refs/remotes/origin/main" })
        #expect(staged.verifications.contains { $0.canonicalRefName == "refs/remotes/origin/stable" })
        #expect(staged.deletions.map(\.canonicalRefName) == ["refs/remotes/origin/feature/delete-me"])
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/remotes/origin/feature/delete-me"))
        #expect(try Data(contentsOf: fetchHeadURL) == fetchHeadSentinel)
        #expect(!(try fixture.git.succeeds("show-ref", "--verify", "refs/tags/staged-fetch-tag")))
        #expect(try fixture.git.run("for-each-ref", "refs/remotes/unrelated/").isEmpty)

        let incompletePlan = GitStagedFetchResult(
            snapshot: staged.snapshot,
            handle: staged.handle,
            promotionGuard: staged.promotionGuard,
            updates: staged.updates,
            verifications: [],
            deletions: []
        )
        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.promoteStagedFetch(
                GitPromoteStagedFetchRequest(stagedFetch: incompletePlan)
            )
        }
        #expect(try fixture.git.run("rev-parse", "refs/remotes/origin/main") == canonicalBefore)

        let missingGuardPlan = GitStagedFetchResult(
            snapshot: staged.snapshot,
            handle: staged.handle,
            promotionGuard: nil,
            updates: staged.updates,
            verifications: staged.verifications,
            deletions: staged.deletions
        )
        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.promoteStagedFetch(
                GitPromoteStagedFetchRequest(stagedFetch: missingGuardPlan)
            )
        }
        #expect(try fixture.git.run("rev-parse", "refs/remotes/origin/main") == canonicalBefore)

        let promoted = try await client.promoteStagedFetch(
            GitPromoteStagedFetchRequest(stagedFetch: staged)
        )
        #expect(promoted.updatedRefNames == ["refs/remotes/origin/main"])
        #expect(promoted.deletedRefNames == ["refs/remotes/origin/feature/delete-me"])
        #expect(try fixture.git.run("rev-parse", "refs/remotes/origin/main") != canonicalBefore)
        #expect(!(try fixture.git.succeeds("show-ref", "--verify", "refs/remotes/origin/feature/delete-me")))
        #expect(try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD").contains("origin/main"))
        #expect(try fixture.git.run("for-each-ref", staged.stagingNamespace).isEmpty)
    }

    @Test("staged promotion rejects concurrent canonical mutation as one transaction")
    func stagedPromotionRejectsConcurrentCanonicalMutationAsOneTransaction() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-race")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        let firstOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try fixture.write("second.txt", contents: "second\n")
        try fixture.git.run("add", "second.txt")
        try fixture.git.run("commit", "-m", "second")
        let secondOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git.run("push", "origin", "main")
        try fixture.git.run("update-ref", "refs/remotes/origin/main", firstOID)

        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let captured = try await client.captureRemoteTrackingSnapshot(
            GitRemoteTrackingSnapshotRequest(
                repositoryPath: fixture.repositoryPath,
                remoteName: "origin"
            )
        )
        let staged = try await client.stageFetch(
            GitStagedFetchRequest(snapshot: captured, stagingID: UUID())
        )
        try fixture.git.run("update-ref", "refs/remotes/origin/main", secondOID, firstOID)

        // Act / Assert
        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.promoteStagedFetch(
                GitPromoteStagedFetchRequest(stagedFetch: staged)
            )
        }
        #expect(
            try fixture.git.run("rev-parse", "refs/remotes/origin/main")
                .trimmingCharacters(in: .whitespacesAndNewlines) == secondOID
        )

        _ = try await client.cleanupStagedFetch(
            GitCleanupStagedFetchRequest(handle: staged.handle)
        )
        #expect(try fixture.git.run("for-each-ref", staged.stagingNamespace).isEmpty)
    }

    @Test("cleanup revokes a deletion-only staged promotion")
    func cleanupRevokesDeletionOnlyStagedPromotion() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-revoke")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        let canonicalBefore = try fixture.git.run("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git.run("update-ref", "refs/remotes/origin/main", canonicalBefore)
        try fixture.git.run(
            "--git-dir",
            remotePath.path,
            "config",
            "receive.denyDeleteCurrent",
            "ignore",
            currentDirectory: fixture.root
        )
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let captured = try await client.captureRemoteTrackingSnapshot(
            GitRemoteTrackingSnapshotRequest(repositoryPath: fixture.repositoryPath, remoteName: "origin")
        )
        try fixture.git.run(
            "--git-dir",
            remotePath.path,
            "update-ref",
            "-d",
            "refs/heads/main",
            currentDirectory: fixture.root
        )
        let staged = try await client.stageFetch(
            GitStagedFetchRequest(snapshot: captured, stagingID: UUID())
        )
        #expect(staged.updates.isEmpty)
        #expect(staged.verifications.isEmpty)
        #expect(staged.deletions.map(\.canonicalRefName) == ["refs/remotes/origin/main"])

        // Act
        _ = try await client.cleanupStagedFetch(
            GitCleanupStagedFetchRequest(handle: staged.handle)
        )

        // Assert
        await #expect(throws: GitDataPlaneError.self) {
            _ = try await client.promoteStagedFetch(
                GitPromoteStagedFetchRequest(stagedFetch: staged)
            )
        }
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/remotes/origin/main"))
    }

    @Test("abandoned staging sweep preserves active UUIDs then removes only reserved refs")
    func abandonedStagingSweepPreservesActiveUUIDsThenRemovesOnlyReservedRefs() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-sweep")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        let canonicalBefore = try fixture.git.run("rev-parse", "refs/remotes/origin/main")
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let snapshot = try await client.captureRemoteTrackingSnapshot(
            GitRemoteTrackingSnapshotRequest(
                repositoryPath: fixture.repositoryPath,
                remoteName: "origin"
            )
        )
        let stagingID = UUID()
        let staged = try await client.stageFetch(
            GitStagedFetchRequest(snapshot: snapshot, stagingID: stagingID)
        )

        // Act / Assert
        let retained = try await client.cleanupAbandonedStagedFetches(
            GitCleanupAbandonedStagedFetchesRequest(
                repositoryCommonDirectory: snapshot.repositoryCommonDirectory,
                retainedStagingIDs: [stagingID]
            )
        )
        #expect(retained.deletedRefNames.isEmpty)
        #expect(!retained.retainedRefNames.isEmpty)

        let cleaned = try await client.cleanupAbandonedStagedFetches(
            GitCleanupAbandonedStagedFetchesRequest(
                repositoryCommonDirectory: snapshot.repositoryCommonDirectory,
                retainedStagingIDs: []
            )
        )
        #expect(!cleaned.deletedRefNames.isEmpty)
        #expect(cleaned.retainedRefNames.isEmpty)
        #expect(try fixture.git.run("for-each-ref", staged.stagingNamespace).isEmpty)
        #expect(try fixture.git.run("rev-parse", "refs/remotes/origin/main") == canonicalBefore)
    }

    @Test("abandoned staging sweep stays within the Git output limit")
    func abandonedStagingSweepStaysWithinGitOutputLimit() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-bounded-sweep")
        defer { fixture.remove() }
        let objectID = try fixture.git.run("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeStagingID = UUID()
        let abandonedStagingIDs = [UUID(), UUID()]
        let activeNamespace = GitStagedFetchHandle(
            repositoryCommonDirectory: fixture.repositoryPath,
            stagingID: activeStagingID
        ).stagingNamespace
        let abandonedNamespaces = abandonedStagingIDs.map {
            GitStagedFetchHandle(
                repositoryCommonDirectory: fixture.repositoryPath,
                stagingID: $0
            ).stagingNamespace
        }
        let activeRefNames = (0..<3).map {
            "\(activeNamespace)heads/active-\(String(format: "%03d", $0))"
        }
        let abandonedRefNames = abandonedNamespaces.flatMap { namespace in
            (0..<192).map {
                "\(namespace)heads/abandoned-\(String(format: "%03d", $0))"
            }
        }
        let refCreationCommands = (activeRefNames + abandonedRefNames)
            .map { "create \($0) \(objectID)\n" }
            .joined()
        try fixture.git.run(
            ["update-ref", "--stdin"],
            standardInput: Data(refCreationCommands.utf8)
        )
        let canonicalRefName = "refs/remotes/origin/main"
        try fixture.git.run("update-ref", canonicalRefName, objectID)
        let capturedOutputLimitBytes: Int64 = 16_384
        let unboundedEnumeration = try fixture.git.run(
            "--git-dir",
            fixture.repositoryPath.appending(path: ".git").path,
            "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(symref)",
            "refs/agentstudio/staged/"
        )
        #expect(Int64(unboundedEnumeration.utf8.count) > capturedOutputLimitBytes)
        let client = SystemGitRemoteClient(
            configuration: .init(
                allowedProtocols: [.file],
                capturedOutputLimitBytes: capturedOutputLimitBytes
            )
        )

        // Act
        let cleanup = try await client.cleanupAbandonedStagedFetches(
            GitCleanupAbandonedStagedFetchesRequest(
                repositoryCommonDirectory: fixture.repositoryPath.appending(path: ".git"),
                retainedStagingIDs: [activeStagingID]
            )
        )

        // Assert
        #expect(cleanup.deletedRefNames == abandonedRefNames.sorted())
        #expect(cleanup.retainedRefNames == activeRefNames.sorted())
        for abandonedNamespace in abandonedNamespaces {
            #expect(try fixture.git.run("for-each-ref", abandonedNamespace).isEmpty)
        }
        #expect(try fixture.git.run("for-each-ref", activeNamespace).split(separator: "\n").count == 3)
        #expect(
            try fixture.git.run("rev-parse", canonicalRefName).trimmingCharacters(in: .whitespacesAndNewlines)
                == objectID)
    }

    @Test("staging cleanup stays within the Git output limit")
    func stagingCleanupStaysWithinGitOutputLimit() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-bounded-cleanup")
        defer { fixture.remove() }
        let repositoryCommonDirectory = fixture.repositoryPath.appending(path: ".git")
        let handle = GitStagedFetchHandle(
            repositoryCommonDirectory: repositoryCommonDirectory,
            stagingID: UUID()
        )
        let objectID = try fixture.git.run("rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedRefNames = [
            "\(handle.stagingNamespace)heads/alpha",
            "\(handle.stagingNamespace)heads/beta",
        ]
        for stagedRefName in stagedRefNames {
            try fixture.git.run("update-ref", stagedRefName, objectID)
        }
        let capturedOutputLimitBytes: Int64 = 192
        let unboundedEnumeration = try fixture.git.run(
            "--git-dir",
            repositoryCommonDirectory.path,
            "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(symref)",
            handle.stagingNamespace
        )
        #expect(Int64(unboundedEnumeration.utf8.count) > capturedOutputLimitBytes)
        let client = SystemGitRemoteClient(
            configuration: .init(
                allowedProtocols: [.file],
                capturedOutputLimitBytes: capturedOutputLimitBytes
            )
        )

        // Act
        let cleanup = try await client.cleanupStagedFetch(
            GitCleanupStagedFetchRequest(handle: handle)
        )

        // Assert
        #expect(cleanup.deletedRefNames == stagedRefNames)
        #expect(cleanup.retainedRefNames.isEmpty)
        #expect(try fixture.git.run("for-each-ref", handle.stagingNamespace).isEmpty)
    }

    @Test("staging cleanup survives removal of the originating linked worktree")
    func stagingCleanupSurvivesRemovalOfOriginatingLinkedWorktree() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-staged-fetch-linked")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-stage", branch: "feature/linked-stage")
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let snapshot = try await client.captureRemoteTrackingSnapshot(
            GitRemoteTrackingSnapshotRequest(repositoryPath: linkedPath, remoteName: "origin")
        )
        let staged = try await client.stageFetch(
            GitStagedFetchRequest(snapshot: snapshot, stagingID: UUID())
        )
        try fixture.git.run("worktree", "remove", "--force", linkedPath.path)

        // Act
        let cleanup = try await client.cleanupStagedFetch(
            GitCleanupStagedFetchRequest(handle: staged.handle)
        )

        // Assert
        #expect(!cleanup.deletedRefNames.isEmpty)
        #expect(cleanup.retainedRefNames.isEmpty)
        #expect(try fixture.git.run("for-each-ref", staged.stagingNamespace).isEmpty)
    }
}
