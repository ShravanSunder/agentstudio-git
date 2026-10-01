import AgentStudioGit
import AgentStudioGitContracts
import CLibGit2Local
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch deletion integration", .serialized)
struct GitBranchDeletionIntegrationTests {
    @Test("loose branch deletion removes its own config section and reflog only")
    func looseBranchDeletionRemovesOnlyItsOwnMetadata() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-loose")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        try fixture.makeBranch("topic.deep")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("tag", "keep-topic", topicCommit)
        try fixture.git.run("update-ref", "refs/remotes/origin/topic", topicCommit)
        try fixture.git.run("config", "--local", "branch.topic.remote", "origin")
        try fixture.git.run("config", "--local", "branch.topic.merge", "refs/heads/topic")
        try fixture.git.run("config", "--local", "branch.topic.description", "remove topic metadata")
        try fixture.git.run("config", "--local", "branch.topic.deep.remote", "keep-deep-section")

        let expectedReflog = try fixture.reflogBytes(for: "topic")
        #expect(expectedReflog != nil)
        let unrelatedReferencesBefore = try referencesExcluding("refs/heads/topic", from: fixture.localReferences())
        let client = LibGit2AgentStudioGitLocalClient()
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: fixture.repositoryPath,
            branchName: "topic",
            expectedCommit: topicCommit
        )

        // Act
        let result = try await client.deleteLocalBranch(request)

        // Assert
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(configuration: .removed, reflog: .removed),
                    lockResidue: []
                )
        )
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/heads/topic") == false)
        #expect(try fixture.reflogBytes(for: "topic") == nil)
        #expect(try fixture.configValue("branch.topic.deep.remote") == "keep-deep-section")
        #expect(
            try referencesExcluding("refs/heads/topic", from: fixture.localReferences()) == unrelatedReferencesBefore)
        #expect(try #require(expectedReflog).isEmpty == false)
    }

    @Test("packed branch deletion removes the packed local ref and preserves other refs")
    func packedBranchDeletionRemovesPackedLocalReference() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-packed")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        try fixture.git.run("tag", "keep-topic", topicCommit)
        try fixture.git.run("update-ref", "refs/remotes/origin/topic", topicCommit)
        try fixture.git.run("pack-refs", "--all", "--prune")
        #expect(!FileManager.default.fileExists(atPath: fixture.gitDirectory.appending(path: "refs/heads/topic").path))
        let unrelatedReferencesBefore = referencesExcluding("refs/heads/topic", from: try fixture.localReferences())
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(
            result
                == .deleted(
                    cleanup: GitBranchMetadataCleanup(configuration: .absent, reflog: .removed),
                    lockResidue: []
                )
        )
        #expect(try fixture.git.succeeds("show-ref", "--verify", "refs/heads/topic") == false)
        #expect(
            referencesExcluding("refs/heads/topic", from: try fixture.localReferences()) == unrelatedReferencesBefore)
    }

    @Test("a branch checked out in the main worktree is retained without metadata changes")
    func checkedOutMainBranchIsRetainedWithoutMetadataChanges() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-main-checkout")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        try fixture.git.run("checkout", "topic")
        let topicCommit = try fixture.branchCommit("topic")
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(
            result == .retained(reason: .checkedOut(worktreePaths: [fixture.repositoryPath]), lockResidue: [])
        )
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
    }

    @Test("a branch checked out in a linked worktree is retained")
    func checkedOutLinkedBranchIsRetained() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-linked-checkout")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-topic", onBranch: "topic")
        let topicCommit = try fixture.branchCommit("topic")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(result == .retained(reason: .checkedOut(worktreePaths: [linkedPath]), lockResidue: []))
        #expect(try fixture.branchCommit("topic") == topicCommit)
    }

    @Test("all worktrees checking out the branch are reported")
    func allWorktreesCheckingOutBranchAreReported() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-two-checkouts")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let firstLinkedPath = try fixture.addLinkedWorktree(named: "first-topic", onBranch: "topic")
        let secondLinkedPath = fixture.root.appending(path: "second-topic")
        try fixture.git.run("worktree", "add", "--force", secondLinkedPath.path, "topic")
        let topicCommit = try fixture.branchCommit("topic")
        let expectedWorktreePaths = [firstLinkedPath, secondLinkedPath].sorted { $0.path < $1.path }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "topic",
                expectedCommit: topicCommit
            )
        )

        // Assert
        #expect(result == .retained(reason: .checkedOut(worktreePaths: expectedWorktreePaths), lockResidue: []))
    }

    @Test("a locked linked worktree with a missing directory refuses an unreadable checkout")
    func lockedLinkedWorktreeWithMissingDirectoryRefusesUnreadableCheckout() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-missing-workdir")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let linkedPath = try fixture.addLinkedWorktree(named: "locked-topic", onBranch: "topic")
        try fixture.git.run("worktree", "lock", "--reason", "preserve missing worktree", linkedPath.path)
        try FileManager.default.removeItem(at: linkedPath)
        let topicCommit = try fixture.branchCommit("topic")
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        do {
            _ = try await client.deleteLocalBranch(
                GitDeleteLocalBranchRequest(
                    repositoryPath: fixture.repositoryPath,
                    branchName: "topic",
                    expectedCommit: topicCommit
                )
            )
            Issue.record("branch deletion unexpectedly ignored an unreadable locked worktree")
        } catch {
            #expect(error.reason == .checkoutUnreadable(worktreePath: nil))
            #expect(error.lockResidue?.isEmpty == true)
        }
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
    }

    @Test("an absent branch is retained and leaves its metadata alone")
    func absentBranchIsRetainedWithoutMetadataChanges() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-absent")
        defer { fixture.remove() }
        let expectedCommit = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let configBefore = try fixture.localConfiguration()
        let referencesBefore = try fixture.localReferences()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.deleteLocalBranch(
            GitDeleteLocalBranchRequest(
                repositoryPath: fixture.repositoryPath,
                branchName: "missing/topic",
                expectedCommit: expectedCommit
            )
        )

        // Assert
        #expect(result == .retained(reason: .notFound, lockResidue: []))
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.localReferences() == referencesBefore)
    }

    @Test("symbolic and non-commit local refs are rejected without mutation")
    func nonDirectCommitReferencesAreRejectedWithoutMutation() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-non-commit")
        defer { fixture.remove() }
        let commitOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git.run("symbolic-ref", "refs/heads/symbolic-topic", "refs/heads/main")
        try createDirectReference("refs/heads/tree-topic", pointingTo: treeOID, in: fixture)
        let referencesBefore = try fixture.localReferences()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        for (branchName, expectedCommit) in [("symbolic-topic", commitOID), ("tree-topic", treeOID)] {
            do {
                _ = try await client.deleteLocalBranch(
                    GitDeleteLocalBranchRequest(
                        repositoryPath: fixture.repositoryPath,
                        branchName: branchName,
                        expectedCommit: expectedCommit
                    )
                )
                Issue.record("a non-commit reference was unexpectedly deleted: \(branchName)")
            } catch {
                #expect(error.reason == .notADirectCommitReference)
                #expect(error.lockResidue?.isEmpty == true)
            }
        }
        #expect(try fixture.localReferences() == referencesBefore)
    }

    @Test("invalid and injection-shaped branch names are rejected before mutation")
    func invalidBranchNamesAreRejectedBeforeMutation() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-invalid-name")
        defer { fixture.remove() }
        let expectedCommit = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let configBefore = try fixture.localConfiguration()
        let referencesBefore = try fixture.localReferences()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        for branchName in ["", "../escape", "bad\nname", "bad\0name"] {
            do {
                _ = try await client.deleteLocalBranch(
                    GitDeleteLocalBranchRequest(
                        repositoryPath: fixture.repositoryPath,
                        branchName: branchName,
                        expectedCommit: expectedCommit
                    )
                )
                Issue.record("invalid branch name unexpectedly succeeded: \(branchName)")
            } catch {
                #expect(error.reason == .invalidBranchName)
                #expect(error.lockResidue?.isEmpty == true)
            }
        }
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.localReferences() == referencesBefore)
    }

    @Test("a competing native reference lock is reported with its exact residue path")
    func competingReferenceLockIsReportedWithExactResidue() async throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-ref-lock")
        defer { fixture.remove() }
        try fixture.makeBranch("topic")
        let topicCommit = try fixture.branchCommit("topic")
        let lockPath = fixture.gitDirectory.appending(path: "refs/heads/topic.lock")
        try fixture.writeLockFile(lockPath)
        let configBefore = try fixture.localConfiguration()
        let reflogBefore = try #require(try fixture.reflogBytes(for: "topic"))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        do {
            _ = try await client.deleteLocalBranch(
                GitDeleteLocalBranchRequest(
                    repositoryPath: fixture.repositoryPath,
                    branchName: "topic",
                    expectedCommit: topicCommit
                )
            )
            Issue.record("branch deletion unexpectedly acquired an existing ref lock")
        } catch {
            #expect(error.reason == .refLockContended)
            #expect(error.lockResidue == [lockPath.standardizedFileURL])
        }
        #expect(try fixture.branchCommit("topic") == topicCommit)
        #expect(try fixture.localConfiguration() == configBefore)
        #expect(try fixture.reflogBytes(for: "topic") == reflogBefore)
    }

    private func referencesExcluding(_ refName: String, from output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("\(refName) ") }
            .joined(separator: "\n")
    }

    private func createDirectReference(
        _ referenceName: String,
        pointingTo objectID: String,
        in fixture: GitBranchDeletionFixture
    ) throws {
        try LibGit2Runtime.shared.ensureInitialized()
        var repository: OpaquePointer?
        let openResult = fixture.repositoryPath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            Issue.record("could not open branch deletion fixture repository")
            return
        }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        let parseResult = objectID.withCString { git_oid_fromstr(&oid, $0) }
        guard parseResult >= 0 else {
            Issue.record("could not parse test object identifier")
            return
        }

        var reference: OpaquePointer?
        let createResult = referenceName.withCString { namePointer in
            git_reference_create(&reference, repository, namePointer, &oid, 1, "create non-commit fixture ref")
        }
        guard createResult >= 0, let reference else {
            Issue.record("could not create test direct reference")
            return
        }
        git_reference_free(reference)
    }
}
