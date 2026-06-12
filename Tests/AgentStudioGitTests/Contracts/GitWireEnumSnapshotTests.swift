import AgentStudioGit
import Testing

@Suite("Git wire enum snapshots")
struct GitWireEnumSnapshotTests {
    @Test("wire enum raw values stay stable")
    func wireEnumRawValuesStayStable() {
        #expect(GitStatusState.added.rawValue == "added")
        #expect(GitStatusState.modified.rawValue == "modified")
        #expect(GitStatusState.renamed.rawValue == "renamed")
        #expect(GitDiffChangeKind.deleted.rawValue == "deleted")
        #expect(GitDiffTargetKind.workingTree.rawValue == "workingTree")
        #expect(GitRemotePromptPolicy.noninteractive.rawValue == "noninteractive")
    }
}
