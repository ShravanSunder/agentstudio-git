import AgentStudioGit
import CryptoKit
import Foundation
import Testing

@Suite("Git review data integration", .serialized)
struct GitReviewDataIntegrationTests {
    @Test("repository designation maps symbolic origin HEAD to the matching local branch")
    func repositoryDesignationMapsSymbolicOriginHeadToMatchingLocalBranch() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-local-default")
        defer { fixture.remove() }
        let remoteTipOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("update-ref", "refs/remotes/origin/main", remoteTipOID)
        try fixture.git.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        try fixture.write("local-only.txt", contents: "local integration work\n")
        try fixture.git.run("add", "local-only.txt")
        try fixture.git.run("commit", "-m", "local integration commit")
        let localTipOID = try fixture.git.run("rev-parse", "refs/heads/main").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let designation = try await client.localDefaultBranch(for: fixture.repositoryPath)
        let contribution = try await client.contributionDiff(
            GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named(try #require(designation?.referenceName))
            )
        )

        // Assert
        #expect(designation == GitLocalDefaultBranch(name: "main"))
        #expect(remoteTipOID != localTipOID)
        #expect(contribution.resolvedTarget.oid == localTipOID)
    }

    @Test("repository designation rejects absent direct malformed and missing-local references")
    func repositoryDesignationRejectsInvalidReferences() async throws {
        // Arrange
        let scenarios = try LocalDefaultBranchDesignationScenario.allCases.map { scenario in
            (scenario, try scenario.makeFixture())
        }
        defer {
            for (_, fixture) in scenarios {
                fixture.remove()
            }
        }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        for (scenario, fixture) in scenarios {
            let designation = try await client.localDefaultBranch(for: fixture.repositoryPath)

            // Assert
            #expect(designation == nil, "unexpected designation for \(scenario)")
        }
    }

    @Test(
        "contribution capture retains committed and dirty work across history shapes",
        arguments: ContributionHistoryShape.allCases
    )
    func contributionCaptureRetainsCommittedAndDirtyWork(historyShape: ContributionHistoryShape) async throws {
        // Arrange
        let fixture = try ContributionHistoryFixture.make(historyShape)
        defer { fixture.remove() }
        try fixture.addDirtyWorktreeChanges()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(snapshot.resolvedTarget.oid == fixture.targetOID)
        #expect(snapshot.reviewedHead.oid == fixture.reviewedHeadOID)
        #expect(snapshot.contributionBase.oid == fixture.expectedBaseOID)
        #expect(files["target-only.txt"] == nil)
        #expect(files["staged.txt"]?.changeKind == .added)
        #expect(files["README.md"]?.changeKind == .modified)
        #expect(files["untracked.txt"]?.changeKind == .added)
        #expect((files["feature.txt"] != nil) == historyShape.hasCommittedContribution)
    }

    @Test("target-only advancement changes target identity without changing contribution")
    func targetOnlyAdvancementChangesTargetIdentityWithoutChangingContribution() async throws {
        // Arrange
        let fixture = try ContributionHistoryFixture.make(.diverged)
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let expressionRequest = GitContributionDiffRequest(
            repositoryPath: fixture.request.repositoryPath,
            target: .named("\(fixture.request.target.name)^{commit}")
        )
        let predecessor = try await client.contributionDiff(expressionRequest)

        // Act
        let advancedTargetOID = try fixture.advanceTargetOnly()
        let successor = try await client.contributionDiff(expressionRequest)

        // Assert
        #expect(predecessor.resolvedTarget.oid != successor.resolvedTarget.oid)
        #expect(successor.resolvedTarget.oid == advancedTargetOID)
        #expect(predecessor.contributionBase == successor.contributionBase)
        #expect(predecessor.diff == successor.diff)
        #expect(filesByPath(successor.diff.files)["target-second.txt"] == nil)
    }

    @Test(arguments: FortyCharacterTargetScenario.allCases)
    func fortyCharacterTargetResolution(scenario: FortyCharacterTargetScenario) async throws {
        // Arrange
        let fixture = try scenario.makeFixture()
        defer { fixture.remove() }
        // Act
        let snapshot = try await LibGit2AgentStudioGitLocalClient().contributionDiff(fixture.request)
        // Assert
        #expect(snapshot.resolvedTarget == fixture.expectedRevision)
    }

    @Test("contribution capture preserves rename delete and binary facts")
    func contributionCapturePreservesRenameDeleteAndBinaryFacts() async throws {
        // Arrange
        let fixture = try RenameDeleteBinaryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(files["renamed.txt"]?.changeKind == .renamed)
        #expect(files["renamed.txt"]?.previousPath == "rename-source.txt")
        #expect(files["delete-source.txt"]?.changeKind == .deleted)
        #expect(files["binary.bin"]?.isBinary == true)
    }

    @Test("contribution capture preserves recreated content after a staged same-path deletion")
    func contributionCapturePreservesRecreatedContentAfterStagedSamePathDeletion() async throws {
        // Arrange
        let fixture = try SamePathOverlapFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.contributionDiff(fixture.request)
        let overlap = try #require(filesByPath(snapshot.diff.files)["overlap.txt"])

        // Assert
        #expect(overlap.changeKind == .modified)
        #expect(overlap.oldContentHash == fixture.originalContentHash)
        #expect(overlap.newContentHash == fixture.recreatedContentHash)
    }

    @Test("contribution capture rejects unresolved targets without a snapshot")
    func contributionCaptureRejectsUnresolvedTargetsWithoutASnapshot() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unresolved-target")
        defer { fixture.remove() }
        let request = GitContributionDiffRequest(
            repositoryPath: fixture.repositoryPath,
            target: .named("refs/heads/missing")
        )
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: GitDataPlaneError.revisionUnavailable(target: request.target)) {
            _ = try await client.contributionDiff(request)
        }
    }

    @Test(
        "contribution capture preserves target and HEAD failure identity without a snapshot",
        arguments: ContributionRevisionFailureScenario.allCases
    )
    func contributionCapturePreservesRevisionFailureIdentity(
        scenario: ContributionRevisionFailureScenario
    ) async throws {
        // Arrange
        let fixture = try scenario.makeFixture()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: fixture.expectedError) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects unrelated histories without a snapshot")
    func contributionCaptureRejectsUnrelatedHistoriesWithoutASnapshot() async throws {
        // Arrange
        let fixture = try UnrelatedHistoryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.noSharedHistory(
                targetOID: fixture.targetOID,
                headOID: fixture.reviewedHeadOID
            )
        ) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects missing ancestry without a partial snapshot")
    func contributionCaptureRejectsMissingAncestryWithoutAPartialSnapshot() async throws {
        // Arrange
        let fixture = try MissingAncestryFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        do {
            _ = try await client.contributionDiff(fixture.request)
            Issue.record("missing ancestry unexpectedly produced a contribution snapshot")
        } catch GitDataPlaneError.libgit2Failure(_, _, let message) {
            #expect(message.contains(fixture.missingCommitOID))
        } catch {
            Issue.record("expected libgit2 failure, got \(error)")
        }
    }

    @Test("contribution capture rejects multiple best merge bases without a snapshot")
    func contributionCaptureRejectsMultipleBestMergeBasesWithoutASnapshot() async throws {
        // Arrange
        let fixture = try MultipleBestMergeBasesFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.multipleBestMergeBases(
                targetOID: fixture.targetOID,
                headOID: fixture.reviewedHeadOID,
                count: 2
            )
        ) {
            _ = try await client.contributionDiff(fixture.request)
        }
    }

    @Test("contribution capture rejects unborn and missing HEAD without a snapshot")
    func contributionCaptureRejectsUnbornAndMissingHeadWithoutASnapshot() async throws {
        // Arrange
        let unbornFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unborn-head")
        let missingFixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-missing-head")
        defer {
            unbornFixture.remove()
            missingFixture.remove()
        }
        try unbornFixture.git.run("symbolic-ref", "HEAD", "refs/heads/unborn")
        try missingFixture.git.run("symbolic-ref", "HEAD", "refs/missing/HEAD")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        for fixture in [unbornFixture, missingFixture] {
            await #expect(throws: GitDataPlaneError.headUnavailable) {
                _ = try await client.contributionDiff(
                    GitContributionDiffRequest(
                        repositoryPath: fixture.repositoryPath,
                        target: .named("refs/heads/main")
                    )
                )
            }
        }
    }

    @Test("contribution capture rejects a missing required tree without a snapshot")
    func contributionCaptureRejectsMissingRequiredTreeWithoutASnapshot() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-missing-base-tree")
        defer { fixture.remove() }
        let treeOID = try fixture.git.run("rev-parse", "HEAD^{tree}").trimmed
        try FileManager.default.removeItem(at: fixture.looseObjectPath(oid: treeOID))
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(throws: GitDataPlaneError.requiredObjectNotFound(oid: treeOID)) {
            _ = try await client.contributionDiff(
                GitContributionDiffRequest(
                    repositoryPath: fixture.repositoryPath,
                    target: .named("refs/heads/main")
                )
            )
        }
    }

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

    @Test("tree reads preserve entries when blob size lookup cannot read an object")
    func treeReadsPreserveEntriesWhenBlobSizeLookupCannotReadAnObject() async throws {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-tree-missing-blob")
        defer { fixture.remove() }
        try fixture.write("MissingBlob.txt", contents: "content\n")
        try fixture.git.run("add", "MissingBlob.txt")
        try fixture.git.run("commit", "-m", "seed missing blob")
        let blobOID = try fixture.git.run("rev-parse", "HEAD:MissingBlob.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objectPath = fixture.repositoryPath
            .appending(path: ".git/objects")
            .appending(path: String(blobOID.prefix(2)))
            .appending(path: String(blobOID.dropFirst(2)))
        try FileManager.default.removeItem(at: objectPath)
        let client = LibGit2AgentStudioGitLocalClient()

        let tree = try await client.readTree(
            GitTreeReadRequest(repositoryPath: fixture.repositoryPath, revision: .named("HEAD"), path: nil)
        )
        let entry = try #require(tree.entries.first { $0.path == "MissingBlob.txt" })

        #expect(entry.oid == blobOID)
        #expect(entry.sizeBytes == nil)
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

    @Test("direct review comparison correlates a selected target with the working tree")
    func directReviewComparisonCorrelatesSelectedTargetWithWorkingTree() async throws {
        // Arrange
        let fixture = try ReviewDataFixture.make()
        defer { fixture.remove() }
        try fixture.stageReviewChanges()
        try fixture.addWorkingTreeOnlyChanges()
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let snapshot = try await client.directReviewComparison(
            GitDirectReviewComparisonRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named(fixture.baseOID)
            )
        )
        let files = filesByPath(snapshot.diff.files)

        // Assert
        #expect(snapshot.resolvedTarget.oid == fixture.baseOID)
        #expect(snapshot.reviewedHead.oid == fixture.headOID)
        #expect(files["Sources/App.swift"]?.changeKind == .modified)
        #expect(files["Sources/New.swift"]?.changeKind == .added)
        #expect(files["worktree-only.txt"]?.changeKind == .added)
        #expect(files["Docs/RenamedGuide.md"]?.changeKind == .renamed)
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
