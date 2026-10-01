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

    @Test("branch deletion payloads keep explicit stable wire tags")
    func branchDeletionPayloadsKeepExplicitStableWireTags() throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/repository")
        let packedReferencesLock = URL(fileURLWithPath: "/tmp/repo/.git/packed-refs.lock")
        let request = GitDeleteLocalBranchRequest(
            repositoryPath: repositoryPath,
            branchName: "topic",
            expectedCommit: "0123456789abcdef0123456789abcdef01234567"
        )
        let cleanup = GitBranchMetadataCleanup(
            configuration: .removed,
            reflog: .leftInPlace(.recreatedMeanwhile)
        )

        try expectWireSnapshot(
            request,
            expected:
                #"{"branchName":"topic","expectedCommit":"0123456789abcdef0123456789abcdef01234567","repositoryPath":"file:\/\/\/tmp\/repository"}"#
        )
        try expectWireSnapshot(
            cleanup,
            expected:
                #"{"configuration":{"kind":"removed"},"reflog":{"kind":"leftInPlace","reason":"recreatedMeanwhile"}}"#
        )
        try expectWireSnapshot(
            GitBranchRetentionReason.checkedOut(worktreePaths: [repositoryPath]),
            expected:
                #"{"kind":"checkedOut","worktreePaths":["file:\/\/\/tmp\/repository"]}"#
        )
        try expectWireSnapshot(
            GitDeleteLocalBranchErrorReason.checkoutUnreadable(worktreePath: repositoryPath),
            expected:
                #"{"kind":"checkoutUnreadable","worktreePath":"file:\/\/\/tmp\/repository"}"#
        )
        try expectWireSnapshot(
            GitDeleteLocalBranchResult.uncertain(
                error: .lockHeld(GitLockFact(path: packedReferencesLock, resource: .packedRefs)),
                lockResidue: [packedReferencesLock]
            ),
            expected:
                #"{"error":{"lockHeld":{"fact":{"path":"file:\/\/\/tmp\/repo\/.git\/packed-refs.lock","resource":{"packedRefs":{}}}}},"kind":"uncertain","lockResidue":["file:\/\/\/tmp\/repo\/.git\/packed-refs.lock"]}"#
        )
    }

    @Test("worktree removal effects keep stable tagged wire values")
    func worktreeRemovalEffectsKeepStableTaggedWireValues() throws {
        let worktreeID = GitWorktreeID(rawValue: "common:/tmp/repository/.git|worktree:/tmp/repository/linked")
        let effects = GitWorktreeRemovalEffects(
            administration: .removed,
            workingDirectory: .notRequested,
            failure: nil,
            lockResidue: []
        )

        let encodedPartialEffect = try JSONEncoder().encode(GitRemovalEffect.partial)
        #expect(String(data: encodedPartialEffect, encoding: .utf8) == #""partial""#)
        try expectWireSnapshot(
            GitWorktreeRemovalFailureKind.pruneFailed(code: -1, klass: 7),
            expected: #"{"code":-1,"kind":"pruneFailed","klass":7}"#
        )
        try expectWireSnapshot(
            GitWorktreeRemovalFailureKind.observationFailed,
            expected: #"{"kind":"observationFailed"}"#
        )
        try expectWireSnapshot(
            GitWorktreeRemovalFailureKind.removalIncomplete,
            expected: #"{"kind":"removalIncomplete"}"#
        )
        try expectWireSnapshot(
            effects,
            expected: #"{"administration":"removed","lockResidue":[],"workingDirectory":"notRequested"}"#
        )
        try expectWireSnapshot(
            GitWorktreeRemovalResult(removedWorktreeID: worktreeID, effects: effects),
            expected:
                #"{"effects":{"administration":"removed","lockResidue":[],"workingDirectory":"notRequested"},"removedWorktreeID":"common:\/tmp\/repository\/.git|worktree:\/tmp\/repository\/linked"}"#
        )
    }

    @Test("fetch requests and results keep optional branch and lock fields stable")
    func fetchRequestsAndResultsKeepStableWireValues() throws {
        let repositoryPath = URL(fileURLWithPath: "/tmp/repository")
        let remoteTrackingLock = URL(fileURLWithPath: "/tmp/repository/.git/refs/remotes/origin/main.lock")
        let wholeRemoteRequest = GitFetchRequest(repositoryPath: repositoryPath, remoteName: "origin")
        let branchRequest = GitFetchRequest(
            repositoryPath: repositoryPath,
            remoteName: "origin",
            branchName: "main"
        )
        let wholeRemoteResult = GitFetchResult(
            fetchedRemoteName: "origin",
            fetchedCommit: nil,
            lockResidue: nil
        )
        let observedCleanBranchResult = GitFetchResult(
            fetchedRemoteName: "origin",
            fetchedCommit: "0123456789abcdef0123456789abcdef01234567",
            lockResidue: []
        )
        let branchResult = GitFetchResult(
            fetchedRemoteName: "origin",
            fetchedCommit: "0123456789abcdef0123456789abcdef01234567",
            lockResidue: [remoteTrackingLock]
        )

        try expectWireSnapshot(
            wholeRemoteRequest,
            expected: #"{"remoteName":"origin","repositoryPath":"file:\/\/\/tmp\/repository"}"#
        )
        try expectWireSnapshot(
            branchRequest,
            expected: #"{"branchName":"main","remoteName":"origin","repositoryPath":"file:\/\/\/tmp\/repository"}"#
        )
        try expectWireSnapshot(
            wholeRemoteResult,
            expected: #"{"fetchedRemoteName":"origin"}"#
        )
        try expectWireSnapshot(
            observedCleanBranchResult,
            expected:
                #"{"fetchedCommit":"0123456789abcdef0123456789abcdef01234567","fetchedRemoteName":"origin","lockResidue":[]}"#
        )
        try expectWireSnapshot(
            branchResult,
            expected:
                #"{"fetchedCommit":"0123456789abcdef0123456789abcdef01234567","fetchedRemoteName":"origin","lockResidue":["file:\/\/\/tmp\/repository\/.git\/refs\/remotes\/origin\/main.lock"]}"#
        )
        #expect(
            try JSONDecoder().decode(GitFetchRequest.self, from: JSONEncoder().encode(branchRequest)) == branchRequest)
        #expect(
            try JSONDecoder().decode(GitFetchResult.self, from: JSONEncoder().encode(wholeRemoteResult))
                == wholeRemoteResult)
        #expect(
            try JSONDecoder().decode(GitFetchResult.self, from: JSONEncoder().encode(observedCleanBranchResult))
                == observedCleanBranchResult
        )
        #expect(try JSONDecoder().decode(GitFetchResult.self, from: JSONEncoder().encode(branchResult)) == branchResult)
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
            GitRemovalEffect.allCases.map(\.rawValue) == ["removed", "retained", "partial", "unknown", "notRequested"]
        )
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
                "contentChanged", "repositoryStateChanged",
            ])
        #expect(
            GitWorktreeForkMaterialization.allCases.map(\.rawValue) == ["copyOnWrite", "changesOnly"])
        #expect(
            GitWorktreeWorkingStateRefusalReason.allCases.map(\.rawValue) == [
                "conflicts", "operationInProgress", "submoduleChanged", "nestedRepository",
                "sparseOrSkipWorktree", "intentToAdd", "unsupportedEntryKind", "customFilter", "attributesChanged",
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
                "temporaryArtifact", "lockFile",
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
