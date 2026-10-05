import AgentStudioGit
import Darwin
import Foundation
import Testing

@Suite("Git worktree copy rules review integration", .serialized)
struct GitWorktreeForkCopyRulesReviewIntegrationTests {
    @Test("independent nested repositories follow their location regardless of siblings", arguments: [false, true])
    func independentRepositoryLocation(addSibling: Bool) async throws {
        let fixture = try makeFixture("nested-location", ignores: "ignored/\n")
        defer { fixture.remove() }
        let origin = try fixture.makeIndependentWorktreeRepository()
        let nested = fixture.source.appending(path: "ignored/tool")
        try fixture.git.run("clone", "-q", origin.path, nested.path)
        if addSibling { try fixture.write("ignored/other.txt", "other\n") }
        let result = try await fork(fixture, patterns: [])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "ignored")))
        #expect(try report(result).preservedGitRepositoryCount == 0)
    }

    @Test(
        "bare repositories are opaque and source-index tracked descendants keep their chain", arguments: [false, true])
    func bareRepositoryIsOpaque(trackedAdministration: Bool) async throws {
        let fixture = try makeFixture(
            "bare-opaque", ignores: trackedAdministration ? "cache/\n" : "cache/tool/objects/\n")
        defer { fixture.remove() }
        let origin = try fixture.makeIndependentWorktreeRepository()
        let bare = fixture.source.appending(path: "cache/tool")
        try fixture.git.run("clone", "-q", "--bare", origin.path, bare.path)
        let sourceHead = try fixture.blobID("HEAD", at: bare)
        if trackedAdministration { try fixture.git.run("add", "-f", "cache/tool/HEAD") }
        _ = try await fork(fixture, patterns: [])
        let destination = fixture.destination().appending(path: "cache/tool")
        #expect(try fixture.blobID("HEAD", at: destination) == sourceHead)
        try fixture.git.run(["cat-file", "-e", "HEAD^{commit}"], currentDirectory: destination)
        #expect(GitWorktreeForkFileProbe.exists(destination.appending(path: "objects")))
    }

    @Test("a Git-shaped ordinary directory remains subject to path policy")
    func unconfirmedGitDirectoryIsOrdinary() async throws {
        let fixture = try makeFixture("git-shape", ignores: "fake/objects/\n")
        defer { fixture.remove() }
        try fixture.write("fake/HEAD", "ordinary text\n")
        try fixture.write("fake/objects/file", "ignored\n")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "fake/refs"), withIntermediateDirectories: true)
        _ = try await fork(fixture, patterns: [])
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "fake/HEAD")))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "fake/objects")))
    }

    @Test("an included independent nested repository is kept whole including its own ignored content")
    func includedIndependentRepository() async throws {
        let fixture = try makeFixture("included-nested", ignores: "ignored/\n")
        defer { fixture.remove() }
        let origin = try fixture.makeIndependentWorktreeRepository()
        let nested = fixture.source.appending(path: "ignored/tool")
        try fixture.git.run("clone", "-q", origin.path, nested.path)
        try fixture.write(".gitignore", "cache/\n", in: nested)
        try fixture.git.run(["add", ".gitignore"], currentDirectory: nested)
        try fixture.git.run(["commit", "-qm", "ignore nested cache"], currentDirectory: nested)
        try fixture.write("cache/output", "nested ignored\n", in: nested)
        try fixture.write("ignored/drop.txt", "drop\n")
        let result = try await fork(fixture, patterns: ["ignored/tool/"])
        let destination = fixture.destination().appending(path: "ignored/tool")
        #expect(GitWorktreeForkFileProbe.exists(destination.appending(path: ".git")))
        #expect(
            try String(contentsOf: destination.appending(path: "cache/output"), encoding: .utf8) == "nested ignored\n")
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "ignored/drop.txt")))
        #expect(try report(result).preservedGitRepositoryCount == 1)
    }

    @Test("submodules under ignored folders are kept from HEAD or index gitlinks", arguments: [false, true])
    func submoduleUnderIgnoredFolder(commitGitlink: Bool) async throws {
        let fixture = try makeFixture("ignored-submodule", ignores: "third_party/\n")
        defer { fixture.remove() }
        let origin = try fixture.makeIndependentWorktreeRepository()
        try fixture.git.run("submodule", "add", "-q", "-f", origin.path, "third_party/lib")
        if commitGitlink { try fixture.git.run("commit", "-qm", "submodule") }
        try fixture.write("third_party/NOTES.local", "ignored sibling\n")
        let sourceLibrary = fixture.source.appending(path: "third_party/lib")
        let sourceHead = try fixture.blobID("HEAD", at: sourceLibrary)
        let result = try await fork(fixture, patterns: [])
        let destinationLibrary = fixture.destination().appending(path: "third_party/lib")
        #expect(try fixture.blobID("HEAD", at: destinationLibrary) == sourceHead)
        #expect(GitWorktreeForkFileProbe.exists(destinationLibrary.appending(path: ".git")))
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "third_party/NOTES.local")))
        #expect(try report(result).preservedGitRepositoryCount == 1)
    }

    @Test("a tracked hard-link secondary is kept without its ignored siblings")
    func trackedHardLinkSecondary() async throws {
        let fixture = try makeFixture("tracked-secondary", ignores: "build/\n")
        defer { fixture.remove() }
        try fixture.write("aaa/data.bin", "shared bytes\n")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: fixture.source.appending(path: "aaa/data.bin"), to: fixture.source.appending(path: "build/data.bin"))
        try fixture.git.run("add", "-f", "build/data.bin")
        try fixture.write("build/drop.txt", "ignored\n")
        let result = try await fork(fixture, patterns: [])
        let primary = try #require(GitWorktreeForkFileProbe.info(fixture.destination().appending(path: "aaa/data.bin")))
        let secondary = try #require(
            GitWorktreeForkFileProbe.info(fixture.destination().appending(path: "build/data.bin")))
        #expect(primary.st_ino == secondary.st_ino)
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "build/drop.txt")))
        #expect(try report(result).ignoredExcludedCount == 1)
    }

    @Test("an unmatched ignored hard-link secondary is excluded and counted")
    func ignoredHardLinkSecondary() async throws {
        let fixture = try makeFixture("ignored-secondary", ignores: "build/*.bin\n")
        defer { fixture.remove() }
        try fixture.write("aaa.bin", "shared\n")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: fixture.source.appending(path: "aaa.bin"), to: fixture.source.appending(path: "build/ignored.bin"))
        try fixture.write("build/keep.txt", "kept\n")
        let result = try await fork(fixture, patterns: [])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "build/ignored.bin")))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "build/keep.txt")))
        #expect(try report(result).ignoredExcludedCount == 1)
        #expect(try report(result).preservedHardLinkCount == 0)
    }

    @Test("intent-to-add and conflicted index paths remain tracked", arguments: [false, true])
    func everyIndexStageAndFlag(conflicted: Bool) async throws {
        let fixture = try makeFixture("index-flags", ignores: "build/\n")
        defer { fixture.remove() }
        try fixture.write("build/carried.txt", "working content\n")
        if conflicted {
            let oid = try fixture.git.run("hash-object", "-w", "build/carried.txt").trimmingCharacters(
                in: .whitespacesAndNewlines)
            try fixture.git.run(
                ["update-index", "--index-info"],
                standardInput: Data("100644 \(oid) 2\tbuild/carried.txt\n100644 \(oid) 3\tbuild/carried.txt\n".utf8))
        } else {
            try fixture.git.run("add", "-N", "-f", "build/carried.txt")
        }
        _ = try await fork(fixture, patterns: [])
        #expect(
            try String(contentsOf: fixture.destination().appending(path: "build/carried.txt"), encoding: .utf8)
                == "working content\n")
    }

    @Test("a skip-worktree path present only in the index remains tracked")
    func skipWorktreeIndexPath() async throws {
        let fixture = try makeFixture("skip-worktree", ignores: "build/\n")
        defer { fixture.remove() }
        try fixture.write("build/carried.txt", "index-only content\n")
        try fixture.git.run("add", "-f", "build/carried.txt")
        try fixture.git.run("update-index", "--skip-worktree", "build/carried.txt")
        _ = try await fork(fixture, patterns: [])
        #expect(
            try String(contentsOf: fixture.destination().appending(path: "build/carried.txt"), encoding: .utf8)
                == "index-only content\n")
    }

    @Test("a missing index is empty while an unreadable existing index refuses", arguments: [false, true])
    func missingOrUnreadableIndex(unreadable: Bool) async throws {
        let fixture = try makeFixture("missing-index", ignores: "ignored/\n")
        defer { fixture.remove() }
        let index = fixture.source.appending(path: ".git/index")
        if unreadable {
            try #require(chmod(index.path, 0o000) == 0)
            defer { _ = chmod(index.path, 0o644) }
            do {
                _ = try await fork(fixture, patterns: [])
                Issue.record("expected unreadable index refusal")
            } catch let error as GitWorktreeForkError {
                #expect(error == .rejected(reason: .sourceIndexUnreadable))
            }
        } else {
            try FileManager.default.removeItem(at: index)
            _ = try await fork(fixture, patterns: [])
            #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "README.md")))
        }
    }

    @Test("split and sparse indexes refuse as unsupported", arguments: [false, true])
    func unsupportedIndexFormats(sparse: Bool) async throws {
        let fixture = try makeFixture("index-format", ignores: "ignored/\n")
        defer { fixture.remove() }
        try fixture.write("kept/file", "kept\n")
        try fixture.write("other/file", "other\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "sparse files")
        if sparse {
            try fixture.git.run("sparse-checkout", "init", "--cone", "--sparse-index")
            try fixture.git.run("sparse-checkout", "set", "kept")
        } else {
            try fixture.git.run("update-index", "--split-index")
        }
        do {
            _ = try await fork(fixture, patterns: [])
            Issue.record("expected unsupported index refusal")
        } catch let error as GitWorktreeForkError {
            if case .rejected(let reason) = error {
                #expect(reason.rawValue == "sourceIndexUnsupported")
            } else {
                Issue.record("wrong refusal: \(error)")
            }
        }
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
    }

    @Test("include matching and tracked lookup follow core.ignorecase")
    func caseFoldedIncludesAndTrackedPaths() async throws {
        let fixture = try makeFixture("case-fold", ignores: "frameworks/\ndocs/\n")
        defer { fixture.remove() }
        try fixture.git.run("config", "core.ignorecase", "true")
        try fixture.write("Docs/tracked.txt", "tracked\n")
        try fixture.git.run("add", "-f", "Docs/tracked.txt")
        try fixture.git.run("commit", "-qm", "tracked case")
        try FileManager.default.moveItem(
            at: fixture.source.appending(path: "Docs"), to: fixture.source.appending(path: "case-temp"))
        try FileManager.default.moveItem(
            at: fixture.source.appending(path: "case-temp"), to: fixture.source.appending(path: "docs"))
        try fixture.write("Frameworks/lib.bin", "included\n")
        let result = try await fork(fixture, patterns: ["frameworks/"])
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "docs/tracked.txt")))
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "Frameworks/lib.bin")))
        #expect(try report(result).ignoredIncludedPatterns == ["frameworks/"])
    }

    @Test("a non-ignored included parent keeps its ignored child and reports the pattern", arguments: [false, true])
    func includedNonIgnoredAncestor(childIgnored: Bool) async throws {
        let fixture = try makeFixture(
            "included-ancestor", ignores: childIgnored ? "Frameworks/GhosttyKit.xcframework\n" : "")
        defer { fixture.remove() }
        try fixture.write("Frameworks/GhosttyKit.xcframework/library.bin", "framework binary\n")
        try fixture.write("Frameworks/notes.txt", "non-ignored sibling\n")
        let result = try await fork(fixture, patterns: ["Frameworks/"])
        #expect(
            GitWorktreeForkFileProbe.exists(
                fixture.destination().appending(path: "Frameworks/GhosttyKit.xcframework/library.bin")))
        #expect(try report(result).ignoredIncludedPatterns == (childIgnored ? ["Frameworks/"] : []))
    }

    @Test("multi-level descendant includes retain their chain and exclude all siblings")
    func multiLevelIncludeAndCount() async throws {
        let fixture = try makeFixture("deep-includes", ignores: "ignored/\n")
        defer { fixture.remove() }
        for path in ["ignored/a/b/keep.txt", "ignored/sibling.txt", "ignored/a/drop.txt", "ignored/a/b/drop.txt"] {
            try fixture.write(path, path)
        }
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "ignored/empty"), withIntermediateDirectories: true)
        let result = try await fork(fixture, patterns: ["ignored/a/b/keep.txt"])
        #expect(GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "ignored/a/b/keep.txt")))
        for path in ["ignored/sibling.txt", "ignored/a/drop.txt", "ignored/a/b/drop.txt", "ignored/empty"] {
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: path)))
        }
        #expect(try report(result).ignoredExcludedCount == 4)
    }

    @Test("excluded count measures paths, including empty directories")
    func excludedPathCount() async throws {
        let fixture = try makeFixture("path-count", ignores: "cache/\n")
        defer { fixture.remove() }
        try fixture.write("cache/a", "a")
        try fixture.write("cache/nested/b", "b")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "cache/empty"), withIntermediateDirectories: true)
        let result = try await fork(fixture, patterns: [])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "cache")))
        #expect(try report(result).ignoredExcludedCount == 5)
    }

    @Test(
        "unopenable gitfiles follow location policy while stale source registrations are skipped",
        arguments: BrokenNestedGitfileScenario.allCases)
    func brokenNestedGitfiles(scenario: BrokenNestedGitfileScenario) async throws {
        let sameRepository = scenario == .sameRepository
        let ignored = scenario == .ignoredIndependent
        let nestedPath = ignored ? "ignored/nested" : "nested"
        let fixture = try makeFixture("broken-gitfile", ignores: ignored ? "ignored/\n" : "")
        defer { fixture.remove() }
        let target =
            sameRepository
            ? fixture.source.appending(path: ".git/worktrees/pruned")
            : fixture.repository.root.appending(path: "missing-independent-admin")
        try fixture.write("\(nestedPath)/.git", "gitdir: \(target.path)\n")
        try fixture.write("\(nestedPath)/file", "nested working content")
        do {
            let result = try await fork(fixture, patterns: [])
            #expect(sameRepository || ignored)
            #expect(try report(result).nestedWorktreesSkipped == (sameRepository ? ["nested"] : []))
            #expect(try report(result).ignoredExcludedCount == (ignored ? 3 : 0))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: nestedPath)))
        } catch let error as GitWorktreeForkError {
            #expect(!sameRepository && !ignored)
            #expect(
                error
                    == .entryFailed(
                        relativePath: "nested/.git", reason: .unresolvableGitAdministration, errorNumber: nil))
        }
    }

    enum BrokenNestedGitfileScenario: CaseIterable {
        case sameRepository
        case keptIndependent
        case ignoredIndependent
    }

    @Test("unopenable reftable directory administration follows location policy", arguments: [false, true])
    func reftableNestedDirectory(ignored: Bool) async throws {
        let fixture = try makeFixture("reftable-location", ignores: ignored ? "ignored/\n" : "")
        defer { fixture.remove() }
        let nestedPath = ignored ? "ignored/tool" : "tool"
        try fixture.git.run("init", "-q", "--ref-format=reftable", fixture.source.appending(path: nestedPath).path)
        try fixture.write("\(nestedPath)/file", "nested working content")
        do {
            let result = try await fork(fixture, patterns: [])
            #expect(ignored)
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "ignored")))
            #expect(try report(result).ignoredExcludedCount == 3)
            #expect(try report(result).nestedWorktreesSkipped.isEmpty)
        } catch let error as GitWorktreeForkError {
            #expect(!ignored)
            #expect(
                error
                    == .entryFailed(
                        relativePath: "\(nestedPath)/.git", reason: .unresolvableGitAdministration, errorNumber: nil))
        }
    }

    @Test("ignored sockets are skipped without contributing to the excluded path count")
    func ignoredSocketIsNotCounted() async throws {
        let fixture = GitWorktreeForkFixture(
            repository: try GitFixtureRepository.makeRepository(
                prefix: "cr-socket", rootDirectory: URL(fileURLWithPath: "/private/tmp")))
        defer { fixture.remove() }
        try fixture.write(".gitignore", "cache/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore socket")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "cache"), withIntermediateDirectories: true)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(fixture.source.appending(path: "cache/agent.sock").path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        try #require(
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        let result = try await fork(fixture, patterns: [])
        #expect(try report(result).ignoredExcludedCount == 1)  // the directory, never the socket
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "cache")))
    }

    @Test("symlinks to ignored directories remain links and are not matched by directory-only includes")
    func symbolicLinkDirectoryPolicy() async throws {
        let fixture = try makeFixture("symlink-dir", ignores: "cache/\nlink\n")
        defer { fixture.remove() }
        try fixture.write("cache/payload", "ignored cache")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.source.appending(path: "link").path,
            withDestinationPath: "cache")
        let result = try await fork(fixture, patterns: ["link/"])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: "link")))
        #expect(try report(result).ignoredIncludedPatterns.isEmpty)
    }

    private func makeFixture(_ label: String, ignores: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: "copy-review-\(label)")
        try fixture.write(".gitignore", ignores)
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore rules")
        return fixture
    }

    private func fork(_ fixture: GitWorktreeForkFixture, patterns: [String]) async throws -> GitForkWorktreeResult {
        try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(
                copyRules: GitWorktreeCopyRules(
                    ignoredPaths: .copyMatching(try patterns.map { try GitPathPattern($0) }))))
    }

    private func report(_ result: GitForkWorktreeResult) throws -> GitWorktreeMaterializationReport {
        guard case .copyOnWrite(let report) = result.materialization else { throw ReportFailure.wrongKind }
        return report
    }
    private enum ReportFailure: Error { case wrongKind }
}
