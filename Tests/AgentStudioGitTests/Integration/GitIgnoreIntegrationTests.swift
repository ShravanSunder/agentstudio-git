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

    @Test("ignore session handles hot walk query volume without crawling ignored contents")
    func ignoreSessionHandlesHotWalkQueryVolume() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-perf")
        defer { fixture.remove() }
        try fixture.write(".gitignore", contents: "ignored-cache/\n")
        let ignoredDirectory = fixture.repositoryPath.appending(path: "ignored-cache")
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        for index in 0..<100_000 {
            let shard = ignoredDirectory.appending(path: "shard-\(index / 1000)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
            let file = shard.appending(path: "generated-\(index).txt")
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let client = LibGit2AgentStudioGitLocalClient()
        let relativePaths = (0..<5000).map { "ignored-cache/generated-\($0).txt" }
        let clock = ContinuousClock()

        let duration = try await clock.measure {
            let checks = try await client.ignoredPaths(
                repositoryAt: fixture.repositoryPath,
                relativePaths: relativePaths
            )
            #expect(checks.count == relativePaths.count)
            #expect(checks.allSatisfy { $0.isIgnored })
        }

        #expect(duration < .seconds(1))
    }

    @Test("ignore session does not read large ignored file contents")
    func ignoreSessionDoesNotReadLargeIgnoredFileContents() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-ignore-large-files")
        defer { fixture.remove() }
        try fixture.write(".gitignore", contents: "large-cache/\n")
        let ignoredDirectory = fixture.repositoryPath.appending(path: "large-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        let relativePaths = (0..<32).map { "large-cache/blob-\($0).bin" }
        for relativePath in relativePaths {
            let fileURL = fixture.repositoryPath.appending(path: relativePath)
            try payload.write(to: fileURL)
        }
        let client = LibGit2AgentStudioGitLocalClient()
        let clock = ContinuousClock()

        let duration = try await clock.measure {
            let checks = try await client.ignoredPaths(
                repositoryAt: fixture.repositoryPath,
                relativePaths: relativePaths
            )
            #expect(checks.count == relativePaths.count)
            #expect(checks.allSatisfy { $0.isIgnored })
        }

        #expect(duration < .seconds(1))
    }
}
