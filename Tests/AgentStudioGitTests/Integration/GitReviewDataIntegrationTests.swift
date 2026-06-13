import AgentStudioGit
import CryptoKit
import Foundation
import Testing

@Suite("Git review data integration", .serialized)
struct GitReviewDataIntegrationTests {
    @Test("revision resolution and tree reads expose commit backed review data")
    func revisionResolutionAndTreeReadsExposeCommitBackedReviewData() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let resolvedHead = try await client.resolveRevision(
            GitRevisionResolutionRequest(repositoryPath: fixture.repositoryPath, target: .named("HEAD"))
        )
        let resolvedBase = try await client.resolveRevision(
            GitRevisionResolutionRequest(repositoryPath: fixture.repositoryPath, target: .named(fixture.baseOID))
        )
        let rootTree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: nil)
        )
        let sourcesTree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: "Sources")
        )

        #expect(resolvedHead.oid == fixture.headOID)
        #expect(resolvedBase.oid == fixture.baseOID)
        #expect(rootTree.revision.oid == fixture.headOID)
        #expect(rootTree.entries.contains { $0.path == "Sources" && $0.isTree })
        #expect(rootTree.entries.contains { $0.path == "binary.bin" && !$0.isTree && $0.sizeBytes == 5 })
        #expect(sourcesTree.entries.contains { $0.path == "Sources/App.swift" && !$0.isTree })
    }

    @Test("diffs cover commit index and working-tree endpoints")
    func diffsCoverCommitIndexAndWorkingTreeEndpoints() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let commitDiff = try await client.diff(
            GitDiffRequest(
                repositoryPath: fixture.repositoryPath,
                base: .commit(fixture.baseOID),
                compare: .commit(fixture.headOID)
            )
        )
        try fixture.stageReviewChanges()

        let headToIndex = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .head, compare: .index)
        )
        try fixture.addWorkingTreeOnlyChanges()
        let objectCountBeforeWorktreeDiff = try fixture.looseObjectCount()
        let indexToWorktree = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .index, compare: .workingTree)
        )
        let objectCountAfterWorktreeDiff = try fixture.looseObjectCount()
        let headToWorktree = try await client.diff(
            GitDiffRequest(repositoryPath: fixture.repositoryPath, base: .head, compare: .workingTree)
        )

        let commitFiles = filesByPath(commitDiff.files)
        #expect(commitFiles["Sources/App.swift"]?.changeKind == .modified)
        #expect(commitFiles["Sources/New.swift"]?.changeKind == .added)
        #expect(commitFiles["Sources/App.swift"]?.oldContentHash != nil)
        #expect(commitFiles["Sources/App.swift"]?.newContentHash != nil)
        #expect(commitFiles["Sources/App.swift"]?.contentHashAlgorithm == "git-blob-sha1")

        let stagedFiles = filesByPath(headToIndex.files)
        #expect(stagedFiles["Docs/RenamedGuide.md"]?.changeKind == .renamed)
        #expect(stagedFiles["Docs/RenamedGuide.md"]?.previousPath == "Docs/Guide.md")
        #expect(stagedFiles["delete-me.txt"]?.changeKind == .deleted)
        #expect(stagedFiles["script.sh"]?.oldMode == 0o100644)
        #expect(stagedFiles["script.sh"]?.newMode == 0o100755)

        let worktreeFiles = filesByPath(indexToWorktree.files)
        let filteredCRLFHash = try fixture.filteredHash("crlf.crlf")
        #expect(objectCountAfterWorktreeDiff == objectCountBeforeWorktreeDiff)
        #expect(worktreeFiles["Sources/App.swift"]?.changeKind == .modified)
        #expect(worktreeFiles["worktree-only.txt"]?.changeKind == .added)
        #expect(worktreeFiles["large.txt"]?.sizeBytes == 2048)
        #expect(worktreeFiles["crlf.crlf"]?.newContentHash == filteredCRLFHash)
        #expect(worktreeFiles["crlf.crlf"]?.contentHashAlgorithm == "git-blob-sha1")

        let fullFiles = filesByPath(headToWorktree.files)
        #expect(fullFiles["binary.bin"]?.isBinary == true)
        #expect(fullFiles["binary.bin"]?.newContentHash != nil)
        #expect(fullFiles["Docs/RenamedGuide.md"]?.fileId != nil)
    }

    @Test("content reads load commit index and working-tree bytes and enforce size limits")
    func contentReadsLoadCommitIndexAndWorkingTreeBytesAndEnforceSizeLimits() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        let headContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .head, path: "Sources/App.swift")
        )
        let binaryContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .head, path: "binary.bin")
        )

        try fixture.stageReviewChanges()
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    30\n}\n")
        let indexContent = try await client.content(
            GitContentRequest(repositoryPath: fixture.repositoryPath, target: .index, path: "Sources/App.swift")
        )
        let worktreeContent = try await client.content(
            GitContentRequest(
                repositoryPath: fixture.repositoryPath,
                target: .workingTree,
                path: "Sources/App.swift"
            )
        )

        #expect(String(data: headContent.data, encoding: .utf8)?.contains("20") == true)
        #expect(headContent.contentHashAlgorithm == "sha256")
        #expect(headContent.contentHash == sha256ContentHash(headContent.data))
        #expect(!headContent.isBinary)
        #expect(binaryContent.isBinary)
        #expect(String(data: indexContent.data, encoding: .utf8)?.contains("10") == true)
        #expect(String(data: worktreeContent.data, encoding: .utf8)?.contains("30") == true)

        await #expect(
            throws: GitDataPlaneError.contentTooLarge(
                path: "large.txt",
                sizeBytes: 2048,
                maxSizeBytes: 16
            )
        ) {
            try await client.content(
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .workingTree,
                    path: "large.txt",
                    maxSizeBytes: 16
                )
            )
        }
    }

    @Test("working-tree content refuses paths that escape the repository")
    func workingTreeContentRefusesPathsThatEscapeTheRepository() async throws {
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        try fixture.writeOutsideRepository("outside.txt", contents: "outside\n")
        try fixture.createSymlinkToOutsideFile(named: "outside-link.txt", outsideName: "outside.txt")

        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "../outside.txt")) {
            try await client.content(
                GitContentRequest(repositoryPath: fixture.repositoryPath, target: .workingTree, path: "../outside.txt")
            )
        }
        await #expect(throws: GitDataPlaneError.pathEscapesRepository(path: "outside-link.txt")) {
            try await client.content(
                GitContentRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .workingTree,
                    path: "outside-link.txt"
                )
            )
        }
    }

    @Test("review APIs report missing repositories consistently")
    func reviewAPIsReportMissingRepositoriesConsistently() async {
        let missingRepositoryPath = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-git-missing-review-\(UUID().uuidString)")
        let client = LibGit2AgentStudioGitLocalClient()

        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.resolveRevision(
                GitRevisionResolutionRequest(repositoryPath: missingRepositoryPath, target: .named("HEAD"))
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.readTree(
                GitTreeReadRequest(repositoryPath: missingRepositoryPath, revision: .named("HEAD"), path: nil)
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.diff(
                GitDiffRequest(repositoryPath: missingRepositoryPath, base: .head, compare: .workingTree)
            )
        }
        await #expect(throws: GitDataPlaneError.repositoryNotFound(path: missingRepositoryPath)) {
            _ = try await client.content(
                GitContentRequest(repositoryPath: missingRepositoryPath, target: .head, path: "README.md")
            )
        }
    }
}

private struct ReviewDataFixture {
    let fixture: GitFixtureRepository
    let baseOID: String
    let headOID: String

    var repositoryPath: URL { fixture.repositoryPath }

    static func make() throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-data")
        try fixture.write(".gitattributes", contents: "*.crlf text eol=crlf\n")
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    10\n}\n")
        try fixture.write("Docs/Guide.md", contents: "guide\n")
        try fixture.write("delete-me.txt", contents: "remove me\n")
        try fixture.write("script.sh", contents: "#!/bin/sh\necho hello\n")
        try fixture.write("crlf.crlf", contents: "one\ntwo\n")
        try writeData(Data([0, 1, 2, 3, 255]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed review data")
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    20\n}\n")
        try fixture.write("Sources/New.swift", contents: "let created = true\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "update review data")
        let headOID = try fixture.git.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try fixture.write("large.txt", contents: String(repeating: "x", count: 2048))
        return Self(fixture: fixture, baseOID: baseOID, headOID: headOID)
    }

    func remove() {
        fixture.remove()
    }

    func write(_ relativePath: String, contents: String) throws {
        try fixture.write(relativePath, contents: contents)
    }

    func stageReviewChanges() throws {
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    10\n}\n")
        try fixture.git.run("add", "Sources/App.swift")
        try fixture.git.run("mv", "Docs/Guide.md", "Docs/RenamedGuide.md")
        try fixture.git.run("rm", "delete-me.txt")
        try fixture.git.run("update-index", "--chmod=+x", "script.sh")
        try writeData(Data([255, 3, 2, 1, 0]), to: "binary.bin", in: fixture.repositoryPath)
        try fixture.git.run("add", "binary.bin")
    }

    func addWorkingTreeOnlyChanges() throws {
        try fixture.write("Sources/App.swift", contents: "func value() -> Int {\n    30\n}\n")
        try fixture.write("crlf.crlf", contents: "one\ntwo\nthree\n")
        try fixture.write("worktree-only.txt", contents: "loose\n")
    }

    func filteredHash(_ relativePath: String) throws -> String {
        try fixture.git.run("hash-object", "--path=\(relativePath)", relativePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func looseObjectCount() throws -> Int {
        let output = try fixture.git.run("count-objects", "-v")
        let countLine = try #require(output.split(separator: "\n").first { $0.hasPrefix("count:") })
        let countValue = try #require(countLine.split(separator: " ").last)
        return try #require(Int(countValue))
    }

    func writeOutsideRepository(_ name: String, contents: String) throws {
        try contents.write(to: fixture.root.appending(path: name), atomically: true, encoding: .utf8)
    }

    func createSymlinkToOutsideFile(named name: String, outsideName: String) throws {
        try FileManager.default.createSymbolicLink(
            at: fixture.repositoryPath.appending(path: name),
            withDestinationURL: fixture.root.appending(path: outsideName)
        )
    }
}

private func filesByPath(_ files: [GitDiffFile]) -> [String: GitDiffFile] {
    Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
}

private func writeData(_ data: Data, to relativePath: String, in directory: URL) throws {
    let file = directory.appending(path: relativePath)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: file)
}

private func sha256ContentHash(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return "sha256:\(digest.map { String(format: "%02x", $0) }.joined())"
}
