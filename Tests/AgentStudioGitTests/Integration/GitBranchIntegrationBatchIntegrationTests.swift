import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch integration batch behavior")
struct GitBranchIntegrationBatchIntegrationTests {
    @Test("duplicate branch rows share one lazy first-parent delta walk")
    func duplicateRowsShareLazyTargetDeltaWork() throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-shared-index")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        for branchName in ["feature-a", "feature-b"] {
            try fixture.git.run("checkout", "-b", branchName, baseCommit)
            try fixture.write("feature.txt", contents: "shared feature delta\n")
            try fixture.git.run("add", "feature.txt")
            try fixture.git.run("commit", "-m", "feature contribution")
            try fixture.git.run("checkout", mainBranch)
        }
        try fixture.write("feature.txt", contents: "shared feature delta\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "squash both feature rows")
        let squashCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("later.txt", contents: "later target change\n")
        try fixture.git.run("add", "later.txt")
        try fixture.git.run("commit", "-m", "advance target after squash")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let readCounter = GitBranchIntegrationDeltaReadCounter()
        let reader = LibGit2BranchIntegrationReader(
            deltaReader: LibGit2BranchIntegrationDeltaReader(afterDeltaRead: { readCounter.record() })
        )

        // Act
        let report = try reader.assess(
            GitBranchIntegrationRequest(
                repositoryPath: fixture.repositoryPath,
                branchNames: ["feature-a", "feature-b"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(
            report.assessments.map(\.grade) == [
                .integrated(.squash(commit: squashCommit)),
                .integrated(.squash(commit: squashCommit)),
            ])
        #expect(readCounter.count == 4)
    }
}

private final class GitBranchIntegrationDeltaReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        storedCount += 1
    }
}
