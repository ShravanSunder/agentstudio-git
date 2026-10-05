import AgentStudioGit
import Foundation
import Testing

@Suite("Git worktree fork copy rules integration", .serialized)
struct GitWorktreeForkCopyRulesIntegrationTests {
    @Test("an ignored directory is copied by a direct pattern and by an ancestor pattern")
    func ignoredDirectoryMatchesDirectAndAncestorPatterns() async throws {
        for (patterns, destinationName) in [(["cache/"], "direct"), (["build/"], "ancestor")] {
            let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-rule")
            defer { fixture.remove() }
            try fixture.write(".gitignore", "build/\n")
            try fixture.git.run("add", ".gitignore")
            try fixture.git.run("commit", "-qm", "ignore build cache")
            try fixture.write("build/cache/output.bin", "cache\n")
            try fixture.write("build/other.bin", "other\n")
            let parsedPatterns = try patterns.map { try GitPathPattern($0) }

            let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
                fixture.request(
                    destination: fixture.destination(destinationName),
                    copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching(parsedPatterns))
                ))

            #expect(
                GitWorktreeForkFileProbe.exists(
                    fixture.destination(destinationName).appending(path: "build/cache/output.bin")))
            #expect(
                destinationName == "direct"
                    ? !GitWorktreeForkFileProbe.exists(
                        fixture.destination(destinationName).appending(path: "build/other.bin"))
                    : GitWorktreeForkFileProbe.exists(
                        fixture.destination(destinationName).appending(path: "build/other.bin")))
            guard case .copyOnWrite(let report) = result.materialization else {
                Issue.record("expected copy-on-write materialization")
                continue
            }
            #expect(report.ignoredIncludedPatterns == patterns)
        }
    }

    @Test("an ignored file is excluded and counted")
    func ignoredFileIsExcludedAndCounted() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-rule-file")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "ignored.txt\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore file")
        try fixture.write("ignored.txt", "ignored\n")
        try fixture.write("kept.txt", "kept\n")

        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination("fork").appending(path: "ignored.txt")))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination("fork").appending(path: "kept.txt")))
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(report.ignoredExcludedCount == 1)
    }

    @Test("copyAll preserves ignored content")
    func copyAllPreservesIgnoredContent() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-all")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "cache/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore cache")
        try fixture.write("cache/output.bin", "cache\n")

        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "cache/output.bin")))
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(report.ignoredExcludedCount == 0)
    }

    @Test("tracked content inside an ignored directory is retained while ignored leaves are filtered")
    func trackedContentInsideIgnoredDirectoryIsRetained() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-tracked")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "build/\n")
        try fixture.write("build/tracked.txt", "tracked\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("add", "-f", "build/tracked.txt")
        try fixture.git.run("commit", "-qm", "tracked ignored directory")
        try fixture.write("build/generated.txt", "generated\n")

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        let destination = fixture.destination()
        #expect(GitWorktreeForkFileProbe.exists(destination.appending(path: "build/tracked.txt")))
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "build/generated.txt")))
    }

    @Test("an included descendant keeps its directory chain while sibling ignored leaves are excluded")
    func includedDescendantKeepsDirectoryChain() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-descendant")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "ignored/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore descendant directory")
        try fixture.write("ignored/keep.txt", "keep\n")
        try fixture.write("ignored/drop.txt", "drop\n")

        let pattern = try GitPathPattern("ignored/keep.txt")
        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([pattern]))))

        let destination = fixture.destination()
        #expect(GitWorktreeForkFileProbe.exists(destination.appending(path: "ignored/keep.txt")))
        #expect(!GitWorktreeForkFileProbe.exists(destination.appending(path: "ignored/drop.txt")))
    }

    @Test("a HEAD-tracked file staged for deletion and recreated on disk is copied")
    func recreatedHeadTrackedFileRemainsTracked() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-head")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "tracked/\n")
        try fixture.write("tracked/file.txt", "head\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("add", "-f", "tracked/file.txt")
        try fixture.git.run("commit", "-qm", "tracked ignored path")
        try fixture.git.run("rm", "-q", "tracked/file.txt")
        try fixture.write("tracked/file.txt", "recreated\n")

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        #expect(
            try String(contentsOf: fixture.destination().appending(path: "tracked/file.txt"), encoding: .utf8)
                == "recreated\n")
    }

    @Test("a force-added ignored file is treated as tracked")
    func forceAddedIgnoredFileRemainsTracked() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-force-add")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "forced.txt\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore force-added file")
        try fixture.write("forced.txt", "forced\n")
        try fixture.git.run("add", "-f", "forced.txt")

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))

        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "forced.txt")))
    }

    @Test("a missing source index is treated as empty")
    func missingSourceIndexIsEmpty() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-index")
        defer { fixture.remove() }
        let index = fixture.source.appending(path: ".git/index")
        let hiddenIndex = fixture.source.appending(path: ".git/index.hidden")
        try FileManager.default.moveItem(at: index, to: hiddenIndex)
        defer { try? FileManager.default.moveItem(at: hiddenIndex, to: index) }

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "README.md")))

    }

    @Test("a same-repository nested linked worktree is skipped and its registry is unchanged")
    func sameRepositoryNestedLinkedWorktreeIsSkipped() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-nested")
        defer { fixture.remove() }
        try fixture.write("tracked/marker.txt", "marker\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tracked marker")
        let nested = fixture.source.appending(path: "nested")
        try fixture.git.run("worktree", "add", "-q", "-b", "nested-copy", nested.path)
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "nested")))
        #expect(try fixture.git.run("worktree", "list", "--porcelain").contains(nested.path))
        #expect(GitWorktreeForkFileProbe.exists(nested.appending(path: ".git")))
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            return
        }
        #expect(report.nestedWorktreesSkipped == ["nested"])
    }

    @Test("independent nested repository remains opaque to the root copy filter")
    func independentNestedRepositoryIsKeptWhole() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-independent")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "dependency/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore dependency")
        let dependency = fixture.source.appending(path: "dependency")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: dependency)
        try fixture.write("dependency.txt", "dependency\n", in: dependency)
        try fixture.git.run(["add", "."], currentDirectory: dependency)
        try fixture.git.run(["commit", "-qm", "dependency"], currentDirectory: dependency)

        _ = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([try GitPathPattern("dependency/")]))))

        let destinationDependency = fixture.destination().appending(path: "dependency")
        #expect(GitWorktreeForkFileProbe.exists(destinationDependency.appending(path: ".git")))
        #expect(GitWorktreeForkFileProbe.exists(destinationDependency.appending(path: "dependency.txt")))
    }

    @Test("an excluded hard-link primary elects a kept secondary")
    func excludedHardLinkPrimaryElectsKeptSecondary() async throws {
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-copy-hardlink")
        defer { fixture.remove() }
        try fixture.write("ignored.bin", "same\n")
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appending(path: "kept.bin"),
            withDestinationURL: fixture.source.appending(path: "ignored.bin"))
        try fixture.write(".gitignore", "ignored.bin\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore hardlink primary")
        try FileManager.default.removeItem(at: fixture.source.appending(path: "kept.bin"))
        try FileManager.default.linkItem(
            at: fixture.source.appending(path: "ignored.bin"), to: fixture.source.appending(path: "kept.bin"))
        try FileManager.default.linkItem(
            at: fixture.source.appending(path: "ignored.bin"), to: fixture.source.appending(path: "zz-kept.bin"))
        try fixture.git.run("add", "kept.bin")

        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: GitWorktreeCopyRules(ignoredPaths: .copyMatching([]))))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "ignored.bin")))
        #expect(try String(contentsOf: fixture.destination().appending(path: "kept.bin"), encoding: .utf8) == "same\n")
        let primary = try #require(GitWorktreeForkFileProbe.info(fixture.destination().appending(path: "kept.bin")))
        let secondary = try #require(
            GitWorktreeForkFileProbe.info(fixture.destination().appending(path: "zz-kept.bin")))
        #expect(primary.st_ino == secondary.st_ino)
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy report")
            return
        }
        #expect(report.preservedHardLinkCount == 1)
    }
}
