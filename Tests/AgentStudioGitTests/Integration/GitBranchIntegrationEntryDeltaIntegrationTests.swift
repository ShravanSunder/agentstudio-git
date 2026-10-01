import AgentStudioGit
import CLibGit2Local
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Git branch integration tree entry deltas")
struct GitBranchIntegrationEntryDeltaIntegrationTests {
    @Test("modes, binary blobs, symlinks, renames, directories, and gitlinks match exactly")
    func exactDeltasPreserveGitTreeEntryFacts() async throws {
        // Arrange
        let treeRepository = try GitBranchIntegrationTreeRepository(
            prefix: "agentstudio-git-integration-entry-facts"
        )
        defer { treeRepository.fixture.remove() }
        let base = try makeBase(in: treeRepository)
        let branches = try makeBranchCommits(in: treeRepository, base: base)
        let target = try makeTargetCandidates(in: treeRepository, base: base, branches: branches)
        try configureHostileDiffSettings(in: treeRepository.fixture)

        // Act
        let report = try await LibGit2AgentStudioGitLocalClient().assessBranchIntegration(
            GitBranchIntegrationRequest(
                repositoryPath: treeRepository.fixture.repositoryPath,
                branchNames: branches.names,
                targetCommit: target.finalCommit,
                squashSearchCommitLimit: 500
            )
        )

        // Assert
        let expectedGrades = try branches.names.map { name in
            GitBranchIntegrationGrade.integrated(
                .squash(commit: try #require(target.candidateCommits[name]))
            )
        }
        #expect(report.assessments.map(\.grade) == expectedGrades)
        try assertRenameAndDirectoryDeltaPaths(
            in: treeRepository,
            baseCommit: base.commit,
            branches: branches
        )
    }

    private func makeBase(in repository: GitBranchIntegrationTreeRepository) throws -> BaseState {
        let attributesBlob = try repository.writeBlob(Data("* diff=review\n".utf8))
        let scriptBlob = try repository.writeBlob(Data("#!/bin/sh\necho base\n".utf8))
        let renameBlob = try repository.writeBlob(Data("rename payload\n".utf8))
        let nodeBlob = try repository.writeBlob(Data("node file\n".utf8))
        let childBlob = try repository.writeBlob(Data("node child\n".utf8))
        let symlinkBlob = try repository.writeBlob(Data("target-a".utf8))
        let childTree = try repository.writeTree(entries: [makeEntry(childBlob, path: "child.txt")])
        let entries = [
            makeEntry(repository.readmeBlob, path: "README.md"),
            makeEntry(attributesBlob, path: ".gitattributes"),
            makeEntry(scriptBlob, path: "script.sh"),
            makeEntry(renameBlob, path: "old-name.txt"),
            makeEntry(nodeBlob, path: "node"),
        ]
        let baseCommit = try repository.writeCommit(
            tree: repository.writeTree(entries: entries),
            parent: repository.initialCommit,
            message: "base with varied tree entry kinds"
        )
        return BaseState(
            entries: entries,
            commit: baseCommit,
            scriptEntry: makeEntry(scriptBlob, path: "script.sh"),
            renameEntry: makeEntry(renameBlob, path: "old-name.txt"),
            nodeEntry: makeEntry(nodeBlob, path: "node"),
            symlinkBlob: symlinkBlob,
            childTree: childTree
        )
    }

    private func makeBranchCommits(
        in repository: GitBranchIntegrationTreeRepository,
        base: BaseState
    ) throws -> BranchState {
        let executableEntry = GitBranchIntegrationTreeEntry(
            mode: "100755", objectType: "blob", objectID: base.scriptEntry.objectID, path: "script.sh"
        )
        let binaryBlob = try repository.writeBlob(Data([0x00, 0x41, 0xff, 0x00, 0x43]))
        let binaryEntry = makeEntry(binaryBlob, path: "binary.bin")
        let symlinkEntry = GitBranchIntegrationTreeEntry(
            mode: "120000", objectType: "blob", objectID: base.symlinkBlob, path: "link"
        )
        let renamedEntry = makeEntry(base.renameEntry.objectID, path: "new-name.txt")
        let directoryEntry = GitBranchIntegrationTreeEntry(
            mode: "040000", objectType: "tree", objectID: base.childTree, path: "node"
        )
        let gitlinkEntry = GitBranchIntegrationTreeEntry(
            mode: "160000", objectType: "commit", objectID: base.commit, path: "submodule"
        )
        let specs = [
            BranchCommitSpec(
                name: "mode-only",
                entries: replacing([base.scriptEntry], with: executableEntry, in: base.entries),
                message: "mode-only feature"
            ),
            BranchCommitSpec(name: "binary", entries: base.entries + [binaryEntry], message: "binary feature"),
            BranchCommitSpec(name: "symlink", entries: base.entries + [symlinkEntry], message: "symlink feature"),
            BranchCommitSpec(
                name: "rename",
                entries: replacing([base.renameEntry], with: renamedEntry, in: base.entries),
                message: "rename feature"
            ),
            BranchCommitSpec(
                name: "file-to-directory",
                entries: replacing([base.nodeEntry], with: directoryEntry, in: base.entries),
                message: "file to directory feature"
            ),
            BranchCommitSpec(name: "gitlink", entries: base.entries + [gitlinkEntry], message: "gitlink feature"),
        ]
        var commits: [String: String] = [:]
        for spec in specs {
            let commit = try writeBranch(spec, baseCommit: base.commit, in: repository)
            try repository.updateBranch(spec.name, to: commit)
            commits[spec.name] = commit
        }
        return BranchState(
            commits: commits,
            names: specs.map(\.name),
            executableEntry: executableEntry,
            binaryEntry: binaryEntry,
            symlinkEntry: symlinkEntry,
            renamedEntry: renamedEntry,
            directoryEntry: directoryEntry,
            gitlinkEntry: gitlinkEntry
        )
    }

    private func makeTargetCandidates(
        in repository: GitBranchIntegrationTreeRepository,
        base: BaseState,
        branches: BranchState
    ) throws -> TargetState {
        var targetEntries = base.entries
        var parentCommit = base.commit
        var candidateCommits: [String: String] = [:]
        let candidateSpecs = [
            TargetCandidateSpec(
                name: "mode-only",
                entryChanges: [(base.scriptEntry, branches.executableEntry)],
                message: "target mode-only candidate"
            ),
            TargetCandidateSpec(
                name: "binary", appendEntries: [branches.binaryEntry], message: "target binary candidate"
            ),
            TargetCandidateSpec(
                name: "symlink", appendEntries: [branches.symlinkEntry], message: "target symlink candidate"
            ),
            TargetCandidateSpec(
                name: "rename",
                entryChanges: [(base.renameEntry, branches.renamedEntry)],
                message: "target rename candidate"
            ),
            TargetCandidateSpec(
                name: "file-to-directory",
                entryChanges: [(base.nodeEntry, branches.directoryEntry)],
                message: "target file to directory candidate"
            ),
            TargetCandidateSpec(
                name: "gitlink", appendEntries: [branches.gitlinkEntry], message: "target gitlink candidate"
            ),
        ]
        for spec in candidateSpecs {
            targetEntries = applying(spec, to: targetEntries)
            parentCommit = try repository.writeCommit(
                tree: repository.writeTree(entries: targetEntries),
                parent: parentCommit,
                message: spec.message
            )
            candidateCommits[spec.name] = parentCommit
        }

        let laterBlob = try repository.writeBlob(Data("later target change\n".utf8))
        targetEntries.append(makeEntry(laterBlob, path: "later.txt"))
        let finalCommit = try repository.writeCommit(
            tree: repository.writeTree(entries: targetEntries),
            parent: parentCommit,
            message: "advance target after candidates"
        )
        return TargetState(finalCommit: finalCommit, candidateCommits: candidateCommits)
    }

    private func writeBranch(
        _ spec: BranchCommitSpec,
        baseCommit: String,
        in repository: GitBranchIntegrationTreeRepository
    ) throws -> String {
        try repository.writeCommit(
            tree: repository.writeTree(entries: spec.entries),
            parent: baseCommit,
            message: spec.message
        )
    }

    private func applying(
        _ spec: TargetCandidateSpec,
        to entries: [GitBranchIntegrationTreeEntry]
    ) -> [GitBranchIntegrationTreeEntry] {
        var updatedEntries = entries
        for (oldEntry, replacement) in spec.entryChanges {
            updatedEntries = replacing([oldEntry], with: replacement, in: updatedEntries)
        }
        return updatedEntries + spec.appendEntries
    }

    private func assertRenameAndDirectoryDeltaPaths(
        in treeRepository: GitBranchIntegrationTreeRepository,
        baseCommit: String,
        branches: BranchState
    ) throws {
        try LibGit2ReviewSupport.withRepository(at: treeRepository.fixture.repositoryPath) { repository in
            let baseTree = try LibGit2ReviewSupport.resolveTree(.named(baseCommit), repository: repository)
            defer { git_tree_free(baseTree) }
            let renameTree = try resolveBranchTree(branches.commits["rename"], repository: repository)
            defer { git_tree_free(renameTree) }
            let directoryTree = try resolveBranchTree(branches.commits["file-to-directory"], repository: repository)
            defer { git_tree_free(directoryTree) }
            let deltaReader = LibGit2BranchIntegrationDeltaReader()
            let renameDelta = try deltaReader.read(oldTree: baseTree, newTree: renameTree, repository: repository)
            let directoryDelta = try deltaReader.read(oldTree: baseTree, newTree: directoryTree, repository: repository)
            #expect(renameDelta.entries.map(\.path) == [Array("new-name.txt".utf8), Array("old-name.txt".utf8)])
            #expect(directoryDelta.entries.map(\.path) == [Array("node".utf8), Array("node/child.txt".utf8)])
        }
    }

    private func resolveBranchTree(_ commit: String?, repository: OpaquePointer) throws -> OpaquePointer {
        guard let commit else {
            throw GitDataPlaneError.unsupported(message: "branch integration fixture is missing a branch commit")
        }
        return try LibGit2ReviewSupport.resolveTree(.named(commit), repository: repository)
    }

    private func configureHostileDiffSettings(in fixture: GitFixtureRepository) throws {
        try fixture.git.run("config", "core.filemode", "false")
        try fixture.git.run("config", "core.ignorecase", "true")
        try fixture.git.run("config", "diff.ignoreSubmodules", "all")
        try fixture.git.run("config", "diff.review.textconv", "/usr/bin/false")
    }

    private func makeEntry(_ objectID: String, path: String) -> GitBranchIntegrationTreeEntry {
        GitBranchIntegrationTreeEntry(mode: "100644", objectType: "blob", objectID: objectID, path: path)
    }

    private func replacing(
        _ oldEntries: [GitBranchIntegrationTreeEntry],
        with replacement: GitBranchIntegrationTreeEntry,
        in entries: [GitBranchIntegrationTreeEntry]
    ) -> [GitBranchIntegrationTreeEntry] {
        let oldPaths = Set(oldEntries.map(\.path))
        return entries.filter { !oldPaths.contains($0.path) } + [replacement]
    }
}

private struct BaseState {
    let entries: [GitBranchIntegrationTreeEntry]
    let commit: String
    let scriptEntry: GitBranchIntegrationTreeEntry
    let renameEntry: GitBranchIntegrationTreeEntry
    let nodeEntry: GitBranchIntegrationTreeEntry
    let symlinkBlob: String
    let childTree: String
}

private struct BranchState {
    let commits: [String: String]
    let names: [String]
    let executableEntry: GitBranchIntegrationTreeEntry
    let binaryEntry: GitBranchIntegrationTreeEntry
    let symlinkEntry: GitBranchIntegrationTreeEntry
    let renamedEntry: GitBranchIntegrationTreeEntry
    let directoryEntry: GitBranchIntegrationTreeEntry
    let gitlinkEntry: GitBranchIntegrationTreeEntry
}

private struct TargetState {
    let finalCommit: String
    let candidateCommits: [String: String]
}

private struct BranchCommitSpec {
    let name: String
    let entries: [GitBranchIntegrationTreeEntry]
    let message: String
}

private struct TargetCandidateSpec {
    let name: String
    var entryChanges: [(GitBranchIntegrationTreeEntry, GitBranchIntegrationTreeEntry)] = []
    var appendEntries: [GitBranchIntegrationTreeEntry] = []
    let message: String
}
