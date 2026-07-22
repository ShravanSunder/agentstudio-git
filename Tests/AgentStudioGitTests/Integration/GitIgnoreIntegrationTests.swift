import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("GitIgnoreIntegrationTests", .serialized)
struct GitIgnoreIntegrationTests {
    @Test("ignore checks honor nested gitignore info exclude and global excludes")
    func ignoreChecksHonorAllGitIgnoreSources() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-sources")
        defer { fixture.remove() }
        let globalExcludes = fixture.root.appending(path: "global-excludes")
        try "global-ignored.txt\n".write(to: globalExcludes, atomically: true, encoding: .utf8)
        try fixture.git.run("config", "core.excludesFile", globalExcludes.path)
        try fixture.write(".gitignore", contents: "root-ignored.txt\n")
        try fixture.write("nested/.gitignore", contents: "nested-ignored.txt\n")
        try fixture.write(".git/info/exclude", contents: "info-ignored.txt\n")
        let client = LibGit2AgentStudioGitLocalClient()

        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "root-ignored.txt"
            )
        )
        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "nested/nested-ignored.txt"
            )
        )
        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "info-ignored.txt"
            )
        )
        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "global-ignored.txt"
            )
        )
        #expect(
            try await !client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "nested/kept.txt"
            )
        )
    }

    @Test("directory ignore checks are prune safe when parent exclusions swallow negations")
    func directoryIgnoreChecksArePruneSafe() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-prune")
        defer { fixture.remove() }
        try fixture.write(
            ".gitignore",
            contents: """
                ignored-dir/
                !ignored-dir/kept.txt
                contents-only/*
                !contents-only/kept.txt
                """
        )
        let client = LibGit2AgentStudioGitLocalClient()

        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "ignored-dir/"
            )
        )
        #expect(
            try await client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "ignored-dir/kept.txt"
            )
        )
        #expect(
            try await !client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "contents-only/"
            )
        )
        #expect(
            try await !client.isPathIgnored(
                repositoryAt: fixture.repositoryPath,
                relativePath: "contents-only/kept.txt"
            )
        )
    }

    @Test("batch ignore checks open repository once for hot walks")
    func batchIgnoreChecksOpenRepositoryOnceForHotWalks() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-batch")
        defer { fixture.remove() }
        try fixture.write(".gitignore", contents: "ignored-cache/\n")
        let client = LibGit2AgentStudioGitLocalClient()
        let relativePaths = [
            "ignored-cache/",
            "ignored-cache/generated-1.txt",
            "ignored-cache/generated-2.txt",
            "kept.txt",
        ]

        let checks = try await client.ignoredPaths(
            repositoryAt: fixture.repositoryPath,
            relativePaths: relativePaths
        )

        #expect(checks.map(\.relativePath) == relativePaths)
        #expect(checks.map(\.isIgnored) == [true, true, true, false])
    }

    @Test("batched ignore checks do not enumerate ignored directory contents")
    func batchedIgnoreChecksDoNotEnumerateIgnoredDirectoryContents() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-no-enumeration")
        defer { fixture.remove() }
        try fixture.write(".gitignore", contents: "ignored-cache/\n")
        let ignoredDirectory = fixture.repositoryPath.appending(path: "ignored-cache")
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: ignoredDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: ignoredDirectory.path
            )
        }
        #expect(throws: Error.self) {
            _ = try FileManager.default.contentsOfDirectory(at: ignoredDirectory, includingPropertiesForKeys: nil)
        }
        let client = LibGit2AgentStudioGitLocalClient()
        let relativePaths = (0..<5000).map { "ignored-cache/shard-\($0 / 100)/generated-\($0).txt" }

        let checks = try await client.ignoredPaths(
            repositoryAt: fixture.repositoryPath,
            relativePaths: relativePaths
        )

        #expect(checks.count == relativePaths.count)
        #expect(checks.allSatisfy { $0.isIgnored })
    }

    @Test("batched ignore checks do not read ignored file contents")
    func batchedIgnoreChecksDoNotReadIgnoredFileContents() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-unreadable-file")
        defer { fixture.remove() }
        try fixture.write(".gitignore", contents: "large-cache/\n")
        let ignoredDirectory = fixture.repositoryPath.appending(path: "large-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        let relativePath = "large-cache/unreadable.bin"
        let fileURL = fixture.repositoryPath.appending(path: relativePath)
        try Data([0x5A]).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        #expect(throws: Error.self) {
            _ = try Data(contentsOf: fileURL)
        }
        let client = LibGit2AgentStudioGitLocalClient()

        let checks = try await client.ignoredPaths(
            repositoryAt: fixture.repositoryPath,
            relativePaths: [relativePath]
        )

        #expect(checks == [GitIgnoreCheck(relativePath: relativePath, isIgnored: true)])
    }
}
