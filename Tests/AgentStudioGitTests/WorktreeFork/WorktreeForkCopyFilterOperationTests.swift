import AgentStudioGit
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
}
