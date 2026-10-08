import AgentStudioGit
import Foundation
import Testing

@Suite("Git remote branch probe integration", .serialized)
struct GitRemoteBranchProbeIntegrationTests {
    @Test("the probe returns the remote tip for a present branch and absent for a missing one")
    func probeReportsPresentAndAbsentBranches() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-remote-probe")
        defer { fixture.remove() }
        let originPath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "-q", "--bare", originPath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", originPath.path)
        try fixture.git.run("push", "-q", "-u", "origin", "main")
        try fixture.git.run("switch", "-q", "-c", "feat")
        try fixture.write("feat.txt", contents: "feat\n")
        try fixture.git.run("add", "feat.txt")
        try fixture.git.run("commit", "-qm", "feat")
        try fixture.git.run("push", "-q", "origin", "feat")
        let featTip = try fixture.git.run("rev-parse", "feat").trimmingCharacters(in: .whitespacesAndNewlines)
        // A branch deleted on the remote keeps its stale tracking ref here; the probe must not read it.
        try fixture.git.run("update-ref", "refs/remotes/origin/gone", "main")
        // ls-remote matches patterns by path tail: this ref matches `feat2`'s pattern without being `feat2`.
        try fixture.git.run("push", "-q", "origin", "main:refs/heads/nested/refs/heads/feat2")
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let originRefsBefore = try fixture.git.run(["for-each-ref"], currentDirectory: originPath)
        let localRefsBefore = try fixture.git.run("for-each-ref")

        // Act
        let present = try await client.probeRemoteBranch(
            GitRemoteBranchProbeRequest(
                repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "feat"))
        let missing = try await client.probeRemoteBranch(
            GitRemoteBranchProbeRequest(
                repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "never-pushed"))
        let deleted = try await client.probeRemoteBranch(
            GitRemoteBranchProbeRequest(
                repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "gone"))
        let tailOnly = try await client.probeRemoteBranch(
            GitRemoteBranchProbeRequest(
                repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "feat2"))

        // Assert
        #expect(present == .present(commit: featTip))
        #expect(missing == .absent)
        #expect(deleted == .absent)
        #expect(tailOnly == .absent)
        #expect(try fixture.git.run("rev-parse", "--verify", "refs/remotes/origin/gone").count == 41)
        #expect(try fixture.git.run(["for-each-ref"], currentDirectory: originPath) == originRefsBefore)
        #expect(try fixture.git.run("for-each-ref") == localRefsBefore)
    }

    @Test("an unreachable remote is thrown, never reported absent")
    func unreachableRemoteIsThrown() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-remote-probe-unreachable")
        defer { fixture.remove() }
        try fixture.git.run("remote", "add", "origin", fixture.root.appending(path: "missing-origin.git").path)
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))

        // Act
        let failure: GitDataPlaneError?
        do {
            _ = try await client.probeRemoteBranch(
                GitRemoteBranchProbeRequest(
                    repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "main"))
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        guard case .processFailed(let processFailure) = failure else {
            Issue.record("expected a process failure, got \(String(describing: failure))")
            return
        }
        #expect(processFailure.exitCode != 0)
        #expect(processFailure.exitCode != 2)
    }

    @Test("invalid remote and branch names are refused before any process runs")
    func invalidNamesAreRefused() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-remote-probe-invalid")
        defer { fixture.remove() }
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let cases: [(remote: String, branch: String, message: String)] = [
            ("--upload-pack=touch", "main", "remote name is invalid"),
            ("origin", "bad..name", "remote branch name is invalid"),
        ]

        for invalid in cases {
            // Act
            let failure: GitDataPlaneError?
            do {
                _ = try await client.probeRemoteBranch(
                    GitRemoteBranchProbeRequest(
                        repositoryPath: fixture.repositoryPath, remoteName: invalid.remote, branchName: invalid.branch))
                failure = nil
            } catch {
                failure = error
            }

            // Assert
            #expect(failure == .unsupported(message: invalid.message))
        }
    }
}
