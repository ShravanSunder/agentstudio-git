import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git status integration", .serialized)
struct GitStatusIntegrationTests {
    @Test("clean repository reports empty status")
    func cleanRepositoryReportsEmptyStatus() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-clean")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let status = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())

        #expect(status.head.kind == .branch)
        #expect(status.head.shortName == "main")
        #expect(status.originResolution == .confirmedAbsent)
        #expect(status.entries.isEmpty)
        #expect(status.summary.changedFileCount == 0)
        #expect(status.summary.stagedFileCount == 0)
        #expect(status.summary.unstagedFileCount == 0)
        #expect(status.summary.untrackedFileCount == 0)
        #expect(status.summary.ignoredFileCount == 0)
        #expect(status.summary.linesAdded == 0)
        #expect(status.summary.linesDeleted == 0)
        #expect(!status.summary.hasUpstream)
    }

    @Test("status entries preserve index and worktree axes")
    func statusEntriesPreserveIndexAndWorktreeAxes() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-axes")
        defer { fixture.remove() }
        try seedStatusAxisFiles(in: fixture)
        try mutateStatusAxisFiles(in: fixture)
        let client = LibGit2AgentStudioGitLocalClient()

        let status = try await client.status(
            for: fixture.repositoryPath,
            options: GitStatusOptions(includeIgnored: true, includeUntracked: true)
        )
        let entriesByPath = Dictionary(uniqueKeysWithValues: status.entries.map { ($0.path, $0) })

        #expect(entriesByPath["modified.txt"]?.indexState == nil)
        #expect(entriesByPath["modified.txt"]?.worktreeState == .modified)
        #expect(entriesByPath["staged.txt"]?.indexState == .modified)
        #expect(entriesByPath["staged.txt"]?.worktreeState == nil)
        #expect(entriesByPath["mixed.txt"]?.indexState == .modified)
        #expect(entriesByPath["mixed.txt"]?.worktreeState == .modified)
        #expect(entriesByPath["deleted.txt"]?.worktreeState == .deleted)
        #expect(entriesByPath["renamed-destination.txt"]?.indexState == .renamed)
        #expect(entriesByPath["renamed-destination.txt"]?.previousPath == "rename-source.txt")
        #expect(entriesByPath["staged-deleted.txt"]?.indexState == .deleted)
        #expect(entriesByPath["binary.bin"]?.worktreeState == .modified)
        #expect(entriesByPath["untracked.txt"]?.untracked == true)
        #expect(entriesByPath["ignored.txt"]?.ignored == true)
        #expect(status.summary.stagedFileCount == 4)
        #expect(status.summary.unstagedFileCount == 4)
        #expect(status.summary.untrackedFileCount == 1)
        #expect(status.summary.ignoredFileCount == 1)
        #expect(status.summary.changedFileCount == 8)

        let withoutIgnored = try await client.status(
            for: fixture.repositoryPath,
            options: GitStatusOptions(includeIgnored: false, includeUntracked: true)
        )
        #expect(!withoutIgnored.entries.contains { $0.ignored })
    }

    @Test("shortstat matches git diff HEAD semantics for staged and unstaged edits")
    func shortstatMatchesGitDiffHeadSemanticsForStagedAndUnstagedEdits() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-shortstat")
        defer { fixture.remove() }
        try fixture.write("Lines.txt", contents: "one\n")
        try fixture.git.run("add", "Lines.txt")
        try fixture.git.run("commit", "-m", "seed line counts")
        try fixture.write("Lines.txt", contents: "one\ntwo\n")
        try fixture.git.run("add", "Lines.txt")
        try fixture.write("Lines.txt", contents: "one\ntwo\nthree\n")
        let client = LibGit2AgentStudioGitLocalClient()

        let status = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        let gitShortstat = try fixture.git.run("diff", "--shortstat", "HEAD", "--")

        #expect(status.summary.linesAdded == 2)
        #expect(status.summary.linesDeleted == 0)
        #expect(parseGitShortstat(gitShortstat) == (insertions: 2, deletions: 0))
    }

    @Test("status reads preserve main and linked worktree indexes and lock sentinels")
    func statusReadsPreserveMainAndLinkedWorktreeIndexesAndLockSentinels() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-index")
        defer { fixture.remove() }
        let linkedPath = try fixture.addLinkedWorktree(named: "linked-index", branch: "feature/linked-index")
        let client = LibGit2AgentStudioGitLocalClient()
        let snapshots = try await client.worktrees(for: fixture.repositoryPath)
        let mainSnapshot = try #require(snapshots.first { $0.isMainWorktree })
        let linkedSnapshot = try #require(snapshots.first { samePath($0.canonicalPath, linkedPath) })
        try fixture.write("main-staged.txt", contents: "main staged\n")
        try fixture.git.run("add", "main-staged.txt")
        try fixture.write("README.md", contents: "main dirty\n")
        try fixture.write("linked-staged.txt", contents: "linked staged\n", in: linkedPath)
        try fixture.git.run("add", "linked-staged.txt", currentDirectory: linkedPath)
        try fixture.write("README.md", contents: "linked dirty\n", in: linkedPath)

        for snapshot in [mainSnapshot, linkedSnapshot] {
            try await assertStatusReadDoesNotMutateIndex(snapshot: snapshot, client: client)
        }
    }

    @Test("branch origin and upstream facts cover sync states")
    func branchOriginAndUpstreamFactsCoverSyncStates() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-branch")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let localOnly = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(localOnly.head.shortName == "main")
        #expect(localOnly.originResolution == .confirmedAbsent)
        #expect(!localOnly.summary.hasUpstream)
        #expect(localOnly.summary.aheadCount == 0)
        #expect(localOnly.summary.behindCount == 0)

        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")

        let inSync = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(inSync.summary.hasUpstream)
        #expect(inSync.summary.aheadCount == 0)
        #expect(inSync.summary.behindCount == 0)
        try expectResolvedOrigin(inSync.originResolution, matches: remotePath)

        try fixture.write("ahead.txt", contents: "ahead\n")
        try fixture.git.run("add", "ahead.txt")
        try fixture.git.run("commit", "-m", "local ahead")
        let ahead = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(ahead.summary.aheadCount == 1)
        #expect(ahead.summary.behindCount == 0)

        let peerPath = fixture.root.appending(path: "peer")
        try fixture.git.run("clone", remotePath.path, peerPath.path, currentDirectory: fixture.root)
        let peerGit = GitProcess(repositoryPath: peerPath)
        try "remote\n".write(to: peerPath.appending(path: "remote.txt"), atomically: true, encoding: .utf8)
        try peerGit.run("add", "remote.txt")
        try peerGit.run("commit", "-m", "remote ahead")
        try peerGit.run("push")
        try fixture.git.run("fetch", "origin")

        let diverged = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(diverged.summary.aheadCount == 1)
        #expect(diverged.summary.behindCount == 1)

        try fixture.git.run("reset", "--hard", "origin/main~1")
        let behind = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(behind.summary.aheadCount == 0)
        #expect(behind.summary.behindCount == 1)

        try fixture.git.run("checkout", "-b", "local-only")
        let noUpstream = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(noUpstream.head.shortName == "local-only")
        #expect(!noUpstream.summary.hasUpstream)
        #expect(noUpstream.summary.aheadCount == 0)
        #expect(noUpstream.summary.behindCount == 0)
    }

    @Test("origin snapshots redact credential-bearing remote URLs")
    func originSnapshotsRedactCredentialBearingRemoteURLs() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-origin-redaction")
        defer { fixture.remove() }
        let credentialedURL = "https://user:secret-token@example.com/org/repo.git"
        let client = LibGit2AgentStudioGitLocalClient()

        try fixture.git.run("remote", "add", "origin", credentialedURL)

        let status = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())

        guard case .resolved(let remote) = status.originResolution else {
            Issue.record("expected resolved origin, got \(status.originResolution)")
            return
        }
        let statusData = try JSONEncoder().encode(status)
        let encoded = try #require(String(data: statusData, encoding: .utf8))
        #expect(remote.rawURL == "https://<redacted>@example.com/org/repo.git")
        #expect(remote.url.absoluteString == "https://example.com/org/repo.git")
        #expect(!encoded.contains("secret-token"))
        #expect(!encoded.contains("user:secret-token"))
    }

    @Test("detached unborn and unresolved origin states still return summaries")
    func detachedUnbornAndUnresolvedOriginStatesStillReturnSummaries() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-head")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        try fixture.git.run("checkout", "--detach", "HEAD")
        let detached = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(detached.head.kind == .detached)
        #expect(detached.head.shortName == nil)
        #expect(detached.summary.changedFileCount == 0)

        try fixture.git.run("checkout", "main")
        try fixture.git.run("remote", "add", "origin", "https://example.invalid/repo.git")
        try fixture.git.run("config", "remote.origin.url", "")
        let unresolvedOrigin = try await client.status(for: fixture.repositoryPath, options: GitStatusOptions())
        #expect(unresolvedOrigin.originResolution == .awaitingResolution)
        #expect(unresolvedOrigin.head.shortName == "main")

        let emptyRoot = fixture.root.appending(path: "empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptyGit = GitProcess(repositoryPath: emptyRoot)
        try emptyGit.run("init")
        let unborn = try await client.status(for: emptyRoot, options: GitStatusOptions())
        #expect(unborn.head.kind == .unborn)
        #expect(unborn.summary.changedFileCount == 0)
    }

    @Test("branches list current branch and upstream names")
    func branchesListCurrentBranchAndUpstreamNames() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-status-branches")
        defer { fixture.remove() }
        let remotePath = fixture.root.appending(path: "origin.git")
        try fixture.git.run("init", "--bare", remotePath.path, currentDirectory: fixture.root)
        try fixture.git.run("remote", "add", "origin", remotePath.path)
        try fixture.git.run("push", "-u", "origin", "main")
        try fixture.git.run("branch", "feature/local")
        let client = LibGit2AgentStudioGitLocalClient()

        let branches = try await client.branches(for: fixture.repositoryPath)
        let main = try #require(branches.first { $0.name == "main" })
        let feature = try #require(branches.first { $0.name == "feature/local" })

        #expect(main.isCurrent)
        #expect(main.upstreamName == "refs/remotes/origin/main")
        #expect(!feature.isCurrent)
        #expect(feature.upstreamName == nil)
    }

    private func seedStatusAxisFiles(in fixture: GitFixtureRepository) throws {
        try fixture.write("modified.txt", contents: "base\n")
        try fixture.write("staged.txt", contents: "base\n")
        try fixture.write("mixed.txt", contents: "base\n")
        try fixture.write("deleted.txt", contents: "base\n")
        try fixture.write("staged-deleted.txt", contents: "base\n")
        try fixture.write("rename-source.txt", contents: "base\n")
        try writeData(Data([0, 1, 2, 3]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.write(".gitignore", contents: "ignored.txt\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed status axes")
    }

    private func mutateStatusAxisFiles(in fixture: GitFixtureRepository) throws {
        try fixture.write("modified.txt", contents: "base\nworktree\n")
        try fixture.write("staged.txt", contents: "base\nstaged\n")
        try fixture.git.run("add", "staged.txt")
        try fixture.write("mixed.txt", contents: "base\nstaged\n")
        try fixture.git.run("add", "mixed.txt")
        try fixture.write("mixed.txt", contents: "base\nstaged\nworktree\n")
        try FileManager.default.removeItem(at: fixture.repositoryPath.appending(path: "deleted.txt"))
        try fixture.git.run("rm", "staged-deleted.txt")
        try fixture.git.run("mv", "rename-source.txt", "renamed-destination.txt")
        try writeData(Data([3, 2, 1, 0]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.write("untracked.txt", contents: "loose\n")
        try fixture.write("ignored.txt", contents: "ignored\n")
    }

    private func assertStatusReadDoesNotMutateIndex(
        snapshot: GitWorktreeSnapshot,
        client: LibGit2AgentStudioGitLocalClient
    ) async throws {
        let indexBefore = try Data(contentsOf: snapshot.indexPath)
        let actualIndexPath = try GitIndexPathResolver().indexPath(for: snapshot.canonicalPath)
        #expect(actualIndexPath == snapshot.indexPath)
        let lockPath = snapshot.indexPath.deletingLastPathComponent().appending(path: "index.lock")
        try "agentstudio-lock-sentinel\n".write(to: lockPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lockPath) }

        _ = try await client.status(for: snapshot.canonicalPath, options: GitStatusOptions())

        let indexAfter = try Data(contentsOf: snapshot.indexPath)
        let lockContents = try String(contentsOf: lockPath, encoding: .utf8)
        #expect(indexAfter == indexBefore)
        #expect(lockContents == "agentstudio-lock-sentinel\n")
    }

    private func expectResolvedOrigin(_ resolution: GitOriginResolution, matches path: URL) throws {
        guard case .resolved(let remote) = resolution else {
            Issue.record("expected resolved origin, got \(resolution)")
            return
        }
        #expect(remote.name == "origin")
        #expect(samePath(remote.url, path))
        #expect(remote.rawURL == path.path)
    }

    private func writeData(_ data: Data, to relativePath: String, in directory: URL) throws {
        let url = directory.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func parseGitShortstat(_ output: String) -> (insertions: Int, deletions: Int) {
        (
            insertions: captureFirstInt(in: output, pattern: #"(\d+) insertions?\(\+\)"#) ?? 0,
            deletions: captureFirstInt(in: output, pattern: #"(\d+) deletions?\(-\)"#) ?? 0
        )
    }

    private func captureFirstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[swiftRange])
    }

    private func samePath(_ first: URL, _ second: URL) -> Bool {
        normalizedPath(first) == normalizedPath(second)
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
