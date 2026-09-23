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

    @Test("worktree fork wire enum raw values stay stable")
    func worktreeForkWireEnumRawValuesStayStable() {
        #expect(
            GitWorktreeFilesystemEntryKind.allCases.map(\.rawValue) == [
                "directory", "regularFile", "symbolicLink", "fifo", "unixSocket", "characterDevice",
                "blockDevice", "unknown",
            ])
        #expect(GitWorktreeMaterializationSkipReason.allCases.map(\.rawValue) == ["unixSocketNotReproducible"])
        #expect(
            GitWorktreeMetadataAttribute.allCases.map(\.rawValue) == [
                "ownerUser", "ownerGroup", "setUserIDBit", "setGroupIDBit",
            ])
        #expect(
            GitWorktreeMetadataNormalizationReason.allCases.map(\.rawValue) == [
                "ownershipNotAssignable", "clearedByCopyOnWriteClone",
            ])
        #expect(
            GitWorktreeForkRejectionReason.allCases.map(\.rawValue) == [
                "clientCapabilityUnavailable", "unsupportedOperatingSystem", "sourceFilesystemNotAPFS",
                "destinationFilesystemNotAPFS", "crossDevice", "cloneCapabilityUnavailable",
                "administrativeStoreOnDifferentDevice", "sourceNotWorktreeRoot", "sourceHeadUnavailable",
                "invalidDestinationPath", "destinationParentMissing", "destinationExists", "overlappingRoots",
                "linkedWorktreeNameInUse", "invalidBranchName", "branchNotFound", "branchAlreadyExists",
                "branchNotAtCapturedHead", "branchCheckedOut", "fileProviderManagedLocation", "datalessContent",
            ])
        #expect(
            GitWorktreeForkSourceRaceReason.allCases.map(\.rawValue) == [
                "entryMissing", "entryKindChanged", "entryIdentityChanged", "containmentEscape",
            ])
        #expect(
            GitWorktreeForkEntryFailureReason.allCases.map(\.rawValue) == [
                "unsupportedEntryKind", "datalessFile", "datalessPolicyUnavailable", "strictCloneFailed",
                "entryCreationFailed", "metadataNotReproducible", "unreadableEntry", "unresolvableGitAdministration",
            ])
        #expect(
            GitWorktreeForkValidationFailureReason.allCases.map(\.rawValue) == [
                "worktreeRegistrationInvalid", "headMismatch", "branchMismatch", "entryCountMismatch",
                "entryKindMismatch", "hardLinkGroupBroken", "indexTreeMismatch", "indexStatNotRefreshed",
                "sparseStateMismatch", "submoduleStateMismatch", "nestedRepositoryUnusable",
                "sourceAdministrationReference", "transactionArtifactRemains",
            ])
        #expect(
            GitWorktreeForkResidueKind.allCases.map(\.rawValue) == [
                "destinationContent", "linkedWorktreeAdministration", "nestedAdministration", "createdBranch",
                "temporaryArtifact",
            ])
    }
}
