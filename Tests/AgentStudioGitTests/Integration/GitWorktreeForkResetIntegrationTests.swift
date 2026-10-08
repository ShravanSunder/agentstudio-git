import AgentStudioGit
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// LR29's reset row: a fork whose start is not the captured HEAD. Every assertion reads the destination through
/// the `git` CLI or Darwin metadata, and source files are backdated first so a rewrite can never hide in the
/// same second as the copy.
@Suite("Git worktree fork reset integration", .serialized)
struct GitWorktreeForkResetIntegrationTests {
    private static let backdated = Date(timeIntervalSince1970: 1_600_000_000)

    @Test("a dirty main checkout forked onto another branch has that branch's files, index, and HEAD only")
    func dirtySourceResetOntoAnotherBranch() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-dirty")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "*.log\n*.o\nbuild/\ncache/\n")
        for name in ["same.txt", "modified.txt", "head-only.txt", "tools/a.txt"] {
            try fixture.write(name, "base \(name)\n")
        }
        try fixture.write("differs.txt", "head version\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "base")
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.write("differs.txt", "start version\n", in: starter)
            try fixture.write("start-only.txt", "only at the start\n", in: starter)
            try fixture.write("build/version.txt", "start tracks this\n", in: starter)
            try fixture.git.run(["rm", "-q", "head-only.txt"], currentDirectory: starter)
            try fixture.git.run(
                ["add", "-f", "differs.txt", "start-only.txt", "build/version.txt"], currentDirectory: starter)
        }
        try fixture.write("modified.txt", "work in progress\n")
        try fixture.write("scratch.txt", "untracked\n")
        try fixture.write("staged-new.txt", "staged only\n")
        try fixture.git.run("add", "staged-new.txt")
        try fixture.write("debug.log", "ignored, not included\n")
        try fixture.write("cache/blob.txt", "ignored folder, not included\n")
        try fixture.write("build/out.bin", "included build output\n")
        try fixture.write("build/version.txt", "source build output\n")
        // `tools/` is included but not ignored, so its entries are classified one by one.
        try fixture.write("tools/scratch.txt", "untracked inside an included folder\n")
        try fixture.write("tools/out.o", "ignored inside an included folder\n")
        try makeIndependentRepository(at: "build/checkouts/dep", in: fixture)
        try makeIndependentRepository(at: "vendor/tool", in: fixture)
        try backdateSourceFiles(fixture)
        _ = try fixture.git.succeeds("update-index", "-q", "--refresh")
        let sourceStatusBefore = try fixture.statusLines(at: fixture.source)
        let destination = fixture.destination()
        let copyRules = GitWorktreeCopyRules(
            ignoredPaths: .copyMatching([try GitPathPattern("build/"), try GitPathPattern("tools/")]))

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(mode: .newBranch(name: "fork", start: .commit(start), upstream: nil), copyRules: copyRules))

        // Assert
        #expect(result.worktree.head == GitHeadSnapshot(kind: .branch, oid: start, shortName: "fork"))
        #expect(try fixture.git.run(["symbolic-ref", "HEAD"], currentDirectory: destination) == "refs/heads/fork\n")
        #expect(try fixture.blobID("HEAD", at: destination) == start)
        #expect(
            try fixture.git.run(["write-tree"], currentDirectory: destination)
                == fixture.git.run("rev-parse", "\(start)^{tree}"))
        #expect(
            try fixture.statusLines(at: destination) == ["!! build/checkouts/", "!! build/out.bin", "!! tools/out.o"])
        #expect(try text("tools/a.txt", in: destination) == "base tools/a.txt\n")
        #expect(try text("tools/out.o", in: destination) == "ignored inside an included folder\n")
        #expect(try text("differs.txt", in: destination) == "start version\n")
        #expect(try text("start-only.txt", in: destination) == "only at the start\n")
        #expect(try text("modified.txt", in: destination) == "base modified.txt\n")
        #expect(try text("build/version.txt", in: destination) == "start tracks this\n")
        #expect(try text("build/out.bin", in: destination) == "included build output\n")
        for absent in [
            "head-only.txt", "scratch.txt", "staged-new.txt", "debug.log", "cache", "vendor", "tools/scratch.txt",
        ] {
            #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: absent)), "\(absent)")
        }
        for unchanged in ["same.txt", ".gitignore", "build/out.bin", "build/checkouts/dep/dep.txt"] {
            #expect(try modificationTime(unchanged, in: destination) == Self.backdated, "\(unchanged)")
        }
        #expect(GitWorktreeForkFileProbe.privateSize(destination.appending(path: "same.txt")) == 0)
        #expect(try modificationTime("modified.txt", in: destination) != Self.backdated)
        #expect(
            try fixture.git.run(
                ["rev-parse", "HEAD"], currentDirectory: destination.appending(path: "build/checkouts/dep"))
                == fixture.git.run(
                    ["rev-parse", "HEAD"], currentDirectory: fixture.source.appending(path: "build/checkouts/dep")))
        #expect(try fixture.statusLines(at: fixture.source) == sourceStatusBefore)
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected a copy-on-write report")
            return
        }
        #expect(report.sourceState == .reset)
        #expect(report.submodulesNotAtStart.isEmpty)
        #expect(
            report.largeFiles == GitLargeFileFill(materializedCount: 0, missing: [], residuePaths: [], scan: .complete))
        #expect(report.ignoredIncludedPatterns == ["build/", "tools/"])
    }

    @Test("a start equal to the captured HEAD copies as is; a detached reset is detached at the start")
    func capturedHeadStartCopiesAsIsAndDetachedResetDetaches() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-as-is")
        defer { fixture.remove() }
        let head = try fixture.blobID("HEAD", at: fixture.source)
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.write("start.txt", "start\n", in: starter)
            try fixture.git.run(["add", "start.txt"], currentDirectory: starter)
        }
        try fixture.write("scratch.txt", "untracked\n")
        let client = LibGit2AgentStudioGitLocalClient()
        let copyRules = GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))

        // Act
        let asIs = try await client.forkWorktree(
            fixture.request(
                destination: fixture.destination("as-is"),
                mode: .newBranch(name: "as-is", start: .commit(head), upstream: nil), copyRules: copyRules))
        let detached = try await client.forkWorktree(
            fixture.request(
                destination: fixture.destination("detached"), mode: .detached(start: .commit(start)),
                copyRules: copyRules))

        // Assert
        #expect(try fixture.statusLines(at: fixture.destination("as-is")) == ["?? scratch.txt"])
        #expect(detached.worktree.head == GitHeadSnapshot(kind: .detached, oid: start, shortName: nil))
        #expect(try fixture.statusLines(at: fixture.destination("detached")).isEmpty)
        #expect(try text("start.txt", in: fixture.destination("detached")) == "start\n")
        guard case .copyOnWrite(let asIsReport) = asIs.materialization,
            case .copyOnWrite(let detachedReport) = detached.materialization
        else {
            Issue.record("expected copy-on-write reports")
            return
        }
        #expect(asIsReport.sourceState == .asIs)
        #expect(asIsReport.largeFiles == nil)
        #expect(detachedReport.sourceState == .reset)
    }

    @Test("an existing branch strictly behind is fast-forwarded and the copy reset to its new tip")
    func existingBranchFastForwardResetsTheCopy() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-fast-forward")
        defer { fixture.remove() }
        let base = try fixture.blobID("HEAD", at: fixture.source)
        try fixture.git.run("branch", "feat")
        let remoteTip = try commitOnBranch("remote-feat", in: fixture) { starter in
            try fixture.write("feat.txt", "from the remote tip\n", in: starter)
            try fixture.git.run(["add", "feat.txt"], currentDirectory: starter)
        }
        try fixture.write("main.txt", "main moved on\n")
        try fixture.git.run("add", "main.txt")
        try fixture.git.run("commit", "-qm", "main")

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                mode: .existingBranch(name: "feat", expectedTip: base, fastForwardTo: remoteTip),
                copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        // Assert
        let destination = fixture.destination()
        #expect(try fixture.blobID("feat", at: fixture.source) == remoteTip)
        #expect(result.worktree.head == GitHeadSnapshot(kind: .branch, oid: remoteTip, shortName: "feat"))
        #expect(try text("feat.txt", in: destination) == "from the remote tip\n")
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "main.txt")))
        #expect(try fixture.statusLines(at: destination).isEmpty)
    }

    @Test("submodules at another commit or new at the start are listed; one the start lacks is removed")
    func submodulesAreListedOrRemoved() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-submodules")
        defer { fixture.remove() }
        let changedSource = try fixture.addSubmodule(at: "sub-changed")
        let changedOrigin = fixture.repository.root.appending(path: "origins/sub-changed")
        try fixture.write("second.txt", "second\n", in: changedOrigin)
        try fixture.git.run(["add", "second.txt"], currentDirectory: changedOrigin)
        try fixture.git.run(["commit", "-qm", "second"], currentDirectory: changedOrigin)
        let changedNext = try fixture.blobID("HEAD", at: changedOrigin)
        let changedCurrent = try fixture.blobID("HEAD", at: changedSource)
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.git.run(
                ["update-index", "--cacheinfo", "160000,\(changedNext),sub-changed"], currentDirectory: starter)
            try fixture.git.run(
                ["update-index", "--add", "--cacheinfo", "160000,\(changedNext),sub-new"], currentDirectory: starter)
            try fixture.git.run(
                ["config", "-f", ".gitmodules", "submodule.sub-new.path", "sub-new"], currentDirectory: starter)
            try fixture.git.run(
                ["config", "-f", ".gitmodules", "submodule.sub-new.url", changedOrigin.path], currentDirectory: starter)
            try fixture.git.run(["add", ".gitmodules"], currentDirectory: starter)
        }
        try fixture.addSubmodule(at: "sub-removed")

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                mode: .newBranch(name: "fork", start: .commit(start), upstream: nil),
                copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        // Assert
        let destination = fixture.destination()
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected a copy-on-write report")
            return
        }
        #expect(report.submodulesNotAtStart == ["sub-changed", "sub-new"])
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "sub-removed")))
        #expect(try fixture.blobID("HEAD", at: destination.appending(path: "sub-changed")) == changedCurrent)
        #expect(try text("tool.txt", in: destination.appending(path: "sub-changed")) == "tool.txt\n")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "sub-new").path).isEmpty)
        #expect(
            try fixture.git.run(["ls-files", "-s", "sub-changed"], currentDirectory: destination).contains(changedNext))
        #expect(try fixture.git.run(["ls-files", "sub-removed"], currentDirectory: destination).isEmpty)
    }

    @Test("an unchanged LFS file keeps the source's real content and a changed one is filled from the store")
    func largeFilesKeepRealContentOrAreFilled() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-lfs")
        defer { fixture.remove() }
        let samePayload = Data("same payload\n".utf8)
        let headPayload = Data("payload at head\n".utf8)
        let startPayload = Data("payload at start\n".utf8)
        try fixture.write(".gitattributes", "*.bin filter=lfs -text\n")
        try fixture.write("same.bin", Self.pointer(samePayload))
        try fixture.write("changed.bin", Self.pointer(headPayload))
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "lfs pointers")
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.write("changed.bin", Self.pointer(startPayload), in: starter)
            try fixture.git.run(["add", "changed.bin"], currentDirectory: starter)
        }
        try samePayload.write(to: fixture.source.appending(path: "same.bin"))
        try headPayload.write(to: fixture.source.appending(path: "changed.bin"))
        try Self.writeStoreObject(startPayload, in: fixture)
        try backdateSourceFiles(fixture)
        // Re-adding through a clean filter shaped like git-lfs's records the smudged files' stats against their
        // pointer blobs, as a git-lfs checkout leaves the index. A size mismatch alone would never be re-hashed.
        try fixture.git.run("-c", "filter.lfs.clean=\(Self.cleanFilter)", "add", "same.bin", "changed.bin")
        #expect(try fixture.statusLines(at: fixture.source).isEmpty)
        #expect(
            try fixture.stagedBlobID("same.bin", at: fixture.source)
                == fixture.blobID("HEAD:same.bin", at: fixture.source))
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                mode: .newBranch(name: "fork", start: .commit(start), upstream: nil),
                copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        // Assert
        #expect(try Data(contentsOf: destination.appending(path: "same.bin")) == samePayload)
        #expect(try modificationTime("same.bin", in: destination) == Self.backdated)
        #expect(try Data(contentsOf: destination.appending(path: "changed.bin")) == startPayload)
        #expect(
            try fixture.git.run(["ls-files", "-s", "changed.bin"], currentDirectory: destination)
                .contains(fixture.git.run("rev-parse", "\(start):changed.bin").trimmingCharacters(in: .newlines)))
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected a copy-on-write report")
            return
        }
        #expect(
            report.largeFiles == GitLargeFileFill(materializedCount: 1, missing: [], residuePaths: [], scan: .complete))
    }

    @Test("a sparse source comes out as a full checkout with no sparse state")
    func sparseSourceComesOutFull() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-sparse")
        defer { fixture.remove() }
        try fixture.write("kept/inside.txt", "inside\n")
        try fixture.write("outside/file.txt", "outside\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "two folders")
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.write("outside/file.txt", "outside at start\n", in: starter)
            try fixture.git.run(["add", "outside/file.txt"], currentDirectory: starter)
        }
        try fixture.git.run("sparse-checkout", "set", "--cone", "kept")
        #expect(!GitWorktreeForkFileProbe.exists(fixture.source.appending(path: "outside/file.txt")))
        let destination = fixture.destination()

        // Act
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                mode: .newBranch(name: "fork", start: .commit(start), upstream: nil),
                copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        // Assert
        #expect(try text("outside/file.txt", in: destination) == "outside at start\n")
        #expect(try text("kept/inside.txt", in: destination) == "inside\n")
        #expect(!(try fixture.git.run(["ls-files", "-t"], currentDirectory: destination).contains("S ")))
        #expect(!(try fixture.git.succeeds("config", "--get", "core.sparseCheckout", currentDirectory: destination)))
        #expect(
            !GitWorktreeForkFileProbe.exists(
                fixture.linkedWorktreeAdministration().appending(path: "info/sparse-checkout")))
        #expect(try fixture.statusLines(at: destination).isEmpty)
    }

    @Test("a failure right after the reset checkout rolls the whole fork back")
    func failureAfterResetCheckoutRollsBack() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-reset-rollback")
        defer { fixture.remove() }
        let start = try commitOnBranch("start", in: fixture) { starter in
            try fixture.write("start.txt", "start\n", in: starter)
            try fixture.git.run(["add", "start.txt"], currentDirectory: starter)
        }
        let injected = GitWorktreeForkError.entryFailed(
            relativePath: "injected", reason: .entryCreationFailed, errorNumber: nil)
        let faults = WorktreeForkFaultInjector { reached throws(GitWorktreeForkError) in
            if reached == .afterResetCheckout {
                throw injected
            }
        }
        let client = LibGit2AgentStudioGitLocalClient(worktreeForkWriter: LibGit2WorktreeForkWriter(faults: faults))
        let branchesBefore = try fixture.branchNames()

        // Act
        let failure: GitWorktreeForkError?
        do {
            _ = try await client.forkWorktree(
                fixture.request(
                    mode: .newBranch(name: "fork", start: .commit(start), upstream: nil),
                    copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))
            failure = nil
        } catch {
            failure = error
        }

        // Assert
        #expect(failure == injected)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.linkedWorktreeAdministration()))
        #expect(try fixture.branchNames() == branchesBefore)
    }

    // MARK: - Fixture helpers

    /// Commits on `branch` (created at the current HEAD) through a temporary linked worktree, so the main
    /// checkout keeps its own branch and working state.
    private func commitOnBranch(
        _ branch: String,
        in fixture: GitWorktreeForkFixture,
        _ change: (URL) throws -> Void
    ) throws -> String {
        let starter = fixture.repository.root.appending(path: "starter-\(branch)")
        try fixture.git.run("worktree", "add", "-q", "-b", branch, starter.path)
        try change(starter)
        try fixture.git.run(["commit", "-qm", "\(branch) change"], currentDirectory: starter)
        let commit = try fixture.blobID("HEAD", at: starter)
        try fixture.git.run("worktree", "remove", "--force", starter.path)
        return commit
    }

    private func makeIndependentRepository(at relativePath: String, in fixture: GitWorktreeForkFixture) throws {
        let root = fixture.source.appending(path: relativePath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: root)
        try fixture.write("dep.txt", "independent\n", in: root)
        try fixture.git.run(["add", "dep.txt"], currentDirectory: root)
        try fixture.git.run(["commit", "-qm", "dep"], currentDirectory: root)
    }

    /// Sets every working file's modification time into the past, outside `.git` directories.
    private func backdateSourceFiles(_ fixture: GitWorktreeForkFixture) throws {
        let enumerator = try #require(
            FileManager.default.enumerator(at: fixture.source, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            try FileManager.default.setAttributes([.modificationDate: Self.backdated], ofItemAtPath: url.path)
        }
    }

    private func modificationTime(_ relativePath: String, in root: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: root.appending(path: relativePath).path)[.modificationDate]
            as? Date
    }

    private func text(_ relativePath: String, in root: URL) throws -> String {
        try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    private static func pointer(_ payload: Data) -> String {
        "version https://git-lfs.github.com/spec/v1\noid sha256:\(sha256(payload))\nsize \(payload.count)\n"
    }

    private static func sha256(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeStoreObject(_ payload: Data, in fixture: GitWorktreeForkFixture) throws {
        let objectID = sha256(payload)
        let object = fixture.source.appending(
            path: ".git/lfs/objects/\(objectID.prefix(2))/\(objectID.dropFirst(2).prefix(2))/\(objectID)")
        try FileManager.default.createDirectory(
            at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: object)
    }

    /// Reads the payload on stdin and prints its LFS pointer, as `git lfs clean` does.
    private static let cleanFilter =
        #"f=$(mktemp); cat > "$f"; printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "#
        + #""$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')"; rm -f "$f""#
}
