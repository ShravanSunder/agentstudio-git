import AgentStudioGit
import Foundation
import Testing

@Suite("Git branch integration squash edge cases")
struct GitBranchIntegrationSquashEdgeIntegrationTests {
    @Test("an edit to the same target path before a squash remains a conservative miss")
    func preLandingEditToSamePathDoesNotMatch() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-pre-landing-edit"
        )
        defer { treeRepository.fixture.remove() }
        let baseBlob = try treeRepository.writeBlob(Data("base\n".utf8))
        let featureBlob = try treeRepository.writeBlob(Data("feature\n".utf8))
        let preLandingBlob = try treeRepository.writeBlob(Data("target pre-landing\n".utf8))
        let baseEntries = [
            makeEntry("README.md", blob: treeRepository.readmeBlob), makeEntry("shared.txt", blob: baseBlob),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "common base"
        )
        let featureEntries = replacing(
            baseEntries,
            path: "shared.txt",
            with: makeEntry("shared.txt", blob: featureBlob)
        )
        let featureTree = try treeRepository.writeTree(entries: featureEntries)
        let featureCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: baseCommit,
            message: "feature change"
        )
        try treeRepository.updateBranch("feature", to: featureCommit)
        let preLandingTree = try treeRepository.writeTree(
            entries: replacing(baseEntries, path: "shared.txt", with: makeEntry("shared.txt", blob: preLandingBlob))
        )
        let preLandingCommit = try treeRepository.writeCommit(
            tree: preLandingTree,
            parent: baseCommit,
            message: "target edits the path first"
        )
        let landingCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: preLandingCommit,
            message: "conflict-free final content after pre-landing edit"
        )
        let laterBlob = try treeRepository.writeBlob(Data("later target file\n".utf8))
        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: featureEntries + [makeEntry("later.txt", blob: laterBlob)]
            ),
            parent: landingCommit,
            message: "advance target after squash"
        )

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: targetCommit)

        // Assert
        #expect(grade == .hasRemainingContribution)
    }

    @Test("a conflict-resolved squash with different bytes remains a conservative miss")
    func conflictResolvedSquashDoesNotMatch() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-conflict-resolved"
        )
        defer { treeRepository.fixture.remove() }
        let baseLeft = try treeRepository.writeBlob(Data("left base\n".utf8))
        let baseRight = try treeRepository.writeBlob(Data("right base\n".utf8))
        let featureLeft = try treeRepository.writeBlob(Data("left feature\n".utf8))
        let featureRight = try treeRepository.writeBlob(Data("right feature\n".utf8))
        let resolvedLeft = try treeRepository.writeBlob(Data("conflict resolution\n".utf8))
        let baseEntries = [
            makeEntry("README.md", blob: treeRepository.readmeBlob),
            makeEntry("left.txt", blob: baseLeft),
            makeEntry("right.txt", blob: baseRight),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "common base"
        )
        let featureTree = try treeRepository.writeTree(
            entries: replacing(
                replacing(baseEntries, path: "left.txt", with: makeEntry("left.txt", blob: featureLeft)),
                path: "right.txt",
                with: makeEntry("right.txt", blob: featureRight)
            )
        )
        let featureCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: baseCommit,
            message: "feature changes both paths"
        )
        try treeRepository.updateBranch("feature", to: featureCommit)
        let resolvedTree = try treeRepository.writeTree(
            entries: replacing(
                replacing(baseEntries, path: "left.txt", with: makeEntry("left.txt", blob: resolvedLeft)),
                path: "right.txt",
                with: makeEntry("right.txt", blob: featureRight)
            )
        )
        let resolvedCommit = try treeRepository.writeCommit(
            tree: resolvedTree,
            parent: baseCommit,
            message: "resolve conflict with distinct content"
        )
        let laterBlob = try treeRepository.writeBlob(Data("later target file\n".utf8))
        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: [
                    makeEntry("README.md", blob: treeRepository.readmeBlob),
                    makeEntry("left.txt", blob: resolvedLeft),
                    makeEntry("right.txt", blob: featureRight),
                    makeEntry("later.txt", blob: laterBlob),
                ]
            ),
            parent: resolvedCommit,
            message: "advance after conflict resolution"
        )

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: targetCommit)

        // Assert
        #expect(grade == .hasRemainingContribution)
    }

    @Test("a partial squash retains the branch contribution")
    func partialSquashLeavesContribution() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-partial-squash"
        )
        defer { treeRepository.fixture.remove() }
        let baseLeft = try treeRepository.writeBlob(Data("left base\n".utf8))
        let baseRight = try treeRepository.writeBlob(Data("right base\n".utf8))
        let featureLeft = try treeRepository.writeBlob(Data("left feature\n".utf8))
        let featureRight = try treeRepository.writeBlob(Data("right feature\n".utf8))
        let baseEntries = [
            makeEntry("README.md", blob: treeRepository.readmeBlob),
            makeEntry("left.txt", blob: baseLeft),
            makeEntry("right.txt", blob: baseRight),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "common base"
        )
        let featureTree = try treeRepository.writeTree(
            entries: replacing(
                replacing(baseEntries, path: "left.txt", with: makeEntry("left.txt", blob: featureLeft)),
                path: "right.txt",
                with: makeEntry("right.txt", blob: featureRight)
            )
        )
        let featureCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: baseCommit,
            message: "feature changes both paths"
        )
        try treeRepository.updateBranch("feature", to: featureCommit)
        let partialCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: replacing(baseEntries, path: "left.txt", with: makeEntry("left.txt", blob: featureLeft))
            ),
            parent: baseCommit,
            message: "target lands only one path"
        )

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: partialCommit)

        // Assert
        #expect(grade == .hasRemainingContribution)
    }

    @Test("merge commits are squash candidates against their first parent")
    func mergeCommitCanMatchFirstParentDelta() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-merge-candidate"
        )
        defer { treeRepository.fixture.remove() }
        let baseBlob = try treeRepository.writeBlob(Data("base\n".utf8))
        let featureBlob = try treeRepository.writeBlob(Data("feature\n".utf8))
        let baseEntries = [
            makeEntry("README.md", blob: treeRepository.readmeBlob), makeEntry("shared.txt", blob: baseBlob),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "common base"
        )
        let featureEntries = replacing(
            baseEntries,
            path: "shared.txt",
            with: makeEntry("shared.txt", blob: featureBlob)
        )
        let featureTree = try treeRepository.writeTree(entries: featureEntries)
        let featureCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: baseCommit,
            message: "feature change"
        )
        try treeRepository.updateBranch("feature", to: featureCommit)
        let sideCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: baseCommit,
            message: "independent empty side commit"
        )
        let mergeCommit = try treeRepository.fixture.git.run(
            ["commit-tree", featureTree, "-p", baseCommit, "-p", sideCommit, "-m", "merge-shaped squash candidate"]
        ).trimmed
        let laterBlob = try treeRepository.writeBlob(Data("later target file\n".utf8))
        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: featureEntries + [makeEntry("later.txt", blob: laterBlob)]),
            parent: mergeCommit,
            message: "advance after merge candidate"
        )

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: targetCommit)

        // Assert
        #expect(grade == .integrated(.squash(commit: mergeCommit)))
    }

    @Test("a root at the first-parent boundary is not treated as a squash candidate")
    func rootCommitEndsSquashSearch() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-root-boundary"
        )
        defer { treeRepository.fixture.remove() }
        let featureBlob = try treeRepository.writeBlob(Data("feature\n".utf8))
        let targetBlob = try treeRepository.writeBlob(Data("target\n".utf8))
        let featureTree = try treeRepository.writeTree(entries: [
            makeEntry("README.md", blob: treeRepository.readmeBlob),
            makeEntry("feature.txt", blob: featureBlob),
        ])
        let featureCommit = try treeRepository.writeCommit(
            tree: featureTree,
            parent: treeRepository.initialCommit,
            message: "feature from root"
        )
        try treeRepository.updateBranch("feature", to: featureCommit)
        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: [
                makeEntry("README.md", blob: treeRepository.readmeBlob),
                makeEntry("target.txt", blob: targetBlob),
            ]),
            parent: treeRepository.initialCommit,
            message: "target from root"
        )

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: targetCommit)

        // Assert
        #expect(grade == .hasRemainingContribution)
    }

    private func assess(
        _ treeRepository: GitBranchIntegrationTreeRepository,
        branchName: String,
        targetCommit: String
    ) async throws -> GitBranchIntegrationGrade {
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: treeRepository.fixture.repositoryPath,
                branchNames: [branchName],
                targetCommit: targetCommit,
                squashSearchCommitLimit: 500
            )
        )
        return try #require(report.assessments.first?.grade)
    }

    private func makeEntry(_ path: String, blob: String) -> GitBranchIntegrationTreeEntry {
        GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: blob, path: path)
    }

    private func replacing(
        _ entries: [GitBranchIntegrationTreeEntry],
        path: String,
        with replacement: GitBranchIntegrationTreeEntry
    ) -> [GitBranchIntegrationTreeEntry] {
        entries.filter { $0.path != Array(path.utf8) } + [replacement]
    }

}
