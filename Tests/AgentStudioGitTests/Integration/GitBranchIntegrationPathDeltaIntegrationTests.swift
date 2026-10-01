import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch integration path deltas")
struct GitBranchIntegrationPathDeltaIntegrationTests {
    @Test("path case, canonical Unicode, and non-UTF8 bytes are not normalized")
    func pathBytesAreComparedWithoutNormalization() async throws {
        // Arrange
        let pathCases: [(name: String, oldPath: [UInt8], newPath: [UInt8])] = [
            ("case", Array("Name.txt".utf8), Array("name.txt".utf8)),
            ("unicode", Array("é.txt".utf8), Array("e\u{301}.txt".utf8)),
            ("non-utf8", [0xff, 0x2e, 0x74, 0x78, 0x74], [0xfe, 0x2e, 0x74, 0x78, 0x74]),
        ]

        for pathCase in pathCases {
            let treeRepository = try GitBranchIntegrationTreeRepository(
                prefix: "agentstudio-git-integration-path-\(pathCase.name)"
            )
            defer { treeRepository.fixture.remove() }
            let attributesBlob = try treeRepository.writeBlob(Data("*.txt diff=review\n".utf8))
            let originalBlob = try treeRepository.writeBlob(Data("original\n".utf8))
            let changedBlob = try treeRepository.writeBlob(Data("changed\n".utf8))
            let baseEntries = [
                makeEntry(treeRepository.readmeBlob, path: "README.md"),
                makeEntry(attributesBlob, path: ".gitattributes"),
                makeEntry(originalBlob, path: pathCase.oldPath),
            ]
            let baseCommit = try treeRepository.writeCommit(
                tree: treeRepository.writeTree(entries: baseEntries),
                parent: treeRepository.initialCommit,
                message: "base with exact path bytes"
            )
            let branchEntries = baseEntries.map { entry in
                guard entry.path == pathCase.oldPath else { return entry }
                return GitBranchIntegrationTreeEntry(
                    mode: entry.mode,
                    objectType: entry.objectType,
                    objectID: changedBlob,
                    path: entry.path
                )
            }
            let branchCommit = try treeRepository.writeCommit(
                tree: treeRepository.writeTree(entries: branchEntries),
                parent: baseCommit,
                message: "modify original exact path"
            )
            try treeRepository.updateBranch("path-change", to: branchCommit)
            let targetEntries = [
                baseEntries[0],
                baseEntries[1],
                makeEntry(changedBlob, path: pathCase.newPath),
            ]
            let targetCommit = try treeRepository.writeCommit(
                tree: treeRepository.writeTree(entries: targetEntries),
                parent: baseCommit,
                message: "replace path with byte-different name"
            )
            try configureHostileDiffSettings(in: treeRepository.fixture)

            // Act
            let grade = try await assess(
                treeRepository,
                branchName: "path-change",
                targetCommit: targetCommit
            )

            // Assert
            #expect(grade == .hasRemainingContribution)
        }
    }

    @Test("whitespace-only differences do not normalize to the same delta")
    func whitespaceDifferencesRemainOutstanding() async throws {
        try await assertContentMismatch(
            ContentMismatchScenario(
                name: "whitespace",
                path: "line.txt",
                baseContents: Data("line\n".utf8),
                branchContents: Data("line \n".utf8),
                targetContents: Data("line\t\n".utf8)
            )
        )
    }

    @Test("line-ending differences do not normalize to the same delta")
    func lineEndingDifferencesRemainOutstanding() async throws {
        try await assertContentMismatch(
            ContentMismatchScenario(
                name: "line-ending",
                path: "ending.txt",
                baseContents: Data("ending\n".utf8),
                branchContents: Data("ending\r\n".utf8),
                targetContents: Data("ending \r\n".utf8)
            )
        )
    }

    @Test("binary differences with NUL bytes do not normalize to the same delta")
    func binaryDifferencesRemainOutstanding() async throws {
        try await assertContentMismatch(
            ContentMismatchScenario(
                name: "binary",
                path: "binary.bin",
                baseContents: Data([0x00, 0x10, 0xff]),
                branchContents: Data([0x00, 0x11, 0xff]),
                targetContents: Data([0x00, 0x12, 0xff])
            )
        )
    }

    private func assertContentMismatch(_ scenario: ContentMismatchScenario) async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-content-\(scenario.name)"
        )
        defer { treeRepository.fixture.remove() }
        let attributesBlob = try treeRepository.writeBlob(Data("* diff=review\n".utf8))
        let baseBlob = try treeRepository.writeBlob(scenario.baseContents)
        let baseEntries = [
            makeEntry(treeRepository.readmeBlob, path: "README.md"),
            makeEntry(attributesBlob, path: ".gitattributes"),
            makeEntry(baseBlob, path: scenario.path),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "base content bytes"
        )
        let branchBlob = try treeRepository.writeBlob(scenario.branchContents)
        let branchCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: replaceEntry(
                    in: baseEntries,
                    path: scenario.path,
                    with: [makeEntry(branchBlob, path: scenario.path)]
                )
            ),
            parent: baseCommit,
            message: "feature content change"
        )
        try treeRepository.updateBranch("feature", to: branchCommit)
        let targetBlob = try treeRepository.writeBlob(scenario.targetContents)
        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: replaceEntry(
                    in: baseEntries,
                    path: scenario.path,
                    with: [makeEntry(targetBlob, path: scenario.path)]
                )
            ),
            parent: baseCommit,
            message: "target has a byte-different variant"
        )
        try configureHostileDiffSettings(in: treeRepository.fixture)

        // Act
        let grade = try await assess(treeRepository, branchName: "feature", targetCommit: targetCommit)

        // Assert
        #expect(grade == .hasRemainingContribution)
    }

    @Test("a rename chain is compared as its exact delete and add leaves")
    func renameChainUsesDeleteAndAddLeaves() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-rename-chain"
        )
        defer { treeRepository.fixture.remove() }
        let originalBlob = try treeRepository.writeBlob(Data("rename chain\n".utf8))
        let baseEntries = [
            makeEntry(treeRepository.readmeBlob, path: "README.md"),
            makeEntry(originalBlob, path: "old.txt"),
        ]
        let baseCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: baseEntries),
            parent: treeRepository.initialCommit,
            message: "rename base"
        )
        let middleEntry = makeEntry(originalBlob, path: "middle.txt")
        let middleCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: [baseEntries[0], middleEntry]),
            parent: baseCommit,
            message: "first rename"
        )
        let finalEntry = makeEntry(originalBlob, path: "final.txt")
        let branchCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: [baseEntries[0], finalEntry]),
            parent: middleCommit,
            message: "second rename"
        )
        try treeRepository.updateBranch("rename-chain", to: branchCommit)

        let targetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(entries: [baseEntries[0], finalEntry]),
            parent: baseCommit,
            message: "target rename chain"
        )
        let laterBlob = try treeRepository.writeBlob(Data("later target change\n".utf8))
        let finalTargetCommit = try treeRepository.writeCommit(
            tree: treeRepository.writeTree(
                entries: [baseEntries[0], finalEntry, makeEntry(laterBlob, path: "later.txt")]
            ),
            parent: targetCommit,
            message: "advance after rename candidate"
        )

        // Act
        let grade = try await assess(
            treeRepository,
            branchName: "rename-chain",
            targetCommit: finalTargetCommit
        )

        // Assert
        #expect(grade == .integrated(.squash(commit: targetCommit)))
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

    private func configureHostileDiffSettings(in fixture: GitFixtureRepository) throws {
        try fixture.git.run("config", "core.ignorecase", "true")
        try fixture.git.run("config", "core.filemode", "false")
        try fixture.git.run("config", "diff.ignoreSubmodules", "all")
        try fixture.git.run("config", "diff.external", "/usr/bin/false")
        try fixture.git.run("config", "diff.review.textconv", "/usr/bin/false")
    }

    private func makeEntry(_ objectID: String, path: String) -> GitBranchIntegrationTreeEntry {
        GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: objectID, path: path)
    }

    private func makeEntry(_ objectID: String, path: [UInt8]) -> GitBranchIntegrationTreeEntry {
        GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: objectID, path: path)
    }

    private func replaceEntry(
        in entries: [GitBranchIntegrationTreeEntry],
        path: String,
        with replacements: [GitBranchIntegrationTreeEntry]
    ) -> [GitBranchIntegrationTreeEntry] {
        entries.filter { $0.path != Array(path.utf8) } + replacements
    }
}

private struct ContentMismatchScenario {
    let name: String
    let path: String
    let baseContents: Data
    let branchContents: Data
    let targetContents: Data
}
