import AgentStudioGit
import Foundation
import Testing

@Suite("Git branch integration assessment integration")
struct GitBranchIntegrationIntegrationTests {
    @Test("reports ancestor proof and preserves input order when a branch is missing")
    func reportsAncestorProofAndPreservesInputOrderWhenBranchIsMissing() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-branch-integration")
        defer { fixture.remove() }
        let branchCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "feature", branchCommit)
        try fixture.write("target.txt", contents: "target\n")
        try fixture.git.run("add", "target.txt")
        try fixture.git.run("commit", "-m", "advance integration target")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let report = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature", "missing"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(report.targetCommit == targetCommit)
        #expect(report.assessments.map(\.branchName) == ["feature", "missing"])
        #expect(report.assessments[0].branchCommit == branchCommit)
        #expect(report.assessments[0].grade == .integrated(.ancestor))
        #expect(report.assessments[1].branchCommit == nil)
        #expect(report.assessments[1].grade == .unknown(.branchNotFound))
    }

    @Test("complete history prefers ancestry over same content, while shallow history keeps direct proof")
    func completeHistoryPrefersAncestorOverSameContent() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-proof-order")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        try fixture.git.run("branch", "ancestor", baseCommit)
        try fixture.git.run("checkout", "-b", "sibling", baseCommit)
        try fixture.git.run("commit", "--allow-empty", "-m", "sibling empty commit")
        try fixture.git.run("checkout", mainBranch)
        try fixture.git.run("commit", "--allow-empty", "-m", "advance target without changing tree")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let request = GitBranchIntegrationRequest(
            repositoryPath: fixture.repositoryPath,
            branchNames: ["ancestor", "sibling"],
            targetCommit: targetCommit,
            squashSearchCommitLimit: 500
        )
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let completeHistory = try await client.assessBranchIntegration(request)
        try Data("\(baseCommit)\n".utf8).write(to: fixture.repositoryPath.appending(path: ".git/shallow"))
        let shallowHistory = try await client.assessBranchIntegration(request)

        // Assert
        #expect(completeHistory.assessments.map(\.grade) == [.integrated(.ancestor), .integrated(.sameContent)])
        #expect(shallowHistory.assessments.map(\.grade) == [.integrated(.sameContent), .integrated(.sameContent)])
    }

    @Test("classifies direct, content, empty-delta, and remaining-contribution proofs")
    func classifiesDirectContentAndDeltaProofs() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-grades")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed

        try fixture.git.run("checkout", "-b", "empty-delta", baseCommit)
        try fixture.write("README.md", contents: "temporary\n")
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "change then restore")
        try fixture.write("README.md", contents: "hello\n")
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "restore base tree")

        try fixture.git.run("checkout", mainBranch)
        try fixture.write("target.txt", contents: "target\n")
        try fixture.git.run("add", "target.txt")
        try fixture.git.run("commit", "-m", "advance target")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "same-commit", targetCommit)

        try fixture.git.run("checkout", "-b", "same-content", targetCommit)
        try fixture.git.run("commit", "--allow-empty", "-m", "same tree, new commit")
        try fixture.git.run("checkout", mainBranch)

        try fixture.git.run("checkout", "-b", "remaining", baseCommit)
        try fixture.write("remaining.txt", contents: "remaining\n")
        try fixture.git.run("add", "remaining.txt")
        try fixture.git.run("commit", "-m", "remaining change")
        try fixture.git.run("checkout", mainBranch)

        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let report = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["same-commit", "same-content", "empty-delta", "remaining"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(
            report.assessments.map(\.grade) == [
                .integrated(.sameCommit),
                .integrated(.sameContent),
                .integrated(.emptyDelta),
                .hasRemainingContribution,
            ])
    }

    @Test("reports unrelated branch history and returns an empty report without opening a repository")
    func reportsUnrelatedHistoryAndDoesNotOpenRepositoryForEmptyInput() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-unrelated")
        defer { fixture.remove() }
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "--orphan", "unrelated")
        try fixture.git.run("rm", "-rf", ".")
        try fixture.write("unrelated.txt", contents: "unrelated\n")
        try fixture.git.run("add", "unrelated.txt")
        try fixture.git.run("commit", "-m", "unrelated root")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let unrelated = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["unrelated"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )
        let empty = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: URL(fileURLWithPath: "/missing/branch-integration-repository"),
                branchNames: [],
                targetCommit: "unvalidated-with-empty-input",
                squashSearchCommitLimit: 0
            )
        )

        // Assert
        #expect(unrelated.assessments.first?.grade == .unknown(.noMergeBase))
        #expect(empty.targetCommit == "unvalidated-with-empty-input")
        #expect(empty.assessments.isEmpty)
    }

    @Test("finds exact squash deltas after later edits to the same and other target paths")
    func findsExactSquashAfterLaterTargetEdits() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-squash")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        try fixture.git.run("checkout", "-b", "feature", baseCommit)
        try fixture.write("feature.txt", contents: "feature payload\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "feature contribution")
        try fixture.git.run("checkout", mainBranch)

        try fixture.write("feature.txt", contents: "feature payload\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "squash feature contribution")
        let squashCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("other.txt", contents: "later other path\n")
        try fixture.git.run("add", "other.txt")
        try fixture.git.run("commit", "-m", "edit another path after landing")
        try fixture.write("feature.txt", contents: "later feature path edit\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "edit landed path after landing")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(report.assessments.first?.grade == .integrated(.squash(commit: squashCommit)))
    }

    @Test("a revert after squash does not undo integration and a later branch commit remains outstanding")
    func preservesIntegratedAtSomePointAcrossRevertAndLaterBranchCommit() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-revert")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        try fixture.git.run("checkout", "-b", "feature", baseCommit)
        try fixture.write("feature.txt", contents: "feature payload\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "feature contribution")
        let featureCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", mainBranch)

        try fixture.write("feature.txt", contents: "feature payload\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "squash feature contribution")
        let squashCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("revert", "--no-edit", squashCommit)
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed

        try fixture.git.run("checkout", "-b", "feature-after", featureCommit)
        try fixture.write("later.txt", contents: "new branch contribution\n")
        try fixture.git.run("add", "later.txt")
        try fixture.git.run("commit", "-m", "new branch commit after landing")
        try fixture.git.run("checkout", mainBranch)

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature", "feature-after"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(report.assessments[0].grade == .integrated(.squash(commit: squashCommit)))
        #expect(report.assessments[1].grade == .hasRemainingContribution)
    }

    @Test("honors squash candidate positions one, 499, 500, and 501 and limit zero")
    func honorsSquashCandidateBoundaries() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-bounds")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        let positions = [1, 499, 500, 501]

        for position in positions {
            let branchName = "feature-\(position)"
            try fixture.git.run("checkout", "-b", branchName, baseCommit)
            try fixture.write("candidate-\(position).txt", contents: "candidate \(position)\n")
            try fixture.git.run("add", "candidate-\(position).txt")
            try fixture.git.run("commit", "-m", "branch candidate \(position)")
            try fixture.git.run("checkout", mainBranch)
        }

        var targetCommitByPosition: [Int: String] = [:]
        for position in [501, 500, 499] {
            try fixture.write("candidate-\(position).txt", contents: "candidate \(position)\n")
            try fixture.git.run("add", "candidate-\(position).txt")
            try fixture.git.run("commit", "-m", "target candidate \(position)")
            targetCommitByPosition[position] = try fixture.git.run("rev-parse", "HEAD").trimmed
        }
        for fillerIndex in 1...497 {
            try fixture.write("filler.txt", contents: "filler \(fillerIndex)\n")
            try fixture.git.run("add", "filler.txt")
            try fixture.git.run("commit", "-m", "first-parent filler \(fillerIndex)")
        }
        try fixture.write("candidate-1.txt", contents: "candidate 1\n")
        try fixture.git.run("add", "candidate-1.txt")
        try fixture.git.run("commit", "-m", "target candidate 1")
        targetCommitByPosition[1] = try fixture.git.run("rev-parse", "HEAD").trimmed
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let branchNames = positions.map { "feature-\($0)" }
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let capped = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: branchNames,
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )
        let disabled = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature-1"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 0
            )
        )
        let extended = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature-501"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 501
            )
        )

        // Assert
        #expect(capped.assessments[0].grade == .integrated(.squash(commit: try #require(targetCommitByPosition[1]))))
        #expect(capped.assessments[1].grade == .integrated(.squash(commit: try #require(targetCommitByPosition[499]))))
        #expect(capped.assessments[2].grade == .integrated(.squash(commit: try #require(targetCommitByPosition[500]))))
        #expect(capped.assessments[3].grade == .unknown(.historyLimitReached))
        #expect(disabled.assessments.first?.grade == .unknown(.historyLimitReached))
        #expect(
            extended.assessments.first?.grade == .integrated(.squash(commit: try #require(targetCommitByPosition[501])))
        )
    }

    @Test("a broken branch does not hide other rows in the same batch")
    func keepsUnreadableAndMissingObjectBranchesAsRows() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-batch-errors")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "ancestor", baseCommit)
        try fixture.write("target.txt", contents: "target\n")
        try fixture.git.run("add", "target.txt")
        try fixture.git.run("commit", "-m", "advance target")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed

        let branchDirectory = fixture.repositoryPath.appending(path: ".git/refs/heads")
        let unreadableReference = branchDirectory.appending(path: "unreadable")
        try Data("ref: refs/heads/missing-symbolic-target\n".utf8).write(to: unreadableReference)
        let missingObjectOID = String(repeating: "f", count: 40)
        let missingObjectReference = branchDirectory.appending(path: "missing-object")
        try Data("\(missingObjectOID)\n".utf8).write(to: missingObjectReference)

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["ancestor", "unreadable", "missing-object"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(report.assessments.map(\.branchName) == ["ancestor", "unreadable", "missing-object"])
        #expect(report.assessments[0].grade == .integrated(.ancestor))
        #expect(report.assessments[1].branchCommit == nil)
        #expect(report.assessments[1].grade == .unknown(.readFailed))
        #expect(report.assessments[2].branchCommit == missingObjectOID)
        #expect(report.assessments[2].grade == .unknown(.missingObjects))
    }

    @Test("reports multiple best merge bases as an unknown instead of choosing one")
    func reportsMultipleBestMergeBases() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-multiple-bases"
        )
        defer { treeRepository.fixture.remove() }

        let aBlob = try treeRepository.writeBlob(Data("A\n".utf8))
        let bBlob = try treeRepository.writeBlob(Data("B\n".utf8))
        let targetBlob = try treeRepository.writeBlob(Data("target\n".utf8))
        let branchBlob = try treeRepository.writeBlob(Data("branch\n".utf8))
        let baseEntries = [
            GitBranchIntegrationTreeEntry(
                mode: "100644", objectType: "blob", objectID: treeRepository.readmeBlob, path: "README.md"
            )
        ]
        let aTree = try treeRepository.writeTree(
            entries: baseEntries + [
                GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: aBlob, path: "a.txt")
            ]
        )
        let bTree = try treeRepository.writeTree(
            entries: baseEntries + [
                GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: bBlob, path: "b.txt")
            ]
        )
        let aCommit = try treeRepository.writeCommit(
            tree: aTree,
            parent: treeRepository.baseCommit,
            message: "first side commit"
        )
        let bCommit = try treeRepository.writeCommit(
            tree: bTree,
            parent: treeRepository.baseCommit,
            message: "second side commit"
        )
        let commonMergeEntries =
            baseEntries + [
                GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: aBlob, path: "a.txt"),
                GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: bBlob, path: "b.txt"),
            ]
        let firstMergeTree = try treeRepository.writeTree(entries: commonMergeEntries)
        let firstMerge = try treeRepository.fixture.git.run(
            ["commit-tree", firstMergeTree, "-p", aCommit, "-p", bCommit, "-m", "first criss-cross merge"]
        ).trimmed
        let reverseMergeEntries =
            commonMergeEntries + [
                GitBranchIntegrationTreeEntry(
                    mode: "100644", objectType: "blob", objectID: branchBlob, path: "branch-side.txt")
            ]
        let reverseMergeTree = try treeRepository.writeTree(entries: reverseMergeEntries)
        let reverseMerge = try treeRepository.fixture.git.run(
            ["commit-tree", reverseMergeTree, "-p", bCommit, "-p", aCommit, "-m", "reverse criss-cross merge"]
        ).trimmed

        let targetTree = try treeRepository.writeTree(
            entries: commonMergeEntries + [
                GitBranchIntegrationTreeEntry(
                    mode: "100644", objectType: "blob", objectID: targetBlob, path: "target-side.txt"
                )
            ]
        )
        let targetCommit = try treeRepository.writeCommit(
            tree: targetTree,
            parent: firstMerge,
            message: "target after first merge"
        )
        let branchTree = try treeRepository.writeTree(
            entries: reverseMergeEntries + [
                GitBranchIntegrationTreeEntry(
                    mode: "100644", objectType: "blob", objectID: aBlob, path: "branch-after.txt"
                )
            ]
        )
        let branchCommit = try treeRepository.writeCommit(
            tree: branchTree,
            parent: reverseMerge,
            message: "branch after reverse merge"
        )
        try treeRepository.updateBranch("criss-cross", to: branchCommit)
        let oracleBases = try treeRepository.fixture.git.run("merge-base", "--all", targetCommit, branchCommit)
            .split(whereSeparator: \.isNewline)

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: treeRepository.fixture.repositoryPath,
                branchNames: ["criss-cross"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(Set(oracleBases.map(String.init)) == Set<String>([aCommit, bCommit]))
        #expect(report.assessments.first?.grade == .unknown(.multipleMergeBases))
    }

    @Test("rejects squash limits outside the public range before opening a repository")
    func rejectsOutOfRangeSquashLimits() async {
        // Arrange
        let missingRepository = URL(fileURLWithPath: "/missing/branch-integration-repository")

        // Act / Assert
        for limit in [-1, 10_001] {
            await #expect(
                throws: GitDataPlaneError.unsupported(
                    message: "branch integration squash search limit must be from 0 through 10000")
            ) {
                try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
                    GitBranchIntegrationRequest(
                        repositoryPath: missingRepository,
                        branchNames: ["branch"],
                        targetCommit: "not-an-oid",
                        squashSearchCommitLimit: limit
                    )
                )
            }
        }
    }

    @Test("rejects an invalid target commit before producing branch rows")
    func rejectsInvalidTargetCommit() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-invalid-target")
        defer { fixture.remove() }

        // Act / Assert
        await #expect(throws: GitDataPlaneError.revisionUnavailable(target: .named("not-an-oid"))) {
            try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
                GitBranchIntegrationRequest(
                    repositoryPath: fixture.repositoryPath,
                    branchNames: ["main"],
                    targetCommit: "not-an-oid",
                    squashSearchCommitLimit: 500
                )
            )
        }
    }
}
