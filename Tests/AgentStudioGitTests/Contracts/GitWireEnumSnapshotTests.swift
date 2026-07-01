import AgentStudioGit
import Testing

@Suite("Git wire enum snapshots")
struct GitWireEnumSnapshotTests {
    @Test("wire enum raw values stay stable")
    func wireEnumRawValuesStayStable() {
        #expect(GitHeadKind.allCases.map(\.rawValue) == ["branch", "detached", "unborn"])
        #expect(
            GitStatusState.allCases.map(\.rawValue) == [
                "added",
                "deleted",
                "modified",
                "renamed",
                "copied",
                "typeChanged",
                "unmerged",
            ])
        #expect(GitDiffTargetKind.allCases.map(\.rawValue) == ["commit", "head", "index", "workingTree"])
        #expect(
            GitDiffChangeKind.allCases.map(\.rawValue) == [
                "added",
                "copied",
                "deleted",
                "modified",
                "renamed",
                "typeChanged",
                "unmerged",
            ])
        #expect(GitRemotePromptPolicy.allCases.map(\.rawValue) == ["noninteractive", "trustedInteractive"])
        #expect(GitRemoteProtocol.allCases.map(\.rawValue) == ["file", "git", "http", "https", "ssh"])
        #expect(GitProcessOutputStream.allCases.map(\.rawValue) == ["stdout", "stderr"])
        #expect(GitTrackedPathKind.allCases.map(\.rawValue) == ["file", "symlink", "submodule"])
        #expect(GitWorktreePruneRefusalReason.allCases.map(\.rawValue) == ["liveWorktree"])
        #expect(
            GitWorktreeRemovalRefusalReason.allCases.map(\.rawValue) == [
                "mainWorktree",
                "dirtyTrackedChanges",
                "stagedChanges",
                "untrackedFiles",
                "locked",
                "ambiguousPath",
                "pathMismatch",
            ])
    }
}
