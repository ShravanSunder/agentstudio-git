import AgentStudioGit
import Foundation
import Testing

@Suite("Git wire enum snapshots")
struct GitWireEnumSnapshotTests {
    @Test("Git lock resources and errors keep explicit stable wire tags")
    func gitLockResourcesAndErrorsKeepExplicitStableWireTags() throws {
        let worktreePath = URL(fileURLWithPath: "/tmp/worktree")
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "/tmp/repo/.git/index.lock"),
            resource: .index(worktreePath: worktreePath)
        )

        try expectWireSnapshot(
            lockFact.resource,
            expected: #"{"index":{"worktreePath":"file:\/\/\/tmp\/worktree"}}"#
        )
        try expectWireSnapshot(
            GitLockResource.reference(name: "refs/heads/topic"),
            expected: #"{"reference":{"name":"refs\/heads\/topic"}}"#
        )
        try expectWireSnapshot(GitLockResource.packedRefs, expected: #"{"packedRefs":{}}"#)
        try expectWireSnapshot(GitLockResource.config, expected: #"{"config":{}}"#)
        try expectWireSnapshot(
            lockFact,
            expected:
                #"{"path":"file:\/\/\/tmp\/repo\/.git\/index.lock","resource":{"index":{"worktreePath":"file:\/\/\/tmp\/worktree"}}}"#
        )
        try expectWireSnapshot(
            GitDataPlaneError.lockHeld(lockFact),
            expected:
                #"{"lockHeld":{"fact":{"path":"file:\/\/\/tmp\/repo\/.git\/index.lock","resource":{"index":{"worktreePath":"file:\/\/\/tmp\/worktree"}}}}}"#
        )
        try expectWireSnapshot(
            GitDataPlaneError.lockUnidentified(.packedRefs),
            expected: #"{"lockUnidentified":{"resource":{"packedRefs":{}}}}"#
        )
        try expectWireSnapshot(GitDataPlaneError.permissionDenied(path: nil), expected: #"{"permissionDenied":{}}"#)
    }

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
        #expect(
            GitIntegrationUnknownReason.allCases.map(\.rawValue) == [
                "branchNotFound", "noMergeBase", "multipleMergeBases", "historyLimitReached",
                "incompleteHistory", "missingObjects", "readFailed",
            ])
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

private func wireSnapshot<TPayload: Encodable>(_ payload: TPayload) throws -> String {
    let encodedPayload = try JSONEncoder().encode(payload)
    let jsonValue = try JSONSerialization.jsonObject(with: encodedPayload)
    let sortedData = try JSONSerialization.data(withJSONObject: jsonValue, options: [.sortedKeys])
    return try #require(String(data: sortedData, encoding: .utf8))
}

private func expectWireSnapshot<TPayload: Encodable>(_ payload: TPayload, expected: String) throws {
    let actual = try wireSnapshot(payload)
    #expect(actual == expected, "actual wire snapshot: \(actual)")
}
