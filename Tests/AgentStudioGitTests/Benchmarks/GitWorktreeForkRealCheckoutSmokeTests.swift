import AgentStudioGit
import Foundation
import Testing

/// Real-target smoke for copy-on-write forks. Synthetic fixtures don't carry real build-output quirks
/// (read-only SwiftPM checkouts, nested repositories, LFS objects). Only a real built checkout does, so
/// this forks one, checks the result, then removes the fork and its branch. It's excluded from
/// `mise run test`. Run it with `AGENTSTUDIO_GIT_FORK_REAL_SOURCE=<absolute path of a clean checkout>`.
@Suite(
    "Git worktree fork real-checkout smoke",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_FORK_REAL_SOURCE"] != nil)
)
struct GitWorktreeForkRealCheckoutSmokeTests {
    @Test("a real built checkout forks copy-on-write, keeps nested repositories, and is cleaned up")
    func realCheckoutForks() async throws {
        // Arrange
        let sourcePath = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_GIT_FORK_REAL_SOURCE"])
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let branch = "agentstudio-fork-smoke-\(suffix)"
        let destination = source.deletingLastPathComponent().appending(path: "\(source.lastPathComponent).\(branch)")
        let git = GitProcess(repositoryPath: source)
        defer {
            _ = try? git.run(["worktree", "remove", "--force", destination.path], currentDirectory: source)
            _ = try? git.run(["branch", "-D", branch], currentDirectory: source)
        }

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            GitForkWorktreeRequest(
                sourceWorktreePath: source,
                destinationPath: destination,
                mode: .newBranch(name: branch),
                materialization: .copyOnWrite
            ))

        // Assert
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(report.skippedEntries.isEmpty, "skipped: \(report.skippedEntries)")
        let sourceHead = try git.run(["rev-parse", "HEAD"], currentDirectory: source)
        let destinationHead = try git.run(["rev-parse", "HEAD"], currentDirectory: destination)
        #expect(destinationHead == sourceHead)
        #expect(try git.run(["branch", "--show-current"], currentDirectory: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines) == branch)
        let sourceStatus = try git.run(["status", "--porcelain"], currentDirectory: source)
        let destinationStatus = try git.run(["status", "--porcelain"], currentDirectory: destination)
        #expect(destinationStatus == sourceStatus, "destination status differs from source")
        print(
            "real-checkout fork: preservedGitRepositories=\(report.preservedGitRepositoryCount) "
                + "clonedFiles=\(report.clonedRegularFileCount) bytes=\(report.logicalRegularFileBytes) "
                + "normalized=\(report.normalizedEntries.count)")
    }
}
