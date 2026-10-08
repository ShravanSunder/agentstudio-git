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

    @Test("branch names match by their bytes: a line separator inside a name, and a canonically equivalent pair")
    func probeMatchesBranchNamesByBytes() async throws {
        // Arrange: the origin holds `a<U+2028>b`, precomposed `é` and decomposed `e<U+0301>` at three commits. The two
        // spellings of é stay distinct refs only in packed-refs, because APFS treats their loose file names as one.
        // Names go in through `update-ref --stdin`: `Process` arguments reach git decomposed.
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-remote-probe-bytes")
        defer { fixture.remove() }
        let originPath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "-q", "--bare", originPath.path, currentDirectory: fixture.root)
        try fixture.git.run(["config", "core.precomposeUnicode", "false"], currentDirectory: originPath)
        try fixture.git.run("remote", "add", "origin", originPath.path)
        var commits: [String] = []
        for index in 0..<3 {
            try fixture.write("byte-\(index).txt", contents: "\(index)\n")
            try fixture.git.run("add", "byte-\(index).txt")
            try fixture.git.run("commit", "-qm", "byte \(index)")
            commits.append(try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try fixture.git.run("push", "-q", "origin", "main")
        let separatorName = "a\u{2028}b"
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"
        #expect(precomposed == decomposed && Array(precomposed.utf8) != Array(decomposed.utf8))
        for (name, commit) in zip([separatorName, precomposed, decomposed], commits) {
            try fixture.git.run(
                ["update-ref", "--stdin"], currentDirectory: originPath,
                standardInput: Data("update refs/heads/\(name) \(commit)\n".utf8))
            try fixture.git.run(["pack-refs", "--all"], currentDirectory: originPath)
        }
        let originNames = try fixture.git.run(
            ["for-each-ref", "--format=%(refname)", "refs/heads/"], currentDirectory: originPath)
        #expect(
            Set(originNames.utf8.split(separator: UInt8(ascii: "\n")).map { Array($0) })
                == Set(["main", separatorName, precomposed, decomposed].map { Array("refs/heads/\($0)".utf8) }))
        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        let probe = { (name: String) async throws -> GitRemoteBranchPresence in
            try await client.probeRemoteBranch(
                GitRemoteBranchProbeRequest(
                    repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: name))
        }

        // Act
        try fixture.git.run("config", "core.precomposeUnicode", "true")
        let separator = try await probe(separatorName)
        let precomposedWhilePrecomposing = try await probe(precomposed)
        let decomposedWhilePrecomposing = try await probe(decomposed)
        try fixture.git.run("config", "core.precomposeUnicode", "false")
        let precomposedExact = try await probe(precomposed)
        let decomposedExact = try await probe(decomposed)

        // Assert
        #expect(separator == .present(commit: commits[0]))
        #expect(precomposedWhilePrecomposing == .present(commit: commits[1]))
        // git asked for the precomposed name; that line is another ref, so not its commit.
        #expect(decomposedWhilePrecomposing == .absent)
        #expect(precomposedExact == .present(commit: commits[1]))
        #expect(decomposedExact == .present(commit: commits[2]))
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
