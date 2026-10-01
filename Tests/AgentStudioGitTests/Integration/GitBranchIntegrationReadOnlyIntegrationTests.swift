import AgentStudioGit
import Foundation
import Testing

@Suite("Git branch integration read-only behavior")
struct GitBranchIntegrationReadOnlyIntegrationTests {
    @Test("assessment does not write repository metadata or working files")
    func assessmentDoesNotWriteRepositoryMetadataOrWorkingFiles() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-read-only")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "feature", baseCommit)
        try fixture.write("target.txt", contents: "target\n")
        try fixture.git.run("add", "target.txt")
        try fixture.git.run("commit", "-m", "advance target")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("config", "core.ignorecase", "true")
        try fixture.git.run("config", "core.filemode", "false")
        try fixture.git.run("config", "diff.ignoreSubmodules", "all")
        try fixture.git.run("config", "diff.external", "/usr/bin/false")
        try fixture.write("README.md", contents: "dirty source worktree\n")
        try fixture.write("untracked.txt", contents: "untracked source file\n")

        let before = try GitDiscoveryFilesystemSnapshot.capture(root: fixture.root)
        let mutationMonitor = try GitDiscoveryFilesystemMutationMonitor.startAndWaitUntilReady(
            scopeRoot: fixture.root,
            watchedRoots: [fixture.root]
        )
        defer { mutationMonitor.stop() }

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )
        let mutations = try mutationMonitor.flushAndDrain()
        mutationMonitor.stop()
        let after = try GitDiscoveryFilesystemSnapshot.capture(root: fixture.root)

        // Assert
        #expect(report.assessments.first?.grade == .integrated(.ancestor))
        #expect(mutations.isEmpty)
        #expect(after == before)
    }
}
