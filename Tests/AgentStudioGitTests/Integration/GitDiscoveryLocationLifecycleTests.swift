import AgentStudioGit
import Foundation
import Testing

extension GitWorktreeIntegrationTests {
    @Test("discovery keeps linked checkout locations distinct within one family")
    func discoveryKeepsLinkedCheckoutLocationsDistinct() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-distinct-locations")
        defer { fixture.remove() }
        let firstPath = try fixture.addLinkedWorktree(named: "first", branch: "feature/first")
        let secondPath = try fixture.addLinkedWorktree(named: "second", branch: "feature/second")
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let main = try await validatedLocation(fixture.repositoryPath, using: client)
        let first = try await validatedLocation(firstPath, using: client)
        let second = try await validatedLocation(secondPath, using: client)

        #expect(first.repositoryIdentity == main.repositoryIdentity)
        #expect(second.repositoryIdentity == main.repositoryIdentity)
        #expect(first.canonicalWorktreePath != second.canonicalWorktreePath)
        #expect(first.canonicalGitDirectory != second.canonicalGitDirectory)
        #expect(first.registration != second.registration)
    }

    @Test("moving a main clone changes location identity and same-path return restores it")
    func mainCloneMoveAndReturnExposeCurrentLocationOnly() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-main-return")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitDiscoveryReadClient()
        let original = try await validatedLocation(fixture.repositoryPath, using: client)
        let movedPath = fixture.root.appending(path: "moved")

        try FileManager.default.moveItem(at: fixture.repositoryPath, to: movedPath)
        let absent = await client.readDiscoveryCandidate(.init(candidatePath: fixture.repositoryPath))
        let moved = try await validatedLocation(movedPath, using: client)

        #expect(absent == .notRepository(.exactCandidateIsNotRepository))
        #expect(moved.repositoryIdentity.id != original.repositoryIdentity.id)
        #expect(moved.canonicalWorktreePath != original.canonicalWorktreePath)
        #expect(moved.registration == .main)

        try FileManager.default.moveItem(at: movedPath, to: fixture.repositoryPath)
        let restored = try await validatedLocation(fixture.repositoryPath, using: client)
        #expect(restored == original)
    }

    @Test("independent clones with identical history and remote remain separate families")
    func identicalHistoryAndRemoteDoNotCollapseFamilies() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-independent-clones")
        defer { fixture.remove() }
        let clonePath = fixture.root.appending(path: "other-clone")
        _ = try fixture.git.run("clone", "--no-hardlinks", fixture.repositoryPath.path, clonePath.path)
        let cloneGit = GitProcess(repositoryPath: clonePath)
        _ = try fixture.git.run("remote", "add", "origin", "https://example.invalid/shared.git")
        _ = try cloneGit.run("remote", "set-url", "origin", "https://example.invalid/shared.git")
        #expect(try fixture.git.run("rev-parse", "HEAD") == cloneGit.run("rev-parse", "HEAD"))
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let original = try await validatedLocation(fixture.repositoryPath, using: client)
        let clone = try await validatedLocation(clonePath, using: client)

        #expect(original.repositoryIdentity.id != clone.repositoryIdentity.id)
        #expect(original.canonicalCommonDirectory != clone.canonicalCommonDirectory)
    }

    @Test("a moved linked checkout with stale registration is not validated as a new location")
    func movedLinkedCheckoutRequiresValidRegistration() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-stale-registration")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked", branch: "feature/linked")
        let movedPath = fixture.root.appending(path: "moved-linked")
        let client = LibGit2AgentStudioGitDiscoveryReadClient()
        let original = try await validatedLocation(linkedPath, using: client)

        try FileManager.default.moveItem(at: linkedPath, to: movedPath)
        let moved = await client.readDiscoveryCandidate(.init(candidatePath: movedPath))

        #expect(moved == .notRepository(.invalidWorktreeRegistration))
        try FileManager.default.moveItem(at: movedPath, to: linkedPath)
        let restored = try await validatedLocation(linkedPath, using: client)
        #expect(restored == original)
    }

    @Test("a symlink alias resolves to the same canonical checkout and family")
    func symlinkAliasPreservesCanonicalLocation() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-location-alias")
        defer { fixture.remove() }
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repositoryPath)
        let client = LibGit2AgentStudioGitDiscoveryReadClient()

        let original = try await validatedLocation(fixture.repositoryPath, using: client)
        let aliased = try await validatedLocation(alias, using: client)

        #expect(aliased == original)
    }

    @Test("a registered linked move exposes a distinct location in the same family")
    func registeredLinkedMoveKeepsFamilyAndChangesLocation() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-registered-move")
        defer { fixture.remove() }
        let originalPath = try fixture.addLinkedWorktree(named: "linked", branch: "feature/linked")
        let movedPath = fixture.root.appending(path: "moved-linked")
        let client = LibGit2AgentStudioGitDiscoveryReadClient()
        let original = try await validatedLocation(originalPath, using: client)

        _ = try fixture.git.run("worktree", "move", originalPath.path, movedPath.path)
        let moved = try await validatedLocation(movedPath, using: client)
        let missing = await client.readDiscoveryCandidate(.init(candidatePath: originalPath))

        #expect(moved.repositoryIdentity == original.repositoryIdentity)
        #expect(moved.registration == original.registration)
        #expect(moved.canonicalGitDirectory == original.canonicalGitDirectory)
        #expect(moved.canonicalWorktreePath != original.canonicalWorktreePath)
        #expect(moved.canonicalCandidatePath == moved.canonicalWorktreePath)
        #expect(missing == .notRepository(.exactCandidateIsNotRepository))
    }

    @Test("a copied main repository is a separate family while the original remains valid")
    func copiedMainRepositoryHasIndependentLocationIdentity() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "discovery-copied-main")
        defer { fixture.remove() }
        let copyPath = fixture.root.appending(path: "copy")
        let client = LibGit2AgentStudioGitDiscoveryReadClient()
        let original = try await validatedLocation(fixture.repositoryPath, using: client)

        try FileManager.default.copyItem(at: fixture.repositoryPath, to: copyPath)
        let copied = try await validatedLocation(copyPath, using: client)
        let retainedOriginal = try await validatedLocation(fixture.repositoryPath, using: client)

        #expect(retainedOriginal == original)
        #expect(copied.repositoryIdentity != original.repositoryIdentity)
        #expect(copied.canonicalWorktreePath != original.canonicalWorktreePath)
        #expect(copied.registration == .main)
    }

    private func validatedLocation(
        _ path: URL,
        using client: LibGit2AgentStudioGitDiscoveryReadClient
    ) async throws -> GitDiscoveryReadEvidence {
        let outcome = await client.readDiscoveryCandidate(.init(candidatePath: path))
        guard case .validated(let evidence) = outcome else {
            throw DiscoveryLifecycleFixtureFailure.invalidLocation
        }
        return evidence
    }
}

private enum DiscoveryLifecycleFixtureFailure: Error {
    case invalidLocation
}
