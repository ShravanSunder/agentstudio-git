import AgentStudioGit
import CryptoKit
import Foundation
import Testing

@Suite("Git large-file pointer Review integration", .serialized)
struct GitLargeFilePointerReviewIntegrationTests {
    @Test("matching smudged large-file content is clean while changed content remains modified")
    func matchingSmudgedLargeFileContentIsCleanWhileChangedContentRemainsModified() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-lfs")
        defer { fixture.remove() }
        let relativePath = "assets/app-icon.svg"
        let committedPayload = Data("<svg>committed payload</svg>\n".utf8)
        let changedPayload = Data("<svg>different payload</svg>\n".utf8)
        #expect(changedPayload.count == committedPayload.count)
        try fixture.write(
            ".gitattributes",
            contents: "*.svg filter=lfs diff=lfs merge=lfs -text\n"
        )
        try writeData(largeFilePointer(for: committedPayload), to: relativePath, in: fixture.repositoryPath)
        try fixture.git.run("add", ".gitattributes", relativePath)
        try fixture.git.run("commit", "-m", "track large-file pointer")
        try writeData(committedPayload, to: relativePath, in: fixture.repositoryPath)
        let client = LibGit2AgentStudioGitLocalClient()
        let request = GitDirectReviewComparisonRequest(
            repositoryPath: fixture.repositoryPath,
            target: .named("HEAD")
        )

        // Act
        let matchingResult = try await client.directReviewComparison(request)
        let matchingRefresh = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("HEAD"),
                refreshInput: .proportional(
                    seed: matchingResult.successorSeed,
                    changedPaths: [relativePath]
                )
            )
        )
        try writeData(changedPayload, to: relativePath, in: fixture.repositoryPath)
        let proportionalChangedResult = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("HEAD"),
                refreshInput: .proportional(
                    seed: matchingResult.successorSeed,
                    changedPaths: [relativePath]
                )
            )
        )
        let completeChangedResult = try await client.directReviewComparison(request)

        // Assert
        #expect(!matchingResult.snapshot.diff.files.contains { $0.path == relativePath })
        #expect(matchingRefresh.calculationDisposition == .proportionalFallback)
        #expect(matchingRefresh.calculationReason == .missingScopedRow)
        #expect(matchingRefresh.snapshot == matchingResult.snapshot)
        #expect(proportionalChangedResult.calculationDisposition == .proportional)
        #expect(proportionalChangedResult.snapshot == completeChangedResult.snapshot)
        #expect(
            proportionalChangedResult.snapshot.diff.files.first { $0.path == relativePath }?.changeKind
                == .modified
        )
    }

    @Test("worktree cleanliness never changes tree or index comparisons")
    func worktreeCleanlinessNeverChangesTreeOrIndexComparisons() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-lfs-sources")
        defer { fixture.remove() }
        let relativePath = "assets/app-icon.svg"
        let firstPayload = Data("<svg>first payload</svg>\n".utf8)
        let secondPayload = Data("<svg>second payload</svg>\n".utf8)
        try fixture.write(".gitattributes", contents: "*.svg filter=lfs diff=lfs merge=lfs -text\n")
        try writeData(largeFilePointer(for: firstPayload), to: relativePath, in: fixture.repositoryPath)
        try fixture.git.run("add", ".gitattributes", relativePath)
        try fixture.git.run("commit", "-m", "track first pointer")
        let firstCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try writeData(largeFilePointer(for: secondPayload), to: relativePath, in: fixture.repositoryPath)
        try fixture.git.run("add", relativePath)
        try writeData(firstPayload, to: relativePath, in: fixture.repositoryPath)
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let treeToIndex = try await client.diff(
            GitDiffRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(firstCommit),
                compare: .index
            )
        )
        try fixture.git.run("commit", "-m", "track second pointer")
        let secondCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let treeToTree = try await client.diff(
            GitDiffRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(firstCommit),
                compare: .commit(secondCommit)
            )
        )

        // Assert
        #expect(treeToIndex.files.first { $0.path == relativePath }?.changeKind == .modified)
        #expect(treeToTree.files.first { $0.path == relativePath }?.changeKind == .modified)
    }

    @Test("only strict standard pointers can suppress matching smudged content")
    func onlyStrictStandardPointersCanSuppressMatchingSmudgedContent() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-lfs-grammar")
        defer { fixture.remove() }
        let payload = Data("<svg>shared payload</svg>\n".utf8)
        let pointer = try #require(String(data: largeFilePointer(for: payload), encoding: .utf8))
        let oidLine = try #require(pointer.split(separator: "\n").first { $0.hasPrefix("oid ") })
        let sizeLine = try #require(pointer.split(separator: "\n").first { $0.hasPrefix("size ") })
        let uppercasePointer = pointer.replacingOccurrences(
            of: String(oidLine),
            with: String(oidLine).uppercased()
        )
        let pointerLikeContentByPath = [
            "assets/canonical-crlf.svg": Data(pointer.replacingOccurrences(of: "\n", with: "\r\n").utf8),
            "assets/reordered.svg": Data(
                "version https://git-lfs.github.com/spec/v1\n\(sizeLine)\n\(oidLine)\n".utf8
            ),
            "assets/duplicate.svg": Data("\(pointer)\(oidLine)\n".utf8),
            "assets/extra.svg": Data("\(pointer)unexpected value\n".utf8),
            "assets/uppercase.svg": Data(uppercasePointer.utf8),
            "assets/cutoff.svg": Data((pointer + String(repeating: "x", count: 1024 - pointer.utf8.count)).utf8),
        ]
        try fixture.write(".gitattributes", contents: "*.svg filter=lfs diff=lfs merge=lfs -text\n")
        for (relativePath, pointerLikeContent) in pointerLikeContentByPath {
            try writeData(pointerLikeContent, to: relativePath, in: fixture.repositoryPath)
        }
        try fixture.git.run("add", ".gitattributes", "assets")
        try fixture.git.run("commit", "-m", "track pointer grammar fixtures")
        for relativePath in pointerLikeContentByPath.keys {
            try writeData(payload, to: relativePath, in: fixture.repositoryPath)
        }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("HEAD")
            )
        ).snapshot
        let modifiedPaths = Set(snapshot.diff.files.map(\.path))

        // Assert
        #expect(!modifiedPaths.contains("assets/canonical-crlf.svg"))
        #expect(modifiedPaths.contains("assets/reordered.svg"))
        #expect(modifiedPaths.contains("assets/duplicate.svg"))
        #expect(modifiedPaths.contains("assets/extra.svg"))
        #expect(modifiedPaths.contains("assets/uppercase.svg"))
        #expect(modifiedPaths.contains("assets/cutoff.svg"))
    }

    @Test("matching smudged content never suppresses an executable-mode change")
    func matchingSmudgedContentNeverSuppressesExecutableModeChange() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-lfs-mode")
        defer { fixture.remove() }
        let relativePath = "assets/tool.svg"
        let payload = Data("<svg>tool payload</svg>\n".utf8)
        try fixture.git.run("config", "core.filemode", "true")
        try fixture.write(".gitattributes", contents: "*.svg filter=lfs diff=lfs merge=lfs -text\n")
        try writeData(largeFilePointer(for: payload), to: relativePath, in: fixture.repositoryPath)
        try fixture.git.run("add", ".gitattributes", relativePath)
        try fixture.git.run("commit", "-m", "track nonexecutable pointer")
        try writeData(payload, to: relativePath, in: fixture.repositoryPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.repositoryPath.appending(path: relativePath).path
        )
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("HEAD")
            )
        ).snapshot
        let file = try #require(snapshot.diff.files.first { $0.path == relativePath })

        // Assert
        #expect(file.changeKind == .modified)
        #expect(file.oldMode == 0o100644)
        #expect(file.newMode == 0o100755)
    }
}

private func largeFilePointer(for payload: Data) -> Data {
    let digest = SHA256.hash(data: payload)
    let oid = digest.map { String(format: "%02x", $0) }.joined()
    return Data(
        """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size \(payload.count)

        """.utf8
    )
}

private func writeData(_ data: Data, to relativePath: String, in directory: URL) throws {
    let file = directory.appending(path: relativePath)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: file)
}
