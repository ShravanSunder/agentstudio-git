import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree fork integration", .serialized)
struct GitWorktreeForkIntegrationTests {
    @Test("a fork reproduces every source state relative to captured HEAD without touching the source")
    func forkReproducesStatusMatrixRelativeToCapturedHead() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-matrix")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "ignored.log\n")
        for name in ["clean.txt", "staged-mod.txt", "unstaged-mod.txt", "deleted.txt"] {
            try fixture.write(name, "base \(name)\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "base")
        try fixture.write("staged-mod.txt", "staged change\n")
        try fixture.git.run("add", "staged-mod.txt")
        try fixture.write("unstaged-mod.txt", "unstaged change\n")
        try fixture.write("staged-new.txt", "staged new\n")
        try fixture.git.run("add", "staged-new.txt")
        try fixture.write("untracked.txt", "untracked\n")
        try fixture.git.run("rm", "-q", "deleted.txt")
        try fixture.write("ignored.log", "ignored\n")
        let sourceStatusBefore = try fixture.statusLines(at: fixture.source)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())
        let indexStat = try fixture.indexStat(at: destination)
        let destinationStatus = try fixture.statusLines(at: destination)

        // Assert
        #expect(
            destinationStatus == [
                " D deleted.txt",
                " M staged-mod.txt",
                " M unstaged-mod.txt",
                "!! ignored.log",
                "?? staged-new.txt",
                "?? untracked.txt",
            ])
        #expect(try fixture.statusLines(at: fixture.source) == sourceStatusBefore)
        #expect(
            try fixture.stagedBlobID("staged-mod.txt", at: destination)
                == fixture.blobID("HEAD:staged-mod.txt", at: destination))
        for unchangedPath in [".gitignore", "README.md", "clean.txt"] {
            let cached = try #require(indexStat[unchangedPath])
            let file = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: unchangedPath)))
            #expect(cached.inode == file.st_ino, "\(unchangedPath) index stat must be refreshed")
            #expect(cached.size == file.st_size)
            #expect(cached.mtimeSeconds == file.st_mtimespec.tv_sec)
        }
        #expect(result.worktree.canonicalPath.lastPathComponent == "fork")
        #expect(result.materialization.clonedRegularFileCount == 8)
        #expect(result.materialization.skippedEntries.isEmpty)
    }

    @Test("new, existing, and detached modes all resolve to the captured HEAD")
    func branchModesResolveToCapturedHead() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-modes")
        defer { fixture.remove() }
        let capturedHead = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "parked")
        let branchesBefore = try fixture.branchNames()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        _ = try await client.forkWorktree(
            fixture.request(destination: fixture.destination("new"), mode: .newBranch(name: "fork-new")))
        _ = try await client.forkWorktree(
            fixture.request(destination: fixture.destination("existing"), mode: .existingBranch(name: "parked")))
        _ = try await client.forkWorktree(
            fixture.request(destination: fixture.destination("detached"), mode: .detached))

        // Assert
        #expect(try fixture.blobID("HEAD", at: fixture.destination("new")) == capturedHead)
        #expect(
            try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: fixture.destination("new"))
                == "refs/heads/fork-new\n")
        #expect(
            try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: fixture.destination("existing"))
                == "refs/heads/parked\n")
        #expect(try fixture.blobID("HEAD", at: fixture.destination("detached")) == capturedHead)
        #expect(
            !(try fixture.git.succeeds("symbolic-ref", "-q", "HEAD", currentDirectory: fixture.destination("detached")))
        )
        #expect(try fixture.branchNames() == (branchesBefore + ["refs/heads/fork-new"]).sorted())
    }

    @Test("preflight rejections happen before any branch, administration, or destination exists")
    func preflightRejectionsHappenBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-preflight")
        defer { fixture.remove() }
        try fixture.write("second.txt", "second\n")
        try fixture.git.run("add", "second.txt")
        try fixture.git.run("commit", "-m", "second")
        try fixture.git.run("branch", "behind", "HEAD~1")
        try fixture.git.run("branch", "taken")
        _ = try fixture.repository.addLinkedWorktree(named: "taken-worktree", branch: nil)
        try fixture.git.run(
            ["checkout", "-q", "taken"], currentDirectory: fixture.repository.linkedWorktreePath("taken-worktree"))
        let existing = fixture.destination("exists")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let branchesBefore = try fixture.branchNames()
        let cases: [(GitForkWorktreeRequest, GitWorktreeForkRejectionReason)] = [
            (fixture.request(destination: existing), .destinationExists),
            (fixture.request(destination: fixture.destination("missing/child")), .destinationParentMissing),
            (fixture.request(destination: fixture.source.appending(path: "inside")), .overlappingRoots),
            (fixture.request(mode: .newBranch(name: "behind")), .branchAlreadyExists),
            (fixture.request(mode: .newBranch(name: "bad..name")), .invalidBranchName),
            (fixture.request(mode: .existingBranch(name: "absent")), .branchNotFound),
            (fixture.request(mode: .existingBranch(name: "behind")), .branchNotAtCapturedHead),
            (fixture.request(mode: .existingBranch(name: "taken")), .branchCheckedOut),
        ]
        let client = LibGit2AgentStudioGitLocalClient()

        for (request, expectedReason) in cases {
            // Act
            let failure = await forkFailure(client, request)

            // Assert
            #expect(failure == .rejected(reason: expectedReason), "\(request.destinationPath.path) \(request.mode)")
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
            #expect(try fixture.branchNames() == branchesBefore)
        }
    }

    @Test("a source that is not a worktree root is rejected")
    func sourceThatIsNotWorktreeRootIsRejected() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-subdir")
        defer { fixture.remove() }
        let subdirectory = fixture.source.appending(path: "nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let request = GitForkWorktreeRequest(
            sourceWorktreePath: subdirectory,
            destinationPath: fixture.destination(),
            mode: .detached
        )

        // Act
        let failure = await forkFailure(LibGit2AgentStudioGitLocalClient(), request)

        // Assert
        #expect(failure == .rejected(reason: .sourceNotWorktreeRoot))
    }

    private func forkFailure(
        _ client: LibGit2AgentStudioGitLocalClient,
        _ request: GitForkWorktreeRequest
    ) async -> GitWorktreeForkError? {
        do {
            _ = try await client.forkWorktree(request)
            return nil
        } catch {
            return error
        }
    }
}
