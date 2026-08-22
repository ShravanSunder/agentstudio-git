import AgentStudioGit
import Foundation
import Testing

@Suite("Git commit range count integration")
struct GitCommitRangeCountIntegrationTests {
    @Test("counts descendant commits exactly below the cap and stops at the cap")
    func countsDescendantCommitsWithBoundedResult() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-commit-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        for commitIndex in 1...3 {
            try fixture.write("commit-\(commitIndex).txt", contents: "\(commitIndex)\n")
            try fixture.git.run("add", "commit-\(commitIndex).txt")
            try fixture.git.run("commit", "-m", "commit \(commitIndex)")
        }
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let exact = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 10,
                maximumTraversalCount: 64
            )
        )
        let capped = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 2,
                maximumTraversalCount: 64
            )
        )
        let same = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(baseOID),
                maximumCount: 10,
                maximumTraversalCount: 64
            )
        )

        // Assert
        #expect(exact == .exact(3))
        #expect(capped == .atLeastLimit(2))
        #expect(same == .exact(0))
    }

    @Test("reports unrelated history instead of inventing a commit count")
    func reportsUnrelatedHistory() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-unrelated-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "--orphan", "unrelated")
        try fixture.git.run("rm", "-rf", ".")
        try fixture.write("unrelated.txt", contents: "unrelated\n")
        try fixture.git.run("add", "unrelated.txt")
        try fixture.git.run("commit", "-m", "unrelated root")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 10,
                maximumTraversalCount: 64
            )
        )

        // Assert
        #expect(result == .unrelated)
    }

    @Test("stops at the cap before classifying a long unrelated history")
    func stopsAtCapForLongUnrelatedHistory() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-capped-unrelated-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "--orphan", "unrelated")
        try fixture.git.run("rm", "-rf", ".")
        for commitIndex in 1...3 {
            try fixture.write("unrelated-\(commitIndex).txt", contents: "\(commitIndex)\n")
            try fixture.git.run("add", "unrelated-\(commitIndex).txt")
            try fixture.git.run("commit", "-m", "unrelated \(commitIndex)")
        }
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 2,
                maximumTraversalCount: 64
            )
        )

        // Assert
        #expect(result == .atLeastLimit(2))
    }

    @Test("returns a typed indeterminate result when ancestry exceeds the traversal budget")
    func returnsTraversalLimitForDeepUnrelatedHistory() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-budgeted-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("checkout", "--orphan", "deep-unrelated")
        try fixture.git.run("rm", "-rf", ".")
        for commitIndex in 1...6 {
            try fixture.write("history.txt", contents: "\(commitIndex)\n")
            try fixture.git.run("add", "history.txt")
            try fixture.git.run("commit", "-m", "unrelated \(commitIndex)")
        }
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 10,
                maximumTraversalCount: 2
            )
        )

        // Assert
        #expect(result == .traversalLimitReached(2))
    }

    @Test("physical traversal budget wins before the promotion count on a long descendant range")
    func traversalBudgetBoundsLongDescendantRange() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-budgeted-descendant-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        for commitIndex in 1...40 {
            try fixture.write("history.txt", contents: "\(commitIndex)\n")
            try fixture.git.run("add", "history.txt")
            try fixture.git.run("commit", "-m", "descendant \(commitIndex)")
        }
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 10,
                maximumTraversalCount: 4
            )
        )

        // Assert
        #expect(result == .traversalLimitReached(4))
    }

    @Test("counts both sides of a small merged range within the shared traversal budget")
    func countsSmallMergedRange() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-merged-commit-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        try fixture.git.run("checkout", "-b", "side")
        try fixture.write("side.txt", contents: "side\n")
        try fixture.git.run("add", "side.txt")
        try fixture.git.run("commit", "-m", "side commit")
        try fixture.git.run("checkout", mainBranch)
        try fixture.write("main.txt", contents: "main\n")
        try fixture.git.run("add", "main.txt")
        try fixture.git.run("commit", "-m", "main commit")
        try fixture.git.run("merge", "--no-ff", "side", "-m", "merge side")
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 10,
                maximumTraversalCount: 64
            )
        )

        // Assert
        #expect(result == .exact(3))
    }

    @Test("deduplicates shared ancestry across an octopus merge")
    func countsOctopusMergedRange() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-octopus-commit-range")
        defer { fixture.remove() }
        let baseOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        let sideBranches = (1...8).map { "side-\($0)" }
        for (branchIndex, branchName) in sideBranches.enumerated() {
            try fixture.git.run("checkout", "-b", branchName, baseOID)
            try fixture.write("side-\(branchIndex + 1).txt", contents: "side \(branchIndex + 1)\n")
            try fixture.git.run("add", "side-\(branchIndex + 1).txt")
            try fixture.git.run("commit", "-m", "side \(branchIndex + 1)")
        }
        try fixture.git.run("checkout", mainBranch)
        try fixture.git.run(["merge", "--no-ff"] + sideBranches + ["-m", "merge all sides"])
        let candidateOID = try fixture.git.run("rev-parse", "HEAD").trimmed
        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let result = try await client.countCommitRange(
            GitCommitRangeCountRequest(
                repositoryPath: fixture.repositoryPath,
                base: .named(baseOID),
                candidate: .named(candidateOID),
                maximumCount: 20,
                maximumTraversalCount: 64
            )
        )

        // Assert
        #expect(result == .exact(9))
    }

    @Test("rejects a nonpositive cap before opening the repository")
    func rejectsNonpositiveMaximumCount() async {
        // Arrange
        let missingRepository = URL(fileURLWithPath: "/path/that/does/not/exist")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.unsupported(message: "commit range maximumCount must be positive")
        ) {
            _ = try await client.countCommitRange(
                GitCommitRangeCountRequest(
                    repositoryPath: missingRepository,
                    base: .named("base"),
                    candidate: .named("candidate"),
                    maximumCount: 0,
                    maximumTraversalCount: 10
                )
            )
        }
    }

    @Test("rejects a nonpositive traversal budget before opening the repository")
    func rejectsNonpositiveTraversalBudget() async {
        // Arrange
        let missingRepository = URL(fileURLWithPath: "/path/that/does/not/exist")
        let client = LibGit2AgentStudioGitLocalClient()

        // Act / Assert
        await #expect(
            throws: GitDataPlaneError.unsupported(
                message: "commit range maximumTraversalCount must be positive"
            )
        ) {
            _ = try await client.countCommitRange(
                GitCommitRangeCountRequest(
                    repositoryPath: missingRepository,
                    base: .named("base"),
                    candidate: .named("candidate"),
                    maximumCount: 10,
                    maximumTraversalCount: 0
                )
            )
        }
    }
}
