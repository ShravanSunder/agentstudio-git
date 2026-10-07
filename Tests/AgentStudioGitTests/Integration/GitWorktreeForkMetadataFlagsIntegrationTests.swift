import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

/// File flags and restrictive directory modes in ignored build output and nested repositories survive a
/// copy-on-write fork exactly, in the order that lets every child and hard link be created first.
@Suite("Git worktree fork metadata flags integration", .serialized)
struct GitWorktreeForkMetadataFlagsIntegrationTests {
    @Test(
        "a hard-linked file with a protecting flag keeps one inode, its payload, and its flag",
        arguments: ProtectingFlag.allCases)
    func protectedHardLinksKeepOneInode(flag: ProtectingFlag) async throws {
        // Arrange
        let fixture = try makeIgnoredBuildFixture(prefix: "agentstudio-git-fork-flagged-hardlink")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        let payload = "linked build output\n"
        try fixture.write(".build/out/first.bin", payload)
        let source = fixture.source
        #expect(
            link(
                source.appending(path: ".build/out/first.bin").path,
                source.appending(path: ".build/out/second.bin").path)
                == 0)
        #expect(chflags(source.appending(path: ".build/out/first.bin").path, flag.value) == 0)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        let first = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: ".build/out/first.bin")))
        let second = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: ".build/out/second.bin")))
        let sourceFirst = try #require(GitWorktreeForkFileProbe.info(source.appending(path: ".build/out/first.bin")))
        #expect(first.st_ino == second.st_ino)
        #expect(first.st_ino != sourceFirst.st_ino)
        #expect(first.st_flags & flag.value == flag.value)
        #expect(first.st_mode & 0o7777 == sourceFirst.st_mode & 0o7777)
        #expect(
            try String(contentsOf: destination.appending(path: ".build/out/second.bin"), encoding: .utf8) == payload)
        #expect(report.preservedHardLinkCount == 1)
        #expect(report.normalizedEntries.isEmpty)
    }

    @Test("an immutable build directory receives its children before its flag")
    func immutableDirectoryReceivesChildrenBeforeItsFlag() async throws {
        // Arrange
        let fixture = try makeIgnoredBuildFixture(prefix: "agentstudio-git-fork-immutable-directory")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        try fixture.write(".build/sealed/inner.bin", "sealed child\n")
        let sealed = fixture.source.appending(path: ".build/sealed")
        #expect(chflags(sealed.path, UInt32(UF_IMMUTABLE)) == 0)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        let destinationSealed = try #require(
            GitWorktreeForkFileProbe.info(destination.appending(path: ".build/sealed")))
        #expect(destinationSealed.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(
            try String(contentsOf: destination.appending(path: ".build/sealed/inner.bin"), encoding: .utf8)
                == "sealed child\n")
        #expect(report.normalizedEntries.isEmpty)
    }

    @Test("ordinary read-only build directories keep their mode")
    func readOnlyBuildDirectoriesKeepTheirMode() async throws {
        // Arrange
        let fixture = try makeIgnoredBuildFixture(prefix: "agentstudio-git-fork-readonly-build")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        try fixture.write(".build/artifacts/deep/cache.bin", "cached payload\n")
        let build = fixture.source.appending(path: ".build")
        try clearWriteBits(under: build)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        for relativePath in [".build", ".build/artifacts", ".build/artifacts/deep"] {
            let info = try #require(GitWorktreeForkFileProbe.info(destination.appending(path: relativePath)))
            #expect(info.st_mode & 0o7777 == 0o555, "\(relativePath)")
        }
        let cache = try #require(
            GitWorktreeForkFileProbe.info(destination.appending(path: ".build/artifacts/deep/cache.bin")))
        #expect(cache.st_mode & 0o7777 == 0o444)
        #expect(report.normalizedEntries.isEmpty)
    }

    @Test(
        "read-only submodule administration directories keep their mode after re-homing writes into them",
        arguments: NestedRepositoryShape.allCases
    )
    func readOnlyNestedAdministrationDirectoriesKeepTheirMode(shape: NestedRepositoryShape) async throws {
        // Arrange: a submodule whose whole administration tree, directories included, is read-only. The re-homer
        // writes HEAD and config into it, sparse state into info/, and alternates into objects/info.
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-readonly-nested-dirs")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        let nestedPath = "deps/dependency"
        let checkout = try makeSubmodule(shape, at: nestedPath, fixture: fixture)
        let sourceAdministration = try fixture.gitDirectory(of: checkout)
        try clearWriteBits(under: sourceAdministration)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        let nestedDestination = destination.appending(path: nestedPath)
        let destinationAdministration = try fixture.gitDirectory(of: nestedDestination)
        for relativePath in shape.administrationDirectories {
            let sourceInfo = try #require(
                GitWorktreeForkFileProbe.info(Self.directory(relativePath, in: sourceAdministration)))
            let info = try #require(
                GitWorktreeForkFileProbe.info(Self.directory(relativePath, in: destinationAdministration)))
            #expect(sourceInfo.st_mode & 0o7777 == 0o555, "\(relativePath) source")
            #expect(info.st_mode & 0o7777 == 0o555, "\(relativePath) destination")
        }
        #expect(try fixture.blobID("HEAD", at: nestedDestination) == fixture.blobID("HEAD", at: checkout))
        #expect(try fixture.statusLines(at: nestedDestination) == fixture.statusLines(at: checkout))
        switch shape {
        case .plain:
            break
        case .sparse:
            #expect(
                try fixture.git.run(["sparse-checkout", "list"], currentDirectory: nestedDestination)
                    == fixture.git.run(["sparse-checkout", "list"], currentDirectory: checkout))
        case .sharedObjects:
            #expect(
                try fixture.git.succeeds("cat-file", "-e", "HEAD:Package.swift", currentDirectory: nestedDestination))
        }
        #expect(report.preservedGitRepositoryCount == 1)
        #expect(report.normalizedEntries.isEmpty)
    }

    @Test("a read-only worktree root keeps its mode")
    func readOnlyWorktreeRootKeepsItsMode() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-readonly-root")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        #expect(chmod(fixture.source.path, 0o555) == 0)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        let info = try #require(GitWorktreeForkFileProbe.info(destination))
        #expect(info.st_mode & 0o7777 == 0o555)
        #expect(try fixture.statusLines(at: destination) == fixture.statusLines(at: fixture.source))
        #expect(report.normalizedEntries.isEmpty)
    }

    @Test("a nested Git administration directory keeps its immutable flag and extended attribute")
    func nestedAdministrationDirectoryKeepsFlagAndExtendedAttribute() async throws {
        // Arrange
        let fixture = try makeIgnoredBuildFixture(prefix: "agentstudio-git-fork-immutable-nested-dirs")
        defer {
            releaseProtections(under: fixture.repository.root)
            fixture.remove()
        }
        let nestedPath = ".build/checkouts/dependency"
        let checkout = try makeRepository(at: fixture.source.appending(path: nestedPath), fixture: fixture)
        let administration = checkout.appending(path: ".git")
        #expect(setxattr(administration.path, "com.agentstudio.probe", "admin", 5, 0, 0) == 0)
        #expect(chflags(administration.path, UInt32(UF_IMMUTABLE)) == 0)
        let destination = fixture.destination()

        // Act
        let result = try await LibGit2AgentStudioGitLocalClient().forkWorktree(fixture.request())

        // Assert
        let report = try copyOnWriteReport(result)
        let destinationAdministration = destination.appending(path: "\(nestedPath)/.git")
        let info = try #require(GitWorktreeForkFileProbe.info(destinationAdministration))
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(getxattr(destinationAdministration.path, "com.agentstudio.probe", nil, 0, 0, 0) == 5)
        #expect(
            try fixture.blobID("HEAD", at: destination.appending(path: nestedPath))
                == fixture.blobID("HEAD", at: checkout))
        #expect(report.normalizedEntries.isEmpty)
    }

    // MARK: - Helpers

    private func makeIgnoredBuildFixture(prefix: String) throws -> GitWorktreeForkFixture {
        let fixture = try GitWorktreeForkFixture.make(prefix: prefix)
        try fixture.write(".gitignore", ".build/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore build")
        return fixture
    }

    private func makeRepository(at path: URL, fixture: GitWorktreeForkFixture) throws -> URL {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try fixture.git.run(["init", "-q"], currentDirectory: path)
        try fixture.write("Package.swift", "// package\n", in: path)
        try fixture.git.run(["add", "."], currentDirectory: path)
        try fixture.git.run(["commit", "-qm", "initial"], currentDirectory: path)
        return path
    }

    /// A submodule at `relativePath` in the given shape: plain, sparse in its own working tree, or cloned with
    /// `--reference` so its objects come through alternates.
    private func makeSubmodule(
        _ shape: NestedRepositoryShape,
        at relativePath: String,
        fixture: GitWorktreeForkFixture
    ) throws -> URL {
        let origin = try makeRepository(at: fixture.repository.root.appending(path: "origin"), fixture: fixture)
        switch shape {
        case .plain:
            try fixture.git.run("submodule", "add", "-q", origin.path, relativePath)
        case .sparse:
            try fixture.write("kept/one.txt", "kept\n", in: origin)
            try fixture.write("dropped/two.txt", "dropped\n", in: origin)
            try fixture.git.run(["add", "."], currentDirectory: origin)
            try fixture.git.run(["commit", "-qm", "sparse tree"], currentDirectory: origin)
            try fixture.git.run("submodule", "add", "-q", origin.path, relativePath)
        case .sharedObjects:
            try fixture.git.run("submodule", "add", "-q", "--reference", origin.path, origin.path, relativePath)
        }
        try fixture.git.run("commit", "-qm", "submodule")
        let checkout = fixture.source.appending(path: relativePath)
        if shape == .sparse {
            try fixture.git.run(["sparse-checkout", "set", "--cone", "kept"], currentDirectory: checkout)
        }
        return checkout
    }

    /// `relativePath` beneath `administration`; empty names the administration directory itself.
    private static func directory(_ relativePath: String, in administration: URL) -> URL {
        relativePath.isEmpty ? administration : administration.appending(path: relativePath)
    }

    private func copyOnWriteReport(_ result: GitForkWorktreeResult) throws -> GitWorktreeMaterializationReport {
        guard case .copyOnWrite(let report) = result.materialization else {
            Issue.record("expected copy-on-write materialization")
            throw MetadataFlagsTestFailure.unexpectedMaterialization
        }
        return report
    }

    /// Clears every write bit beneath `root` and on `root`, deepest first, the way SwiftPM locks checkouts.
    private func clearWriteBits(under root: URL) throws {
        var nodes: [URL] = [root]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                nodes.append(url)
            }
        }
        for node in nodes.reversed() {
            guard let info = GitWorktreeForkFileProbe.info(node), info.st_mode & S_IFMT != S_IFLNK else {
                continue
            }
            #expect(chmod(node.path, info.st_mode & 0o7777 & ~0o222) == 0, "\(node.path)")
        }
    }

    /// Clears user flags and restores owner write and traversal on every node so fixture cleanup succeeds.
    private func releaseProtections(under root: URL) {
        func release(_ node: URL) {
            _ = lchflags(node.path, 0)
            if let info = GitWorktreeForkFileProbe.info(node), info.st_mode & S_IFMT != S_IFLNK {
                _ = chmod(node.path, (info.st_mode & 0o7777) | 0o700)
            }
        }
        release(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator {
            release(url)
        }
    }
}

enum ProtectingFlag: String, CaseIterable, Sendable {
    case immutable
    case appendOnly

    var value: UInt32 {
        switch self {
        case .immutable: UInt32(UF_IMMUTABLE)
        case .appendOnly: UInt32(UF_APPEND)
        }
    }
}

enum NestedRepositoryShape: String, CaseIterable, Sendable {
    case plain
    case sparse
    case sharedObjects

    /// Beneath the submodule's administration; empty names the administration directory itself.
    var administrationDirectories: [String] {
        switch self {
        case .plain: ["", "objects", "refs", "refs/heads", "info"]
        case .sparse: ["", "info", "objects"]
        case .sharedObjects: ["", "objects", "objects/info"]
        }
    }
}

private enum MetadataFlagsTestFailure: Error {
    case unexpectedMaterialization
}
