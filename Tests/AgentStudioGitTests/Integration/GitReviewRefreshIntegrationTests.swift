import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

extension GitReviewDataIntegrationTests {
    @Test("complete contribution and direct calculations return reusable local seeds")
    func completeReviewCalculationsReturnReusableLocalSeeds() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let contribution = try await client.contributionDiff(fixture.contributionRequest())
        let direct = try await client.directReviewComparison(fixture.directRequest())

        // Assert
        #expect(contribution.calculationDisposition == .complete)
        #expect(contribution.calculationReason == .completeRequested)
        #expect(direct.calculationDisposition == .complete)
        #expect(direct.calculationReason == .completeRequested)
        #expect(contribution.snapshot.diff == direct.snapshot.diff)
    }

    @Test("equal complete proportional and fallback results each return a reusable successor seed")
    func equalResultsReturnReusableSuccessorSeeds() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let firstComplete = try await client.contributionDiff(fixture.contributionRequest())
        let equalComplete = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.write("tracked-a.txt", contents: "base a\nworktree one\n")

        // Act
        let firstProportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: equalComplete.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let equalProportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: firstProportional.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let equalFallback = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: equalProportional.successorSeed,
                    changedPaths: ["tracked-a.txt", "tracked-a.txt"]
                )))
        try fixture.write("tracked-a.txt", contents: "base a\nworktree two\n")
        let afterFallback = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: equalFallback.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))

        // Assert
        #expect(firstComplete.snapshot == equalComplete.snapshot)
        #expect(firstProportional.calculationDisposition == .proportional)
        #expect(equalProportional.calculationDisposition == .proportional)
        #expect(firstProportional.snapshot == equalProportional.snapshot)
        #expect(equalFallback.calculationDisposition == .proportionalFallback)
        #expect(equalFallback.snapshot == equalProportional.snapshot)
        #expect(afterFallback.calculationDisposition == .proportional)
    }

    @Test("proportional contribution inserts one newly modified tracked row with full parity")
    func proportionalContributionInsertsNewTrackedModification() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.write("tracked-a.txt", contents: "base a\nworktree a\n")

        // Act
        let proportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let complete = try await client.contributionDiff(fixture.contributionRequest())

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(proportional.calculationReason == .proportionalAccepted)
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
        #expect(proportional.snapshot.diff.files.map(\.path) == ["tracked-a.txt"])
    }

    @Test("proportional contribution replaces an existing modified row with full parity")
    func proportionalContributionReplacesExistingModifiedRow() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(committedPaths: ["tracked-a.txt"])
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        let predecessorFileID = try #require(predecessor.snapshot.diff.files.first?.fileId)
        try fixture.write("tracked-a.txt", contents: "base a\ncommitted a\nworktree a\n")

        // Act
        let proportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let complete = try await client.contributionDiff(fixture.contributionRequest())

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
        #expect(proportional.snapshot.diff.files.first?.fileId != predecessorFileID)
    }

    @Test("proportional direct comparison replaces one row with full parity")
    func proportionalDirectComparisonReplacesExistingModifiedRow() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(committedPaths: ["tracked-a.txt"])
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.directReviewComparison(fixture.directRequest())
        try fixture.write("tracked-a.txt", contents: "base a\ncommitted a\nworktree a\n")

        // Act
        let proportional = try await client.directReviewComparison(
            fixture.directRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let complete = try await client.directReviewComparison(fixture.directRequest())
        let equalFallback = try await client.directReviewComparison(
            fixture.directRequest(
                refreshInput: .proportional(
                    seed: proportional.successorSeed,
                    changedPaths: ["tracked-a.txt", "tracked-a.txt"]
                )))
        try fixture.write("tracked-a.txt", contents: "base a\ncommitted a\nworktree a again\n")
        let afterFallback = try await client.directReviewComparison(
            fixture.directRequest(
                refreshInput: .proportional(
                    seed: equalFallback.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(proportional.calculationReason == .proportionalAccepted)
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
        #expect(equalFallback.calculationDisposition == .proportionalFallback)
        #expect(equalFallback.snapshot == proportional.snapshot)
        #expect(afterFallback.calculationDisposition == .proportional)
    }

    @Test("multiple proportional paths produce the complete sorted snapshot")
    func multipleProportionalPathsPreserveOrdering() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(committedPaths: ["tracked-b.txt"])
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.write("tracked-b.txt", contents: "base b\ncommitted b\nworktree b\n")
        try fixture.write("tracked-a.txt", contents: "base a\nworktree a\n")

        // Act
        let proportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-b.txt", "tracked-a.txt"]
                )))
        let complete = try await client.contributionDiff(fixture.contributionRequest())

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(proportional.snapshot.diff.files.map(\.path) == ["tracked-a.txt", "tracked-b.txt"])
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
    }

    @Test("a missing scoped row selects complete fallback without removing predecessor truth")
    func missingScopedRowSelectsCompleteFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(committedPaths: ["tracked-a.txt"])
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.write("tracked-a.txt", contents: "base a\n")

        // Act
        let refreshed = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let complete = try await client.contributionDiff(fixture.contributionRequest())

        // Assert
        #expect(refreshed.calculationDisposition == .proportionalFallback)
        #expect(refreshed.calculationReason == .missingScopedRow)
        #expect(try encoded(refreshed.snapshot) == encoded(complete.snapshot))
    }

    @Test("case and Unicode spelling mismatches conservatively select complete fallback")
    func pathSpellingMismatchesSelectCompleteFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(unicodePath: "caf\u{00E9}.txt")
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.write("tracked-a.txt", contents: "base a\nworktree a\n")
        try fixture.write("caf\u{00E9}.txt", contents: "base unicode\nworktree unicode\n")
        let misspelledPaths = ["TRACKED-A.txt", "cafe\u{0301}.txt"]
        let complete = try await client.contributionDiff(fixture.contributionRequest())

        // Act
        var results: [GitContributionDiffResult] = []
        for path in misspelledPaths {
            results.append(
                try await client.contributionDiff(
                    fixture.contributionRequest(
                        refreshInput: .proportional(
                            seed: predecessor.successorSeed,
                            changedPaths: [path]
                        ))))
        }

        // Assert
        #expect(results.allSatisfy { $0.calculationDisposition == .proportionalFallback })
        #expect(try results.allSatisfy { try encoded($0.snapshot) == encoded(complete.snapshot) })
        #expect(
            results.allSatisfy {
                [.invalidPath, .missingScopedRow, .outOfScopeScopedRow, .ineligibleScopedRow]
                    .contains($0.calculationReason)
            })
    }

    @Test("nested attributes and ignore files pre-classify as structural fallback")
    func nestedGitControlFilesSelectStructuralFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make(controlPaths: ["nested/.gitattributes", "nested/.gitignore"])
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())

        // Act
        var results: [GitContributionDiffResult] = []
        for path in ["nested/.gitattributes", "nested/.gitignore"] {
            try fixture.write(path, contents: "*.txt -text\n")
            results.append(
                try await client.contributionDiff(
                    fixture.contributionRequest(
                        refreshInput: .proportional(
                            seed: predecessor.successorSeed,
                            changedPaths: [path]
                        ))))
        }

        // Assert
        #expect(results.allSatisfy { $0.calculationDisposition == .proportionalFallback })
        #expect(results.allSatisfy { $0.calculationReason == .structuralGitControlPath })
    }

    @Test("literal scoped comparison preserves filters binary mode and line totals")
    func proportionalCalculationPreservesGitMetadata() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-refresh-metadata")
        defer { fixture.remove() }
        try fixture.write(".gitattributes", contents: "*.crlf text eol=crlf\n")
        try fixture.write("filtered.crlf", contents: "base\n")
        try Data([0, 1, 2, 3, 255]).write(to: fixture.repositoryPath.appending(path: "binary.bin"))
        try fixture.write("script.sh", contents: "#!/bin/sh\necho base\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed metadata paths")
        try fixture.git.run("branch", "target", "HEAD")
        try fixture.git.run("checkout", "-b", "feature")
        let client = LibGit2AgentStudioGitLocalClient()
        let request = GitContributionDiffRequest(
            repositoryPath: fixture.repositoryPath,
            target: .named("refs/heads/target")
        )
        let predecessor = try await client.contributionDiff(request)
        try fixture.write("filtered.crlf", contents: "base\nfiltered\n")
        try Data([255, 3, 2, 1, 0]).write(to: fixture.repositoryPath.appending(path: "binary.bin"))
        try fixture.write("script.sh", contents: "#!/bin/sh\necho changed\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.repositoryPath.appending(path: "script.sh").path
        )

        // Act
        let proportional = try await client.contributionDiff(
            GitContributionDiffRequest(
                repositoryPath: fixture.repositoryPath,
                target: .named("refs/heads/target"),
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["script.sh", "binary.bin", "filtered.crlf"]
                )
            ))
        let complete = try await client.contributionDiff(request)
        let files = Dictionary(uniqueKeysWithValues: proportional.snapshot.diff.files.map { ($0.path, $0) })
        let filteredHash = try fixture.git.run(
            "hash-object", "--path=filtered.crlf", "filtered.crlf"
        ).trimmed

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
        #expect(files["filtered.crlf"]?.newContentHash == filteredHash)
        #expect(files["filtered.crlf"]?.additions == 1)
        #expect(files["binary.bin"]?.isBinary == true)
        #expect(files["script.sh"]?.newMode == 0o100755)
    }

    @Test("added deleted renamed and type-changed paths select complete fallback")
    func structuralPathChangesSelectCompleteFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())

        // Act
        try fixture.write("untracked.txt", contents: "untracked\n")
        let added = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(seed: predecessor.successorSeed, changedPaths: ["untracked.txt"])))

        try fixture.git.run("mv", "tracked-a.txt", "renamed-a.txt")
        let renamed = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt", "renamed-a.txt"]
                )))

        try FileManager.default.removeItem(at: fixture.repositoryPath.appending(path: "tracked-b.txt"))
        let deleted = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(seed: predecessor.successorSeed, changedPaths: ["tracked-b.txt"])))

        try FileManager.default.removeItem(at: fixture.repositoryPath.appending(path: "type-changed.txt"))
        try FileManager.default.createSymbolicLink(
            at: fixture.repositoryPath.appending(path: "type-changed.txt"),
            withDestinationURL: fixture.repositoryPath.appending(path: "README.md")
        )
        let typeChanged = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(seed: predecessor.successorSeed, changedPaths: ["type-changed.txt"])))

        // Assert
        #expect(
            [added, renamed, deleted, typeChanged].allSatisfy {
                $0.calculationDisposition == .proportionalFallback
            })
        #expect(added.calculationReason == .ineligibleScopedRow)
        #expect(renamed.calculationReason == .invalidPath)
        #expect(deleted.calculationReason == .invalidPath)
        #expect(typeChanged.calculationReason == .invalidPath)
    }

    @Test("staged deletion plus same-path recreation retains direct worktree semantics")
    func proportionalStagedDeleteRecreationRetainsDirectSemantics() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        try fixture.git.run("rm", "tracked-a.txt")
        try fixture.write("tracked-a.txt", contents: "recreated content\n")

        // Act
        let proportional = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let complete = try await client.contributionDiff(fixture.contributionRequest())
        let recreated = try #require(proportional.snapshot.diff.files.first { $0.path == "tracked-a.txt" })

        // Assert
        #expect(proportional.calculationDisposition == .proportional)
        #expect(recreated.changeKind == .modified)
        #expect(recreated.newContentHash != nil)
        #expect(try encoded(proportional.snapshot) == encoded(complete.snapshot))
    }

    @Test("seed identity mismatch and identity movement return exact complete fallbacks")
    func identityChangesReturnCompleteFallback() async throws {
        // Arrange
        let firstFixture = try IncrementalReviewFixture.make()
        let secondFixture = try IncrementalReviewFixture.make()
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let client = LibGit2AgentStudioGitLocalClient()
        let foreignSeed = try await client.contributionDiff(firstFixture.contributionRequest()).successorSeed
        try secondFixture.write("tracked-a.txt", contents: "base a\nworktree a\n")

        // Act
        let mismatch = try await client.contributionDiff(
            secondFixture.contributionRequest(
                refreshInput: .proportional(seed: foreignSeed, changedPaths: ["tracked-a.txt"])))

        let predecessor = try await client.contributionDiff(secondFixture.contributionRequest())
        let originalHeadOID = try secondFixture.git.run("rev-parse", "HEAD").trimmed
        let treeOID = try secondFixture.git.run("rev-parse", "HEAD^{tree}").trimmed
        let advancedHeadOID = try secondFixture.git.run(
            "commit-tree", treeOID, "-p", originalHeadOID, "-m", "advance during scoped calculation"
        ).trimmed
        let repositoryPath = secondFixture.repositoryPath
        let movingReader = LibGit2ContributionDiffReader {
            do {
                try GitProcess(repositoryPath: repositoryPath).run("update-ref", "HEAD", advancedHeadOID)
            } catch {
                Issue.record("failed to advance fixture HEAD: \(error)")
            }
        }
        let movement = try movingReader.contributionDiff(
            secondFixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt"]
                )))
        let completeAfterMovement = try await client.contributionDiff(secondFixture.contributionRequest())

        // Assert
        #expect(mismatch.calculationDisposition == .proportionalFallback)
        #expect(mismatch.calculationReason == .seedIdentityMismatch)
        #expect(movement.calculationDisposition == .proportionalFallback)
        #expect(movement.calculationReason == .identityMoved)
        #expect(try encoded(movement.snapshot) == encoded(completeAfterMovement.snapshot))
    }

    @Test("capacity and duplicate changed paths select bounded complete fallback reasons")
    func invalidChangedPathCollectionsSelectCompleteFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())
        let overCapacityPaths = (0...LibGit2ReviewRefreshCalculator.maximumProportionalChangedPathCount)
            .map { "path-\($0).txt" }

        // Act
        let duplicate = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: ["tracked-a.txt", "tracked-a.txt"]
                )))
        let overCapacity = try await client.contributionDiff(
            fixture.contributionRequest(
                refreshInput: .proportional(
                    seed: predecessor.successorSeed,
                    changedPaths: overCapacityPaths
                )))

        // Assert
        #expect(duplicate.calculationReason == .invalidPath)
        #expect(overCapacity.calculationReason == .capacityRejected)
        #expect(
            [duplicate, overCapacity].allSatisfy {
                $0.calculationDisposition == .proportionalFallback
            })
    }

    @Test("root directory and escaping paths select invalid-path complete fallback")
    func invalidFileKindsAndLocationsSelectCompleteFallback() async throws {
        // Arrange
        let fixture = try IncrementalReviewFixture.make()
        defer { fixture.remove() }
        try fixture.write("nested/member.txt", contents: "nested\n")
        let client = LibGit2AgentStudioGitLocalClient()
        let predecessor = try await client.contributionDiff(fixture.contributionRequest())

        // Act
        var results: [GitContributionDiffResult] = []
        for path in [".", "nested", "../outside.txt", "/absolute.txt"] {
            results.append(
                try await client.contributionDiff(
                    fixture.contributionRequest(
                        refreshInput: .proportional(
                            seed: predecessor.successorSeed,
                            changedPaths: [path]
                        ))))
        }

        // Assert
        #expect(results.allSatisfy { $0.calculationDisposition == .proportionalFallback })
        #expect(results.allSatisfy { $0.calculationReason == .invalidPath })
    }

}

private struct IncrementalReviewFixture {
    let fixture: GitFixtureRepository
    let targetReference: String

    var repositoryPath: URL { fixture.repositoryPath }
    var git: GitProcess { fixture.git }

    static func make(
        committedPaths: [String] = [],
        unicodePath: String? = nil,
        controlPaths: [String] = []
    ) throws -> Self {
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-review-refresh")
        try fixture.write("tracked-a.txt", contents: "base a\n")
        try fixture.write("tracked-b.txt", contents: "base b\n")
        try fixture.write("type-changed.txt", contents: "base type\n")
        if let unicodePath {
            try fixture.write(unicodePath, contents: "base unicode\n")
        }
        for path in controlPaths {
            try fixture.write(path, contents: "# initial control\n")
        }
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-m", "seed review refresh paths")
        try fixture.git.run("branch", "target", "HEAD")
        try fixture.git.run("checkout", "-b", "feature")

        for path in committedPaths {
            let baseName = path.replacingOccurrences(of: "tracked-", with: "").replacingOccurrences(
                of: ".txt", with: "")
            try fixture.write(path, contents: "base \(baseName)\ncommitted \(baseName)\n")
        }
        if !committedPaths.isEmpty {
            try fixture.git.run("add", ".")
            try fixture.git.run("commit", "-m", "commit review refresh changes")
        }
        return Self(fixture: fixture, targetReference: "refs/heads/target")
    }

    func contributionRequest(refreshInput: GitReviewRefreshInput = .complete) -> GitContributionDiffRequest {
        GitContributionDiffRequest(
            repositoryPath: repositoryPath,
            target: .named(targetReference),
            refreshInput: refreshInput
        )
    }

    func directRequest(refreshInput: GitReviewRefreshInput = .complete) -> GitDirectReviewComparisonRequest {
        GitDirectReviewComparisonRequest(
            repositoryPath: repositoryPath,
            target: .named(targetReference),
            refreshInput: refreshInput
        )
    }

    func write(_ relativePath: String, contents: String) throws {
        try fixture.write(relativePath, contents: contents)
    }

    func remove() {
        fixture.remove()
    }
}

private func encoded(_ snapshot: GitContributionDiffSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
}

private func encoded(_ snapshot: GitDirectReviewComparisonSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
}
