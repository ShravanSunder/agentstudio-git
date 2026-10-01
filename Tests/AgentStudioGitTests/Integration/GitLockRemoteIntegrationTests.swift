import AgentStudioGit
import AgentStudioGitContracts
import CLibGit2Local
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("System Git lock facts", .serialized)
struct GitLockRemoteIntegrationTests {
    @Test("fetch maps an actual local reference lock with a quoted Unicode repository path")
    func fetchMapsActualLocalReferenceLockWithQuotedUnicodeRepositoryPath() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-remote-lock space ' café-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let fixture = try GitFixtureRepository.makeRepository(
            prefix: "repository",
            rootDirectory: rootDirectory
        )
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")

        let peerPath = fixture.root.appending(path: "peer")
        try fixture.git.run("clone", remotePath.path, peerPath.path, currentDirectory: fixture.root)
        let peerGit = GitProcess(repositoryPath: peerPath)
        try peerGit.run("config", "user.name", "AgentStudio Test")
        try peerGit.run("config", "user.email", "agentstudio@example.invalid")
        try "remote update\n".write(
            to: peerPath.appending(path: "remote-update.txt"),
            atomically: true,
            encoding: .utf8
        )
        try peerGit.run("add", "remote-update.txt")
        try peerGit.run("commit", "-m", "remote update")
        try peerGit.run("push", "origin", "main")

        let expectedLockFact = try LibGit2ReviewSupport.withRepository(at: fixture.repositoryPath) { repository in
            try LibGit2LockPathResolver.fact(
                for: .reference(name: "refs/remotes/origin/main"),
                repository: repository
            )
        }
        try FileManager.default.createDirectory(
            at: expectedLockFact.path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: expectedLockFact.path)

        let client = SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))

        do {
            _ = try await client.fetch(
                GitFetchRequest(repositoryPath: fixture.repositoryPath, remoteName: "origin", branchName: "main")
            )
            Issue.record("fetch unexpectedly replaced a ref while its lock existed")
        } catch {
            #expect(error.reason == .lockHeld(expectedLockFact))
            #expect(error.lockResidue?.isEmpty == true)
        }
    }
}
