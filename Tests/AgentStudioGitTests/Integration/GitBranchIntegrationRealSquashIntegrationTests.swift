import AgentStudioGit
import Foundation
import Testing

@Suite("Git branch integration real squash fixtures")
struct GitBranchIntegrationRealSquashIntegrationTests {
    @Test("the offline real-commit pack matches its manifest and proves both squash cases")
    func realSquashPackIsCompleteAndAssessed() async throws {
        // Arrange
        let fixture = try GitBranchIntegrationRealSquashFixture.load()
        let repository = try GitFixtureRepository.makeRepository(
            prefix: "agentstudio-git-integration-real-squash-pack"
        )
        defer { repository.remove() }
        let indexPath = try fixture.importedIndex(in: repository)

        // Act
        let verifiedObjects = try fixture.verifiedObjects(in: repository, indexPath: indexPath)

        // Assert
        #expect(fixture.manifest.formatVersion == 1)
        #expect(fixture.manifest.sourceRepository == "ShravanSunder/agentstudio")
        #expect(fixture.manifest.sourceHead == "07006b402f1d48525c4a25ef5fffea163bdd4ec6")
        #expect(fixture.manifest.provenance.contains("Read-only Git object export"))
        #expect(fixture.pack.count < 5_000_000)
        #expect(fixture.objects == verifiedObjects)
        #expect(fixture.objects.allSatisfy { $0.hasSuffix(" commit") || $0.hasSuffix(" tree") })
        #expect(fixture.manifest.cases.count == 2)

        for squashCase in fixture.manifest.cases {
            try repository.git.run(
                "update-ref", "refs/heads/fixture/pr-\(squashCase.pullRequest)", squashCase.branchCommit)
            #expect(fixture.objects.contains("\(squashCase.branchCommit) commit"))
            #expect(fixture.objects.contains("\(squashCase.squashCommit) commit"))
            #expect(fixture.objects.contains("\(squashCase.mergeBaseCommit) commit"))
            #expect(fixture.objects.contains("\(squashCase.targetCommit) commit"))
            #expect(
                try repository.git.run("merge-base", squashCase.branchCommit, squashCase.targetCommit).trimmed
                    == squashCase.mergeBaseCommit
            )

            let branchDelta = try repository.git.run(
                "diff-tree",
                "--raw",
                "-r",
                "--no-renames",
                squashCase.mergeBaseCommit,
                squashCase.branchCommit
            )
            let squashDelta = try repository.git.run(
                "diff-tree",
                "--raw",
                "-r",
                "--no-renames",
                "\(squashCase.squashCommit)^1",
                squashCase.squashCommit
            )
            #expect(branchDelta == squashDelta)
            #expect(branchDelta.split(whereSeparator: \.isNewline).count == squashCase.matchingDeltaPathCount)
        }

        let client = LibGit2AgentStudioGitLocalClient()
        let pr388 = try #require(fixture.manifest.cases.first { $0.pullRequest == 388 })
        let pr395 = try #require(fixture.manifest.cases.first { $0.pullRequest == 395 })

        let sameContentReport = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: repository.repositoryPath,
                branchNames: ["fixture/pr-388"],
                targetCommit: pr388.squashCommit,
                squashSearchCommitLimit: 500
            )
        )
        let squashReport = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: repository.repositoryPath,
                branchNames: ["fixture/pr-388", "fixture/pr-395"],
                targetCommit: fixture.manifest.sourceHead,
                squashSearchCommitLimit: 500
            )
        )
        let limitedReport = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: repository.repositoryPath,
                branchNames: ["fixture/pr-388", "fixture/pr-395"],
                targetCommit: fixture.manifest.sourceHead,
                squashSearchCommitLimit: 3
            )
        )

        #expect(sameContentReport.assessments.first?.grade == .integrated(.sameContent))
        #expect(
            squashReport.assessments.map(\.grade) == [
                .integrated(.squash(commit: pr388.squashCommit)),
                .integrated(.squash(commit: pr395.squashCommit)),
            ])
        #expect(
            limitedReport.assessments.map(\.grade) == [
                .unknown(.historyLimitReached),
                .unknown(.historyLimitReached),
            ])
    }
}
