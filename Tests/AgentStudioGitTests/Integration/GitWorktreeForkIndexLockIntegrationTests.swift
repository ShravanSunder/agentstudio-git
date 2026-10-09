import AgentStudioGit
import AgentStudioGitContracts
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork index lock integration", .serialized)
struct GitWorktreeForkIndexLockIntegrationTests {
    @Test("stat refresh maps a competing index lock and preserves its bytes")
    func statRefreshReportsCompetingIndexLock() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-stat-refresh-lock")
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "unchanged tracked content\n")
        try fixture.git.run("add", "tracked.txt")
        try fixture.git.run("commit", "-m", "add stat refresh target")
        let worktreeName = "fork-stat-refresh-lock"
        let destination = fixture.destination(worktreeName)
        let destinationFile = destination.appending(path: "tracked.txt")
        let lockFact = GitLockFact(
            path: fixture.linkedWorktreeAdministration(worktreeName).appending(path: "index.lock").standardizedFileURL,
            resource: .index(worktreePath: destination)
        )
        let lockContents = Data("foreign index lock at stat refresh\n".utf8)
        let checkpointReached = OSAllocatedUnfairLock(initialState: false)
        let faults = WorktreeForkFaultInjector { point throws(GitWorktreeForkError) in
            guard point == .afterInitialIndexWriteBeforeStatRefresh(lockPath: lockFact.path) else {
                return
            }
            checkpointReached.withLock { $0 = true }
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                    ofItemAtPath: destinationFile.path
                )
                try lockContents.write(to: lockFact.path)
            } catch {
                throw .entryFailed(relativePath: "index.lock", reason: .entryCreationFailed, errorNumber: nil)
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults)
        )

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    destination: destination,
                    mode: .newBranch(name: worktreeName, start: .sourceHead, upstream: nil),
                    materialization: .changesOnly
                )
            )
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(checkpointReached.withLock { $0 })
        let primaryFailure: GitWorktreeForkError?
        if case .cleanupIncomplete(let primary, _) = failure {
            primaryFailure = primary
        } else {
            primaryFailure = failure
        }
        #expect(primaryFailure == .gitFailure(.lockHeld(lockFact)))
        #expect(try Data(contentsOf: lockFact.path) == lockContents)
    }
}
