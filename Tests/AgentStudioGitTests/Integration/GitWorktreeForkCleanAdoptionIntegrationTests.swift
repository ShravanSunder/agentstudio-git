import AgentStudioGit
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git worktree fork clean-entry adoption integration", .serialized)
struct GitWorktreeForkCleanAdoptionIntegrationTests {
    @Test("clean entries are adopted while dirty, staged, and racily clean entries are refreshed to their true state")
    func cleanEntriesAdoptedAndOthersRefreshed() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-adoption")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "vendor/\n")
        for name in ["clean.txt", "dirty.txt", "staged.txt", "racy.txt"] {
            try fixture.write(name, "base \(name)\n")
        }
        for name in [".gitignore", "README.md", "clean.txt", "dirty.txt", "staged.txt"] {
            try Self.ageModificationTime(fixture.source.appending(path: name))
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "base")
        let tool = fixture.source.appending(path: "vendor/tool")
        try fixture.write("tool.txt", "nested clean\n", in: tool)
        try Self.ageModificationTime(tool.appending(path: "tool.txt"))
        try fixture.git.run(["init", "-q"], currentDirectory: tool)
        try fixture.git.run(["add", "."], currentDirectory: tool)
        try fixture.git.run(["commit", "-qm", "tool"], currentDirectory: tool)
        try fixture.write("dirty.txt", "dirty edit\n")
        try fixture.write("staged.txt", "staged edit\n")
        try fixture.git.run("add", "staged.txt")
        try Self.makeIndexAsNewAs(
            fixture.source.appending(path: "racy.txt"), index: fixture.source.appending(path: ".git/index"))
        let evidence = OSAllocatedUnfairLock(initialState: [String: WorktreeForkIndexRefreshEvidence]())
        let observer = WorktreeForkIndexObserver { node, nodeEvidence in
            evidence.withLock { $0[node] = nodeEvidence }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(indexObserver: observer))
        let destination = fixture.destination()

        // Act
        _ = try await client.forkWorktree(fixture.request())
        let indexStat = try fixture.indexStat(at: destination)

        // Assert
        let rootEvidence = try #require(evidence.withLock { $0[""] })
        #expect(rootEvidence.adoptedPaths == [".gitignore", "README.md", "clean.txt"])
        #expect(rootEvidence.adoptedPaths.isDisjoint(with: ["dirty.txt", "staged.txt", "racy.txt"]))
        #expect(try #require(evidence.withLock { $0["vendor/tool"] }).adoptedPaths == ["tool.txt"])
        #expect(
            try fixture.statusLines(at: destination) == [" M dirty.txt", " M staged.txt", "!! vendor/"])
        #expect(try fixture.statusLines(at: destination.appending(path: "vendor/tool")).isEmpty)
        for unchangedPath in ["README.md", "clean.txt", "racy.txt"] {
            let cached = try #require(indexStat[unchangedPath])
            let file = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: unchangedPath)))
            #expect(cached.inode == file.st_ino, "\(unchangedPath)")
            #expect(cached.size == file.st_size, "\(unchangedPath)")
            #expect(cached.mtimeSeconds == file.st_mtimespec.tv_sec, "\(unchangedPath)")
        }
    }

    @Test("a sparse-index source adopts nothing and still reports its true status")
    func sparseIndexSourceAdoptsNothing() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-adoption-sparse")
        defer { fixture.remove() }
        for path in ["kept/one.txt", "dropped/two.txt"] {
            try fixture.write(path, "\(path)\n")
            try Self.ageModificationTime(fixture.source.appending(path: path))
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tree")
        try fixture.git.run("sparse-checkout", "init", "--cone", "--sparse-index")
        try fixture.git.run("sparse-checkout", "set", "kept")
        try fixture.write("kept/one.txt", "dirty\n")
        let evidence = OSAllocatedUnfairLock(initialState: [String: WorktreeForkIndexRefreshEvidence]())
        let observer = WorktreeForkIndexObserver { node, nodeEvidence in
            evidence.withLock { $0[node] = nodeEvidence }
        }
        let client = LibGit2AgentStudioGitLocalClient(
            worktreeForkWriter: LibGit2WorktreeForkWriter(indexObserver: observer))

        // Act
        _ = try await client.forkWorktree(fixture.request())

        // Assert
        #expect(try #require(evidence.withLock { $0[""] }).adoptedPaths.isEmpty)
        #expect(try fixture.statusLines(at: fixture.destination()) == [" M kept/one.txt"])
    }

    /// Sets a file's modification time well into the past so Git caches it as a non-racy clean entry.
    private static func ageModificationTime(_ url: URL) throws {
        var times = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
        try #require(utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
    }

    /// Makes the index file's mtime equal the file's, so the file's cached entry is racily clean.
    private static func makeIndexAsNewAs(_ file: URL, index: URL) throws {
        let info = try #require(GitWorktreeForkFileProbe.info(file))
        var times = [info.st_mtimespec, info.st_mtimespec]
        try #require(utimensat(AT_FDCWD, index.path, &times, 0) == 0)
    }
}
