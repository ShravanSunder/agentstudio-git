import AgentStudioGit
import CLibGit2Local
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch integration history overlays")
struct GitBranchIntegrationHistoryIntegrationTests {
    @Test("shallow and grafted repositories suppress history proofs but retain direct proofs")
    func shallowAndGraftedRepositoriesKeepDirectProofs() async throws {
        // Arrange
        let shallowFixture = try GitBranchIntegrationHistoryFixture.make(prefix: "agentstudio-git-integration-shallow")
        defer { shallowFixture.repository.remove() }
        try Data("\(shallowFixture.targetCommit)\n".utf8).write(to: shallowFixture.shallowPath)

        let graftFixture = try GitBranchIntegrationHistoryFixture.make(prefix: "agentstudio-git-integration-grafts")
        defer { graftFixture.repository.remove() }
        try Data("\(graftFixture.targetCommit)\n".utf8).write(to: graftFixture.graftsPath)

        let client = LibGit2AgentStudioGitLocalClient()

        // Act
        let shallowReport = try await client.assessBranchIntegration(
            shallowFixture.request(branchNames: ["ancestor", "same-target", "same-content"])
        )
        let graftReport = try await client.assessBranchIntegration(
            graftFixture.request(branchNames: ["ancestor", "same-target", "same-content"])
        )

        // Assert
        for report in [shallowReport, graftReport] {
            #expect(report.assessments[0].grade == .unknown(.incompleteHistory))
            #expect(report.assessments[1].grade == .integrated(.sameCommit))
            #expect(report.assessments[2].grade == .integrated(.sameContent))
        }
    }

    @Test("zero-byte shallow and graft files do not create an incomplete-history overlay")
    func zeroByteOverlayFilesLeaveGraphProofsAvailable() async throws {
        // Arrange
        let fixture = try GitBranchIntegrationHistoryFixture.make(prefix: "agentstudio-git-integration-empty-overlays")
        defer { fixture.repository.remove() }
        try Data().write(to: fixture.shallowPath)
        try Data().write(to: fixture.graftsPath)

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            fixture.request(branchNames: ["ancestor"])
        )

        // Assert
        #expect(report.assessments.first?.grade == .integrated(.ancestor))
    }

    @Test("linked worktrees resolve common grafts and shallow guards")
    func linkedWorktreeHistoryGuardsUseTheirGitDirectories() async throws {
        // Arrange
        let fixture = try GitBranchIntegrationHistoryFixture.make(prefix: "agentstudio-git-integration-linked-overlays")
        defer { fixture.repository.remove() }
        let linkedPath = try fixture.repository.addLinkedWorktree(named: "linked-history", branch: "linked-history")
        let historyPaths = try GitBranchIntegrationHistoryPaths.resolve(
            repositoryPath: linkedPath,
            identityResolver: GitRepositoryIdentityResolver()
        )
        let openedPaths = try LibGit2ReviewSupport.withRepository(at: linkedPath) { repository in
            guard let gitDirectoryPointer = git_repository_path(repository),
                let commonDirectoryPointer = git_repository_commondir(repository)
            else {
                throw GitDataPlaneError.unsupported(message: "linked fixture repository paths are unavailable")
            }
            var infoBuffer = git_buf()
            defer { git_buf_dispose(&infoBuffer) }
            let infoResult = git_repository_item_path(&infoBuffer, repository, GIT_REPOSITORY_ITEM_INFO)
            guard infoResult >= 0, let infoDirectoryPointer = infoBuffer.ptr else {
                throw GitDataPlaneError.unsupported(message: "linked fixture INFO path is unavailable")
            }
            return (
                gitDirectory: URL(fileURLWithPath: String(cString: gitDirectoryPointer), isDirectory: true),
                commonDirectory: URL(fileURLWithPath: String(cString: commonDirectoryPointer), isDirectory: true),
                infoDirectory: URL(fileURLWithPath: String(cString: infoDirectoryPointer), isDirectory: true)
            )
        }
        #expect(GitBranchIntegrationHistoryPaths.canonicalURL(openedPaths.gitDirectory) == historyPaths.gitDirectory)
        #expect(
            GitBranchIntegrationHistoryPaths.canonicalURL(openedPaths.commonDirectory) == historyPaths.commonDirectory
        )
        #expect(
            GitBranchIntegrationHistoryPaths.canonicalURL(openedPaths.infoDirectory)
                == GitBranchIntegrationHistoryPaths.canonicalURL(historyPaths.commonDirectory.appending(path: "info"))
        )
        #expect(historyPaths.commonDirectory != historyPaths.gitDirectory)
        #expect(historyPaths.graftsFile == fixture.repository.repositoryPath.appending(path: ".git/info/grafts"))
        #expect(historyPaths.shallowFile.deletingLastPathComponent() == historyPaths.commonDirectory)

        let client = LibGit2AgentStudioGitLocalClient()
        try Data("\(fixture.targetCommit)\n".utf8).write(to: historyPaths.graftsFile)

        // Act
        let graftReport = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: linkedPath,
                branchNames: ["ancestor", "same-target", "same-content"],
                targetCommit: fixture.targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(graftReport.assessments[0].grade == .unknown(.incompleteHistory))
        #expect(graftReport.assessments[1].grade == .integrated(.sameCommit))
        #expect(graftReport.assessments[2].grade == .integrated(.sameContent))

        // Act
        try Data().write(to: historyPaths.graftsFile)
        try Data("\(fixture.targetCommit)\n".utf8).write(to: historyPaths.shallowFile)
        let shallowReport = try await client.assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: linkedPath,
                branchNames: ["ancestor"],
                targetCommit: fixture.targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(shallowReport.assessments.first?.grade == .unknown(.incompleteHistory))
    }

    @Test("linked worktrees in a real shallow clone use Git's common shallow path")
    func linkedShallowCloneUsesGitCommonShallowPath() async throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-shallow-clone")
        defer { fixture.remove() }
        try fixture.write("middle.txt", contents: "middle\n")
        try fixture.git.run("add", "middle.txt")
        try fixture.git.run("commit", "-m", "shallow boundary commit")
        let boundaryCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.write("tip.txt", contents: "tip\n")
        try fixture.git.run("add", "tip.txt")
        try fixture.git.run("commit", "-m", "shallow target commit")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let shallowClonePath = fixture.root.appending(path: "shallow-clone")
        try fixture.git.run(
            [
                "clone", "--depth=2", "--no-local", "--branch", "main",
                fixture.repositoryPath.absoluteString, shallowClonePath.path,
            ],
            currentDirectory: fixture.root
        )
        let shallowCloneGit = GitProcess(repositoryPath: shallowClonePath)
        try shallowCloneGit.run("branch", "ancestor", boundaryCommit)
        let linkedWorktreePath = fixture.root.appending(path: "linked-shallow")
        try shallowCloneGit.run(["worktree", "add", "-b", "linked-history", linkedWorktreePath.path, "HEAD"])
        let linkedWorktreeGit = GitProcess(repositoryPath: linkedWorktreePath)
        let shallowOraclePath = URL(
            fileURLWithPath: try linkedWorktreeGit.run(
                ["rev-parse", "--path-format=absolute", "--git-path", "shallow"]
            ).trimmed
        )
        let historyPaths = try GitBranchIntegrationHistoryPaths.resolve(
            repositoryPath: linkedWorktreePath,
            identityResolver: GitRepositoryIdentityResolver()
        )
        let shallowRecords = Set(
            try String(contentsOf: shallowOraclePath, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: linkedWorktreePath,
                branchNames: ["ancestor"],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        #expect(
            GitBranchIntegrationHistoryPaths.canonicalURL(historyPaths.shallowFile)
                == GitBranchIntegrationHistoryPaths.canonicalURL(shallowOraclePath)
        )
        #expect(historyPaths.commonDirectory != historyPaths.gitDirectory)
        #expect(shallowRecords.contains(boundaryCommit))
        #expect(report.assessments.first?.grade == .unknown(.incompleteHistory))
    }

    @Test("a guard changed after delta reads invalidates graph positives but preserves direct proofs")
    func changedGuardAfterDeltaReadInvalidatesPositiveGraphProofs() throws {
        // Arrange
        let fixture = try GitFixtureRepository.makeRepository(prefix: "agentstudio-git-integration-post-delta-guard")
        defer { fixture.remove() }
        let baseCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        let baseReadme = try String(contentsOf: fixture.repositoryPath.appending(path: "README.md"), encoding: .utf8)
        let mainBranch = try fixture.git.run("branch", "--show-current").trimmed
        try fixture.git.run("branch", "ancestor", baseCommit)

        try fixture.git.run("checkout", "-b", "empty-delta", baseCommit)
        try fixture.write("README.md", contents: "temporary\n")
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "temporary branch change")
        try fixture.write("README.md", contents: baseReadme)
        try fixture.git.run("add", "README.md")
        try fixture.git.run("commit", "-m", "restore base tree")

        try fixture.git.run("checkout", "-b", "squash", baseCommit)
        try fixture.write("feature.txt", contents: "squashed contribution\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "feature contribution")
        try fixture.git.run("checkout", mainBranch)
        try fixture.write("feature.txt", contents: "squashed contribution\n")
        try fixture.git.run("add", "feature.txt")
        try fixture.git.run("commit", "-m", "squash feature contribution")
        try fixture.write("target.txt", contents: "advance target\n")
        try fixture.git.run("add", "target.txt")
        try fixture.git.run("commit", "-m", "advance after squash")
        let targetCommit = try fixture.git.run("rev-parse", "HEAD").trimmed
        try fixture.git.run("branch", "same-commit", targetCommit)
        try fixture.git.run("checkout", "-b", "same-content", targetCommit)
        try fixture.git.run("commit", "--allow-empty", "-m", "same-tree direct proof")
        try fixture.git.run("checkout", mainBranch)

        let graftsPath = fixture.repositoryPath.appending(path: ".git/info/grafts")
        let graftRecord = Data("\(baseCommit)\n".utf8)
        let reader = LibGit2BranchIntegrationReader(
            deltaReader: LibGit2BranchIntegrationDeltaReader(afterDeltaRead: {
                try? graftRecord.write(to: graftsPath)
            })
        )
        let request = GitBranchIntegrationRequest(
            repositoryPath: fixture.repositoryPath,
            branchNames: ["ancestor", "empty-delta", "squash", "same-commit", "same-content"],
            targetCommit: targetCommit,
            squashSearchCommitLimit: 500
        )

        // Act
        let report = try reader.assess(request)

        // Assert
        #expect(
            report.assessments.map(\.grade) == [
                .unknown(.readFailed), .unknown(.readFailed), .unknown(.readFailed),
                .integrated(.sameCommit), .integrated(.sameContent),
            ])
    }

    @Test("a malformed nonempty graft file remains a repository-level open failure")
    func malformedGraftDataFailsRepositoryOpen() async throws {
        // Arrange
        let fixture = try GitBranchIntegrationHistoryFixture.make(
            prefix: "agentstudio-git-integration-malformed-grafts")
        defer { fixture.repository.remove() }
        try Data("# malformed comment\n".utf8).write(to: fixture.graftsPath)

        // Act / Assert
        var openError: GitDataPlaneError?
        do {
            _ = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
                fixture.request(branchNames: ["ancestor"])
            )
        } catch let error {
            openError = error
        }
        guard let openError else {
            Issue.record("Malformed graft data unexpectedly produced branch assessment rows")
            return
        }
        if case .libgit2Failure = openError {
            return
        }
        Issue.record("Expected a repository-open libgit2 failure, received \(openError)")
    }

    @Test("changed or unreadable history guards suppress graph proofs without suppressing direct proofs")
    func changedAndUnreadableHistoryGuardsFailClosedForGraphProofs() throws {
        // Arrange
        let changedFixture = try GitBranchIntegrationHistoryFixture.make(
            prefix: "agentstudio-git-integration-changed-guard")
        defer { changedFixture.repository.remove() }
        let changedGraftsPath = changedFixture.graftsPath
        let changedReader = LibGit2BranchIntegrationReader(
            afterRepositoryOpen: {
                try? Data().write(to: changedGraftsPath)
            }
        )

        let unreadableFixture = try GitBranchIntegrationHistoryFixture.make(
            prefix: "agentstudio-git-integration-unreadable-guard")
        defer { unreadableFixture.repository.remove() }
        let unreadableGraftsPath = unreadableFixture.graftsPath
        let unreadableReader = LibGit2BranchIntegrationReader(
            afterRepositoryOpen: {
                try? FileManager.default.createDirectory(
                    at: unreadableGraftsPath,
                    withIntermediateDirectories: true
                )
            }
        )

        // Act
        let changedReport = try changedReader.assess(
            changedFixture.request(branchNames: ["ancestor", "same-target", "same-content"])
        )
        let unreadableReport = try unreadableReader.assess(
            unreadableFixture.request(branchNames: ["ancestor", "same-target", "same-content"])
        )

        // Assert
        for report in [changedReport, unreadableReport] {
            #expect(report.assessments[0].grade == .unknown(.readFailed))
            #expect(report.assessments[1].grade == .integrated(.sameCommit))
            #expect(report.assessments[2].grade == .integrated(.sameContent))
        }
    }
}

private struct GitBranchIntegrationHistoryFixture {
    let repository: GitFixtureRepository
    let baseCommit: String
    let targetCommit: String

    var graftsPath: URL {
        repository.repositoryPath.appending(path: ".git/info/grafts")
    }

    var shallowPath: URL {
        repository.repositoryPath.appending(path: ".git/shallow")
    }

    static func make(prefix: String) throws -> Self {
        let repository = try GitFixtureRepository.makeRepository(prefix: prefix)
        let baseCommit = try repository.git.run("rev-parse", "HEAD").trimmed
        let mainBranch = try repository.git.run("branch", "--show-current").trimmed
        try repository.git.run("branch", "ancestor", baseCommit)
        try repository.write("target.txt", contents: "target\n")
        try repository.git.run("add", "target.txt")
        try repository.git.run("commit", "-m", "advance target")
        let targetCommit = try repository.git.run("rev-parse", "HEAD").trimmed
        try repository.git.run("branch", "same-target", targetCommit)
        try repository.git.run("checkout", "-b", "same-content", targetCommit)
        try repository.git.run("commit", "--allow-empty", "-m", "same tree, new commit")
        try repository.git.run("checkout", mainBranch)
        return Self(repository: repository, baseCommit: baseCommit, targetCommit: targetCommit)
    }

    func request(branchNames: [String]) -> GitBranchIntegrationRequest {
        GitBranchIntegrationRequest(
            repositoryPath: repository.repositoryPath,
            branchNames: branchNames,
            targetCommit: targetCommit,
            squashSearchCommitLimit: 500
        )
    }
}
