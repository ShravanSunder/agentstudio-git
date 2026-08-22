import AgentStudioGit
import Foundation
import Testing

@Suite("Git bounded diff impact summary integration")
struct GitDiffImpactSummaryIntegrationTests {
    @Test("stops diff generation at the changed-file cap")
    func stopsAtChangedFileCap() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-diff-impact-file-cap")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        for fileIndex in 1...4 {
            try fixture.write("file-\(fileIndex).swift", contents: "let value\(fileIndex) = \(fileIndex)\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "add four files")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let summary = try await client.summarizeDiffImpact(
            GitDiffImpactSummaryRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(baseOID),
                compare: .commit(candidateOID),
                maximumChangedFileCount: 2,
                maximumChangedLineCount: 100,
                maximumDiffableBlobByteCount: 1_048_576
            )
        )

        // Assert
        #expect(summary.pathsAreComplete == false)
        #expect(summary.changedPaths.count == 2)
        #expect(summary.changedFileCount == .atLeastLimit(2))
        #expect(summary.changedLineCount == .indeterminate)
        #expect(summary.addedLineCount == nil)
        #expect(summary.deletedLineCount == nil)
    }

    @Test("stops patch work at the changed-line cap while retaining complete paths")
    func stopsAtChangedLineCap() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-diff-impact-line-cap")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("README.md", contents: "one\ntwo\nthree\nfour\nfive\n")
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "expand readme")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let summary = try await client.summarizeDiffImpact(
            GitDiffImpactSummaryRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(baseOID),
                compare: .commit(candidateOID),
                maximumChangedFileCount: 10,
                maximumChangedLineCount: 3,
                maximumDiffableBlobByteCount: 1_048_576
            )
        )

        // Assert
        #expect(summary.pathsAreComplete)
        #expect(summary.changedPaths == [GitDiffImpactPath(currentPath: "README.md", previousPath: nil)])
        #expect(summary.changedFileCount == .exact(1))
        #expect(summary.changedLineCount == .atLeastLimit(3))
        let partialAddedLineCount = try #require(summary.addedLineCount)
        let partialDeletedLineCount = try #require(summary.deletedLineCount)
        #expect(partialAddedLineCount >= 0)
        #expect(partialDeletedLineCount >= 0)
        #expect(partialAddedLineCount + partialDeletedLineCount >= 3)
    }

    @Test("reports rename and deletion paths exactly below both caps")
    func reportsRenameAndDeletionPaths() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-diff-impact-paths")
        defer { fixture.remove() }
        try fixture.write("rename-me.swift", contents: "let renamed = true\n")
        try fixture.write("delete-me.swift", contents: "let deleted = true\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "add impact paths")
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("mv", "rename-me.swift", "renamed.swift")
        try fixture.git.run("rm", "delete-me.swift")
        try fixture.git.run("commit", "-m", "rename and delete")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let summary = try await client.summarizeDiffImpact(
            GitDiffImpactSummaryRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(baseOID),
                compare: .commit(candidateOID),
                maximumChangedFileCount: 10,
                maximumChangedLineCount: 100,
                maximumDiffableBlobByteCount: 1_048_576
            )
        )

        // Assert
        #expect(summary.pathsAreComplete)
        #expect(
            summary.changedPaths == [
                GitDiffImpactPath(currentPath: nil, previousPath: "delete-me.swift"),
                GitDiffImpactPath(currentPath: "renamed.swift", previousPath: "rename-me.swift"),
            ]
        )
        #expect(summary.changedFileCount == .exact(2))
        #expect(summary.changedLineCount == .exact(1))
        #expect(summary.addedLineCount == 0)
        #expect(summary.deletedLineCount == 1)
    }

    @Test("returns indeterminate line impact for an oversized single-line blob")
    func returnsIndeterminateForOversizedBlob() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-diff-impact-blob-cap")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("large-line.txt", contents: String(repeating: "x", count: 1024))
        try fixture.git.run("add", "large-line.txt")
        try fixture.git.run("commit", "-m", "add oversized line")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let summary = try await client.summarizeDiffImpact(
            GitDiffImpactSummaryRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(baseOID),
                compare: .commit(candidateOID),
                maximumChangedFileCount: 10,
                maximumChangedLineCount: 100,
                maximumDiffableBlobByteCount: 64
            )
        )

        // Assert
        #expect(summary.pathsAreComplete)
        #expect(summary.changedPaths == [GitDiffImpactPath(currentPath: "large-line.txt", previousPath: nil)])
        #expect(summary.changedFileCount == .exact(1))
        #expect(summary.changedLineCount == .indeterminate)
        #expect(summary.addedLineCount == nil)
        #expect(summary.deletedLineCount == nil)
    }

    @Test("rejects nonpositive diff-impact caps before opening the repository")
    func rejectsNonpositiveCaps() async {
        // Arrange
        let missingRepository = URL(fileURLWithPath: "/path/that/does/not/exist")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.unsupported(
                message: "diff impact maximumChangedFileCount must be positive"
            )
        ) {
            _ = try await client.summarizeDiffImpact(
                GitDiffImpactSummaryRequest(
                    repositoryPath: missingRepository,
                    base: .head,
                    compare: .workingTree,
                    maximumChangedFileCount: 0,
                    maximumChangedLineCount: 100,
                    maximumDiffableBlobByteCount: 1_048_576
                )
            )
        }
        await #expect(
            throws: GitDataPlaneError.unsupported(
                message: "diff impact maximumChangedLineCount must be positive"
            )
        ) {
            _ = try await client.summarizeDiffImpact(
                GitDiffImpactSummaryRequest(
                    repositoryPath: missingRepository,
                    base: .head,
                    compare: .workingTree,
                    maximumChangedFileCount: 25,
                    maximumChangedLineCount: 0,
                    maximumDiffableBlobByteCount: 1_048_576
                )
            )
        }
        await #expect(
            throws: GitDataPlaneError.unsupported(
                message: "diff impact maximumDiffableBlobByteCount must be positive"
            )
        ) {
            _ = try await client.summarizeDiffImpact(
                GitDiffImpactSummaryRequest(
                    repositoryPath: missingRepository,
                    base: .head,
                    compare: .workingTree,
                    maximumChangedFileCount: 25,
                    maximumChangedLineCount: 1000,
                    maximumDiffableBlobByteCount: 0
                )
            )
        }
    }
}
