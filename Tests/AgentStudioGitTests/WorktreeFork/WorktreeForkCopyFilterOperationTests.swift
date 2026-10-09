import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Worktree copy filter operation counts")
struct WorktreeForkCopyFilterOperationTests {
    @Test("a 50,000-file ignored subtree is decided at its root", arguments: [false, true])
    func largeIgnoredSubtreeIsPruned(included: Bool) throws {
        try LibGit2Runtime.shared.ensureInitialized()
        let fixture = try GitWorktreeForkFixture.make(prefix: "copy-rule-operation")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "cache/\n")
        try fixture.git.run("add", ".gitignore")
        try fixture.git.run("commit", "-qm", "ignore cache")
        try FileManager.default.createDirectory(
            at: fixture.source.appending(path: "cache"), withIntermediateDirectories: true)
        let info = try #require(GitWorktreeForkFileProbe.info(fixture.source.appending(path: "README.md")))
        let identity = WorktreeForkEntryIdentity(info)
        var directories = [
            WorktreeForkPlannedDirectory(relativePath: "", identity: identity),
            WorktreeForkPlannedDirectory(relativePath: "cache", identity: identity),
        ]
        var batches: [WorktreeForkLeafBatch] = []
        for directoryNumber in 0..<5000 {
            let directory = "cache/\(directoryNumber)"
            directories.append(.init(relativePath: directory, identity: identity))
            batches.append(
                .init(
                    directoryRelativePath: directory,
                    leaves: (0..<10).map { fileNumber in
                        .init(
                            name: "\(fileNumber)", relativePath: "\(directory)/\(fileNumber)", kind: .regularFile,
                            identity: identity, plannedStat: WorktreeForkObservedStat(info))
                    }))
        }
        let filesystem = WorktreeForkFilesystemPlan(
            directories: directories, leafBatches: batches,
            hardLinkGroups: [], skippedEntries: [], nestedGitEntryPaths: [], gitDirectoryCandidatePaths: [])
        let patterns = included ? [try GitPathPattern("cache/")] : []
        let result = try WorktreeForkCopyFilter(cancellation: WorktreeForkCancellation()).apply(
            .init(
                filesystem: filesystem, sourceRoot: fixture.source,
                sourceCommonDirectory: fixture.source.appending(path: ".git"),
                sourceGitDirectory: fixture.source.appending(path: ".git"),
                capturedHead: .init(
                    commitOID: try fixture.blobID("HEAD", at: fixture.source),
                    treeOID: try fixture.blobID("HEAD^{tree}", at: fixture.source)),
                copyRules: .init(ignoredPaths: .copyMatching(patterns)), resetsToStart: false))
        #expect(result.classifiedPathCount == 1)
        #expect(result.ignoreQueryCount == 1)
        #expect(result.ignoredExcludedCount == (included ? 0 : 55_001))
        #expect(result.filesystem.leafBatches.count == (included ? 5000 : 0))
    }

    @Test("reset mode keeps only captured HEAD paths and ignored paths an include covers")
    func resetModeKeepsHeadAndCoveredIgnoredPaths() throws {
        // Arrange
        try LibGit2Runtime.shared.ensureInitialized()
        let fixture = try GitWorktreeForkFixture.make(prefix: "copy-rule-reset-mode")
        defer { fixture.remove() }
        try fixture.write(".gitignore", "*.o\ncache/\n")
        try fixture.write("tools/a.txt", "tracked\n")
        try fixture.write("src/main.c", "tracked\n")
        try fixture.git.run("add", ".")
        try fixture.git.run("commit", "-qm", "tracked")
        try fixture.write("tools/scratch.txt", "untracked under an included folder\n")
        try fixture.write("tools/out.o", "ignored under an included folder\n")
        try fixture.write("notes.txt", "untracked\n")
        try fixture.write("staged.txt", "staged only\n")
        try fixture.git.run("add", "staged.txt")
        try fixture.write("cache/blob.bin", "ignored, not included\n")
        try fixture.write("build.o", "ignored, not included\n")
        guard case .success(let sourceRoot) = WorktreeForkDescriptors.realpathURL(fixture.source),
            case .success(let descriptor) = WorktreeForkDescriptors.openRoot(atCanonicalPath: sourceRoot)
        else {
            Issue.record("could not open the source root")
            return
        }
        defer { close(descriptor) }
        let filesystem = try WorktreeForkSourceWalker(cancellation: WorktreeForkCancellation())
            .walk(sourceRootDescriptor: descriptor)

        // Act
        let result = try WorktreeForkCopyFilter(cancellation: WorktreeForkCancellation()).apply(
            .init(
                filesystem: filesystem, sourceRoot: sourceRoot,
                sourceCommonDirectory: sourceRoot.appending(path: ".git"),
                sourceGitDirectory: sourceRoot.appending(path: ".git"),
                capturedHead: .init(
                    commitOID: try fixture.blobID("HEAD", at: fixture.source),
                    treeOID: try fixture.blobID("HEAD^{tree}", at: fixture.source)),
                copyRules: .init(ignoredPaths: .copyMatching([try GitPathPattern("tools/")])), resetsToStart: true))

        // Assert
        let keptLeaves = Set(result.filesystem.leafBatches.flatMap(\.leaves).map(\.relativePath))
        #expect(keptLeaves == [".gitignore", "README.md", "src/main.c", "tools/a.txt", "tools/out.o"])
        #expect(!result.filesystem.directories.map(\.relativePath).contains("cache"))
        #expect(result.ignoredIncludedPatterns == ["tools/"])
        // Ignored exclusions only: `cache/` with its file, and `build.o`; untracked work in progress is not counted.
        #expect(result.ignoredExcludedCount == 3)
    }
}
