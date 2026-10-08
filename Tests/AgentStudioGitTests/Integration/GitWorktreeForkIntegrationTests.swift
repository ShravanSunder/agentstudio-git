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
        guard case .copyOnWrite(let materializationReport) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(materializationReport.clonedRegularFileCount == 8)
        #expect(materializationReport.skippedEntries.isEmpty)
    }

    @Test("new, existing, and detached modes at the captured HEAD attach after the copy and report the branch")
    func branchModesResolveToCapturedHead() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-modes")
        defer { fixture.remove() }
        let capturedHead = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "parked")
        let branchesBefore = try fixture.branchNames()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let newBranch = try await client.forkWorktree(
            fixture.request(
                destination: fixture.destination("new"),
                mode: .newBranch(name: "fork-new", start: .sourceHead, upstream: nil)))
        let existingBranch = try await client.forkWorktree(
            fixture.request(
                destination: fixture.destination("existing"),
                mode: .existingBranch(name: "parked", expectedTip: capturedHead, fastForwardTo: nil)))
        let detached = try await client.forkWorktree(
            fixture.request(destination: fixture.destination("detached"), mode: .detached(start: .commit(capturedHead)))
        )

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
        #expect(newBranch.worktree.head == GitHeadSnapshot(kind: .branch, oid: capturedHead, shortName: "fork-new"))
        #expect(existingBranch.worktree.head == GitHeadSnapshot(kind: .branch, oid: capturedHead, shortName: "parked"))
        #expect(detached.worktree.head == GitHeadSnapshot(kind: .detached, oid: capturedHead, shortName: nil))
        #expect(!(try fixture.git.succeeds("config", "--get-regexp", "^branch\\.")))
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
        try fixture.git.run("branch", "parked")
        try fixture.git.run("branch", "taken")
        let head = try fixture.blobID("HEAD", at: fixture.source)
        let behind = try fixture.blobID("behind", at: fixture.source)
        let unknown = String(repeating: "a", count: 40)
        let takenWorktree = try fixture.repository.addLinkedWorktree(named: "taken-worktree", branch: nil)
        try fixture.git.run(["checkout", "-q", "taken"], currentDirectory: takenWorktree)
        let existing = fixture.destination("exists")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let branchesBefore = try fixture.branchNames()
        func newBranch(
            _ name: String,
            start: GitForkStart = .sourceHead,
            upstream: GitBranchUpstream? = nil
        ) -> GitForkWorktreeMode {
            .newBranch(name: name, start: start, upstream: upstream)
        }
        let cases: [(GitForkWorktreeRequest, GitWorktreeForkError)] = [
            (fixture.request(destination: existing), .rejected(reason: .destinationExists)),
            (
                fixture.request(destination: fixture.destination("missing/child")),
                .rejected(reason: .destinationParentMissing)
            ),
            (
                fixture.request(destination: fixture.source.appending(path: "inside")),
                .rejected(reason: .overlappingRoots)
            ),
            (fixture.request(mode: newBranch("behind")), .rejected(reason: .branchAlreadyExists)),
            (fixture.request(mode: newBranch("bad..name")), .rejected(reason: .invalidBranchName)),
            (
                fixture.request(
                    mode: newBranch("fresh", upstream: GitBranchUpstream(remoteName: "bad remote", branchName: "x"))),
                .rejected(reason: .invalidUpstream)
            ),
            (
                fixture.request(mode: newBranch("fresh", start: .commit(unknown))),
                .gitFailure(.requiredObjectNotFound(oid: unknown))
            ),
            (
                fixture.request(mode: newBranch("fresh", start: .commit(head + String(repeating: "0", count: 24)))),
                .gitFailure(.unsupported(message: "start must be a full object identifier"))
            ),
            (
                fixture.request(mode: newBranch("fresh", start: .commit(behind)), materialization: .changesOnly),
                .rejected(reason: .invalidStart)
            ),
            (fixture.request(mode: newBranch("fresh", start: .commit(behind))), .rejected(reason: .invalidStart)),
            (
                fixture.request(mode: .existingBranch(name: "absent", expectedTip: head, fastForwardTo: nil)),
                .rejected(reason: .branchNotFound)
            ),
            (
                fixture.request(mode: .existingBranch(name: "behind", expectedTip: head, fastForwardTo: nil)),
                .rejected(reason: .branchMoved)
            ),
            (
                fixture.request(mode: .existingBranch(name: "parked", expectedTip: head, fastForwardTo: behind)),
                .rejected(reason: .fastForwardNotDescendant)
            ),
            (
                fixture.request(mode: .existingBranch(name: "taken", expectedTip: head, fastForwardTo: nil)),
                .branchCheckedOut(worktreePath: takenWorktree)
            ),
            (fixture.request(mode: newBranch("main")), .rejected(reason: .branchAlreadyExists)),
        ]
        let client = LibGit2AgentStudioGitLocalClient()

        for (request, expectedFailure) in cases {
            // Act
            let failure = await forkFailure(client, request)

            // Assert
            #expect(failure == expectedFailure, "\(request.destinationPath.path) \(request.mode)")
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
            mode: .detached(start: .sourceHead),
            materialization: .copyOnWrite,
            copyRules: GitWorktreeCopyRules(ignoredPaths: .copyAll)
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
