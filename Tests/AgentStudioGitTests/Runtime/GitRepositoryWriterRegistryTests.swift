import AgentStudioGit
import Foundation
import Testing

@Suite("Git repository writer registry")
struct GitRepositoryWriterRegistryTests {
    @Test("registry reuses one lane for the same canonical repository")
    func registryReusesOneLaneForSameCanonicalRepository() async {
        let registry = GitRepositoryWriterRegistry()
        let identity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "repo-1"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/repo")
        )

        let firstLane = await registry.writer(for: identity)
        let secondLane = await registry.writer(for: identity)

        #expect(firstLane.laneID == secondLane.laneID)
        #expect(firstLane.repositoryID == identity.id)
    }

    @Test("registry separates lanes for different canonical repositories")
    func registrySeparatesLanesForDifferentCanonicalRepositories() async {
        let registry = GitRepositoryWriterRegistry()
        let firstIdentity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "repo-1"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo-1/.git"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/repo-1")
        )
        let secondIdentity = GitRepositoryIdentity(
            id: GitRepositoryID(rawValue: "repo-2"),
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/repo-2/.git"),
            mainWorktreePath: URL(fileURLWithPath: "/tmp/repo-2")
        )

        let firstLane = await registry.writer(for: firstIdentity)
        let secondLane = await registry.writer(for: secondIdentity)

        #expect(firstLane.laneID != secondLane.laneID)
        #expect(firstLane.repositoryID == firstIdentity.id)
        #expect(secondLane.repositoryID == secondIdentity.id)
    }
}
