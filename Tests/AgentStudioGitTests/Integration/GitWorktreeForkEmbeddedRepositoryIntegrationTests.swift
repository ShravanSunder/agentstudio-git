import AgentStudioGit
import Darwin
import Foundation
import Testing

/// A repository inside a copied folder that is neither a registered submodule nor a linked worktree of the
/// source repository is part of the checkout as it is. SwiftPM's package checkouts are the common case: clones
/// made with `--shared` whose own object store is empty and whose alternates may name a cache that no longer
/// exists. The fork copies such a repository's `.git` like any other content, broken or not.
@Suite("Git worktree fork embedded repository integration", .serialized)
struct GitWorktreeForkEmbeddedRepositoryIntegrationTests {
    @Test("a shared clone whose alternates name a removed store is copied byte for byte")
    func sharedCloneWithDanglingAlternatesIsCopied() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-embedded-dangling")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let checkout = try makeSharedCheckout(fixture: fixture, upstreamName: "upstream")
        let movedUpstream = fixture.repository.root.appending(path: "upstream-moved")
        try FileManager.default.moveItem(at: fixture.repository.root.appending(path: "upstream"), to: movedUpstream)
        let sourceAlternates = try alternatesText(of: checkout.source)
        let sourceContent = try GitWorktreeForkFileProbe.contentTree(at: checkout.source)

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: includingBuildFolder()))

        // Assert
        let destinationCheckout = fixture.destination().appending(path: checkout.relativePath)
        #expect(try GitWorktreeForkFileProbe.contentTree(at: destinationCheckout) == sourceContent)
        #expect(try alternatesText(of: destinationCheckout) == sourceAlternates)
        #expect(sourceAlternates.hasSuffix("/upstream/.git/objects\n"))
        #expect(!GitWorktreeForkFileProbe.exists(objectMirrors(fixture)))
        #expect(try report(result).preservedGitRepositoryCount == 0)
    }

    @Test("a shared clone whose alternates still resolve is copied byte for byte, without an object mirror")
    func sharedCloneWithValidAlternatesIsCopiedWithoutMirror() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-embedded-valid")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let checkout = try makeSharedCheckout(fixture: fixture, upstreamName: "upstream")
        let sourceAlternates = try alternatesText(of: checkout.source)
        let sourceContent = try GitWorktreeForkFileProbe.contentTree(at: checkout.source)
        let sourceHead = try fixture.blobID("HEAD", at: checkout.source)

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: includingBuildFolder()))

        // Assert
        let destinationCheckout = fixture.destination().appending(path: checkout.relativePath)
        #expect(try GitWorktreeForkFileProbe.contentTree(at: destinationCheckout) == sourceContent)
        #expect(try alternatesText(of: destinationCheckout) == sourceAlternates)
        #expect(!GitWorktreeForkFileProbe.exists(objectMirrors(fixture)))
        #expect(try fixture.blobID("HEAD", at: destinationCheckout) == sourceHead)
        #expect(try report(result).preservedGitRepositoryCount == 0)
    }

    @Test(
        "an initialized submodule keeps destination administration beside a broken embedded repository",
        arguments: ForkedWorktreeKind.allCases)
    func submoduleKeepsAdministrationBesideBrokenEmbeddedRepository(kind: ForkedWorktreeKind) async throws {
        // Arrange: in a linked worktree, the submodule's administration lives under that worktree's own
        // `worktrees/<name>/modules`, beside the same-repository registrations the fork skips.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-embedded-submodule")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let sourceRoot: URL
        switch kind {
        case .mainWorktree:
            sourceRoot = fixture.source
        case .linkedWorktree:
            sourceRoot = fixture.repository.root.appending(path: "linked-source")
            try fixture.git.run("worktree", "add", "-q", "-b", "linked-source", sourceRoot.path)
        }
        let library = try makeRepository(
            at: fixture.repository.root.appending(path: "library"), file: "library.txt", fixture: fixture)
        try fixture.git.run(["submodule", "add", "-q", library.path, "deps/library"], currentDirectory: sourceRoot)
        try fixture.git.run(["commit", "-qm", "submodule"], currentDirectory: sourceRoot)
        let checkout = try makeSharedCheckout(in: sourceRoot, fixture: fixture, upstreamName: "upstream")
        try FileManager.default.moveItem(
            at: fixture.repository.root.appending(path: "upstream"),
            to: fixture.repository.root.appending(path: "upstream-moved"))
        let sourceContent = try GitWorktreeForkFileProbe.contentTree(at: checkout.source)
        let sourceSubmoduleHead = try fixture.blobID("HEAD", at: sourceRoot.appending(path: "deps/library"))

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            GitForkWorktreeRequest(
                sourceWorktreePath: sourceRoot,
                destinationPath: fixture.destination(),
                mode: .newBranch(name: "fork"),
                materialization: .copyOnWrite,
                copyRules: try includingBuildFolder()
            ))

        // Assert
        let destinationSubmodule = fixture.destination().appending(path: "deps/library")
        #expect(try fixture.blobID("HEAD", at: destinationSubmodule) == sourceSubmoduleHead)
        #expect(
            try fixture.gitDirectory(of: destinationSubmodule).path
                == canonical(fixture.linkedWorktreeAdministration()).appending(path: "modules/deps/library").path)
        #expect(try fixture.statusLines(at: destinationSubmodule).isEmpty)
        #expect(
            try GitWorktreeForkFileProbe.contentTree(at: fixture.destination().appending(path: checkout.relativePath))
                == sourceContent)
        #expect(try report(result).preservedGitRepositoryCount == 1)
        #expect(try report(result).nestedWorktreesSkipped.isEmpty)
    }

    @Test("a same-repository linked worktree under an included folder is still skipped and reported")
    func sameRepositoryWorktreeUnderIncludedFolderIsSkipped() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-embedded-same-repository")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let nestedWorktree = fixture.source.appending(path: ".build/worktrees/agent")
        try fixture.git.run("worktree", "add", "-q", "-b", "agent", nestedWorktree.path)
        let checkout = try makeSharedCheckout(fixture: fixture, upstreamName: "upstream")
        try FileManager.default.moveItem(
            at: fixture.repository.root.appending(path: "upstream"),
            to: fixture.repository.root.appending(path: "upstream-moved"))
        let sourceContent = try GitWorktreeForkFileProbe.contentTree(at: checkout.source)

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: includingBuildFolder()))

        // Assert
        #expect(try report(result).nestedWorktreesSkipped == [".build/worktrees/agent"])
        #expect(!GitWorktreeForkFileProbe.exists(fixture.destination().appending(path: ".build/worktrees/agent")))
        #expect(try fixture.git.run("worktree", "list", "--porcelain").contains(nestedWorktree.path))
        #expect(
            try GitWorktreeForkFileProbe.contentTree(at: fixture.destination().appending(path: checkout.relativePath))
                == sourceContent)
    }

    @Test("objects hard-linked between an in-tree bare cache and an embedded repository stay one inode")
    func objectsHardLinkedAcrossBareCacheAndEmbeddedRepositoryStayLinked() async throws {
        // Arrange: a local clone hard-links its objects to the bare cache it was cloned from, so one inode has a
        // path in ordinary content and another inside the embedded repository's `.git`.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-embedded-hard-links")
        defer { fixture.remove() }
        try ignore(".build/", fixture: fixture)
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: "upstream"), file: "Package.swift", fixture: fixture)
        let cache = fixture.source.appending(path: ".build/repositories/package.git")
        try fixture.git.run(["clone", "-q", "--bare", upstream.path, cache.path])
        let checkout = fixture.source.appending(path: ".build/checkouts/package")
        try fixture.git.run(["clone", "-q", "--local", cache.path, checkout.path])
        let linkedObjects = try hardLinkedObjectPaths(cache: cache, checkout: checkout)
        try #require(!linkedObjects.isEmpty, "the local clone shares object inodes with its cache")
        let sourceContent = try GitWorktreeForkFileProbe.contentTree(at: checkout)

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(
            fixture.request(copyRules: includingBuildFolder()))

        // Assert
        let destination = fixture.destination()
        for (cachePath, checkoutPath) in linkedObjects {
            let cacheCopy = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: cachePath)))
            let checkoutCopy = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: checkoutPath)))
            #expect(cacheCopy.st_ino == checkoutCopy.st_ino, "\(checkoutPath)")
        }
        #expect(
            try GitWorktreeForkFileProbe.contentTree(at: destination.appending(path: ".build/checkouts/package"))
                == sourceContent)
        #expect(try report(result).preservedHardLinkCount >= linkedObjects.count)
    }

    /// Source-root-relative pairs of loose object files the checkout shares, by inode, with the cache.
    private func hardLinkedObjectPaths(cache: URL, checkout: URL) throws -> [(String, String)] {
        let cacheObjects = cache.appending(path: "objects")
        var pairs: [(String, String)] = []
        for directory in try FileManager.default.contentsOfDirectory(atPath: cacheObjects.path)
        where directory.count == 2 {
            for name in try FileManager.default.contentsOfDirectory(
                atPath: cacheObjects.appending(path: directory).path)
            {
                let objectPath = "objects/\(directory)/\(name)"
                guard let cacheInfo = GitWorktreeForkFileProbe.info(cache.appending(path: objectPath)),
                    let checkoutInfo = GitWorktreeForkFileProbe.info(checkout.appending(path: ".git/\(objectPath)")),
                    cacheInfo.st_ino == checkoutInfo.st_ino
                else {
                    continue
                }
                pairs.append(
                    (
                        ".build/repositories/package.git/\(objectPath)",
                        ".build/checkouts/package/.git/\(objectPath)"
                    ))
            }
        }
        return pairs
    }

    private struct NestedCheckout {
        let relativePath: String
        let source: URL
    }

    /// A SwiftPM-style package checkout: a `--shared` clone of an upstream outside the source tree, so its
    /// own object store is empty and every object comes through `objects/info/alternates`.
    private func makeSharedCheckout(
        in sourceRoot: URL? = nil,
        fixture: GitWorktreeForkFixture,
        upstreamName: String
    ) throws -> NestedCheckout {
        let upstream = try makeRepository(
            at: fixture.repository.root.appending(path: upstreamName), file: "Package.swift", fixture: fixture)
        let relativePath = ".build/checkouts/package"
        let checkout = (sourceRoot ?? fixture.source).appending(path: relativePath)
        try fixture.git.run(["clone", "-q", "--shared", upstream.path, checkout.path])
        return NestedCheckout(relativePath: relativePath, source: checkout)
    }

    private func includingBuildFolder() throws -> GitWorktreeCopyRules {
        GitWorktreeCopyRules(ignoredPaths: .copyMatching([try GitPathPattern(".build/")]))
    }

    private func objectMirrors(_ fixture: GitWorktreeForkFixture) -> URL {
        fixture.linkedWorktreeAdministration().appending(path: "agentstudio-object-mirrors")
    }

    private func alternatesText(of checkout: URL) throws -> String {
        try String(contentsOf: checkout.appending(path: ".git/objects/info/alternates"), encoding: .utf8)
    }

    private func report(_ result: GitForkWorktreeResult) throws -> GitWorktreeMaterializationReport {
        guard case .copyOnWrite(let report) = result.materialization else {
            throw GitWorktreeForkEmbeddedRepositoryTestFailure.notCopyOnWrite
        }
        return report
    }

    private func ignore(_ pattern: String, fixture: GitWorktreeForkFixture) throws {
        try fixture.write(".gitignore", "\(pattern)\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore \(pattern)")
    }

    private func makeRepository(at path: URL, file: String, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write(file, "\(file)\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    private func canonical(_ url: URL) throws -> URL {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

enum ForkedWorktreeKind: String, CaseIterable, Sendable {
    case mainWorktree
    case linkedWorktree
}

private enum GitWorktreeForkEmbeddedRepositoryTestFailure: Error {
    case notCopyOnWrite
}
