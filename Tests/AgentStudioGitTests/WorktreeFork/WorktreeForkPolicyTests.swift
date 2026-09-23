import AgentStudioGit
import Darwin
import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("Worktree fork policy")
struct WorktreeForkPolicyTests {
    private static let apfs = WorktreeForkVolumeFacts(
        fileSystemTypeName: "apfs", deviceID: 7, supportsFileCloning: true, isFileProviderManaged: false)

    @Test("eligibility rejects each unsupported host or volume with its stable reason")
    func eligibilityRejectsEachUnsupportedHostOrVolume() {
        // Arrange
        let cases: [(WorktreeForkEligibilityFacts, GitWorktreeForkRejectionReason?)] = [
            (facts(), nil),
            (facts(operatingSystem: 15), .unsupportedOperatingSystem),
            (facts(source: volume(type: "hfs")), .sourceFilesystemNotAPFS),
            (facts(destination: volume(type: "msdos")), .destinationFilesystemNotAPFS),
            (facts(destination: volume(device: 9)), .crossDevice),
            (facts(source: volume(cloning: false), destination: volume(cloning: false)), .cloneCapabilityUnavailable),
            (facts(stores: [volume(device: 9)]), .administrativeStoreOnDifferentDevice),
            (facts(source: volume(fileProvider: true)), .fileProviderManagedLocation),
            (facts(destination: volume(fileProvider: true)), .fileProviderManagedLocation),
        ]

        for (input, expected) in cases {
            // Act
            let rejection = WorktreeForkEligibility.rejection(for: input)

            // Assert
            #expect(rejection == expected)
        }
    }

    @Test("entry policy descends, realizes, skips sockets, and refuses devices and unknown kinds")
    func entryPolicyDecidesEveryKind() {
        // Arrange
        let expectations: [(mode_t, WorktreeForkEntryPolicy.Disposition)] = [
            (S_IFDIR, .descend),
            (S_IFREG, .realize(.regularFile)),
            (S_IFLNK, .realize(.symbolicLink)),
            (S_IFIFO, .realize(.fifo)),
            (S_IFSOCK, .skip(.unixSocket, .unixSocketNotReproducible)),
            (S_IFCHR, .unsupported),
            (S_IFBLK, .unsupported),
            (S_IFWHT, .unsupported),
        ]

        for (mode, expected) in expectations {
            // Act
            let disposition = WorktreeForkEntryPolicy.disposition(
                for: WorktreeForkEntryKind(mode: mode | 0o644), flags: 0)

            // Assert
            #expect(disposition == expected)
        }
    }

    @Test("dataless regular files and directories are rejected before the walker reads or descends")
    func datalessFilesAndDirectoriesAreRejected() {
        // Arrange
        let dataless = UInt32(SF_DATALESS)

        // Act / Assert
        #expect(WorktreeForkEntryPolicy.disposition(for: .directory, flags: dataless) == .rejectDataless)
        #expect(WorktreeForkEntryPolicy.disposition(for: .regularFile, flags: dataless) == .rejectDataless)
        #expect(WorktreeForkEntryPolicy.disposition(for: .symbolicLink, flags: dataless) == .realize(.symbolicLink))
        #expect(WorktreeForkEntryPolicy.disposition(for: .directory, flags: UInt32(UF_HIDDEN)) == .descend)
    }

    @Test("a denied-materialization scope holds the policy for its body and restores it after a failure")
    func deniedMaterializationScopeRestoresAfterFailure() async throws {
        // Arrange
        let (observations, continuation) = AsyncStream.makeStream(of: DatalessPolicyObservation.self)

        // Act
        let worker = Thread {
            let before = WorktreeForkDatalessPolicy.currentThreadPolicy()
            var during: Int32 = -1
            var failed = false
            do throws(GitWorktreeForkError) {
                try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: ".") {
                    () throws(GitWorktreeForkError) in
                    during = WorktreeForkDatalessPolicy.currentThreadPolicy()
                    throw GitWorktreeForkError.cancelled
                }
            } catch {
                failed = error == .cancelled
            }
            continuation.yield(
                DatalessPolicyObservation(
                    established: failed,
                    before: before,
                    during: during,
                    after: WorktreeForkDatalessPolicy.currentThreadPolicy()
                ))
            continuation.finish()
        }
        worker.start()
        var iterator = observations.makeAsyncIterator()
        let observation = try #require(await iterator.next())

        // Assert
        #expect(observation.established)
        #expect(observation.during == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(observation.after == observation.before)
    }

    @Test("ownership and setuid loss are reported normalization while permission loss fails")
    func ownershipAndSetuidLossAreNormalizationWhilePermissionLossFails() throws {
        // Arrange
        var source = Darwin.stat()
        source.st_mode = S_IFREG | S_ISUID | S_ISGID | 0o755
        source.st_uid = 0
        source.st_gid = 0
        var cloned = source
        cloned.st_mode = S_IFREG | 0o755
        cloned.st_uid = 501
        cloned.st_gid = 20
        var lostExecute = source
        lostExecute.st_mode = S_IFREG | S_ISUID | S_ISGID | 0o644

        // Act
        let normalized = try WorktreeForkEntryMetadata.normalization(
            source: source, destination: cloned, relativePath: "bin/tool")

        // Assert
        #expect(normalized.map(\.attribute) == [.ownerUser, .ownerGroup, .setUserIDBit, .setGroupIDBit])
        #expect(
            normalized.map(\.reason) == [
                .ownershipNotAssignable, .ownershipNotAssignable, .clearedByCopyOnWriteClone,
                .clearedByCopyOnWriteClone,
            ])
        #expect(
            throws: GitWorktreeForkError.entryFailed(
                relativePath: "bin/tool", reason: .metadataNotReproducible, errorNumber: nil)
        ) {
            try WorktreeForkEntryMetadata.normalization(
                source: source, destination: lostExecute, relativePath: "bin/tool")
        }
    }

    @Test("the dataless denial is established, verified, and restored on the worker thread")
    func datalessDenialIsEstablishedAndRestoredOnWorkerThread() async throws {
        // Arrange
        let (observations, continuation) = AsyncStream.makeStream(of: DatalessPolicyObservation.self)

        // Act
        let worker = Thread {
            let before = WorktreeForkDatalessPolicy.currentThreadPolicy()
            let established = WorktreeForkDatalessPolicy.denyMaterializationOnCurrentThread()
            let during = WorktreeForkDatalessPolicy.currentThreadPolicy()
            if case .success(let prior) = established {
                WorktreeForkDatalessPolicy.restore(prior)
            }
            let after = WorktreeForkDatalessPolicy.currentThreadPolicy()
            continuation.yield(
                DatalessPolicyObservation(
                    established: (try? established.get()) != nil, before: before, during: during, after: after))
            continuation.finish()
        }
        worker.start()
        var iterator = observations.makeAsyncIterator()
        let observation = try #require(await iterator.next())

        // Assert
        #expect(observation.established)
        #expect(observation.during == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(observation.after == observation.before)
    }

    @Test("rollback never deletes a destination whose identity no longer matches the journal")
    func rollbackNeverDeletesAReplacedDestination() throws {
        // Arrange
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-git-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "fork")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = try #require(GitWorktreeForkFileProbe.info(destination))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: root.appending(path: "occupant"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var journal = WorktreeForkRollbackJournal(
            commonDirectory: root.appending(path: "missing.git"), destinationRoot: destination, runtime: .shared)
        journal.record(.destinationRoot(path: destination, identity: WorktreeForkEntryIdentity(original)))
        let replacementIsDistinct = GitWorktreeForkFileProbe.info(destination)?.st_ino != original.st_ino

        // Act
        let residue = journal.rollback(faults: .production)

        // Assert
        try #require(replacementIsDistinct)
        #expect(residue == [GitWorktreeForkResidue(kind: .destinationContent, location: ".")])
        #expect(GitWorktreeForkFileProbe.exists(destination))
    }

    @Test("submodule names that could leave the modules directory are unsafe, as Git treats them")
    func submoduleNamesThatCouldLeaveModulesAreUnsafe() {
        // Arrange
        let safe = ["library", "deps/library", "spaced name", "a.b/c-d"]
        let unsafe = ["", ".", "..", "../x", "a/../../x", "a/./b", "a//b", "/abs", "a/", "..\\x", "a\\..\\b"]

        // Act / Assert
        for name in safe {
            #expect(WorktreeForkSubmoduleRegistrations.isSafeName(name), "\(name)")
        }
        for name in unsafe {
            #expect(!WorktreeForkSubmoduleRegistrations.isSafeName(name), "\(name)")
        }
    }

    @Test("rollback never deletes nested administration the transaction did not confirm creating")
    func rollbackNeverDeletesUnconfirmedNestedAdministration() throws {
        // Arrange
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-git-journal-nested-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appending(path: "modules/foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: foreign.appending(path: "owner.txt"))
        let emptyForeign = root.appending(path: "modules/empty-foreign")
        try FileManager.default.createDirectory(at: emptyForeign, withIntermediateDirectories: true)
        let replaced = root.appending(path: "modules/replaced")
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        let originalIdentity = WorktreeForkEntryIdentity(try #require(GitWorktreeForkFileProbe.info(replaced)))
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createDirectory(at: root.appending(path: "occupant"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: replaced.appending(path: "owner.txt"))
        var journal = WorktreeForkRollbackJournal(
            commonDirectory: root.appending(path: "missing.git"), destinationRoot: root.appending(path: "fork"),
            runtime: .shared)
        journal.record(.nestedAdministration(path: foreign, reportLocation: "modules/foreign", identity: nil))
        journal.record(
            .nestedAdministration(path: emptyForeign, reportLocation: "modules/empty-foreign", identity: nil))
        journal.record(
            .nestedAdministration(path: replaced, reportLocation: "modules/replaced", identity: originalIdentity))

        // Act
        let residue = journal.rollback(faults: .production)

        // Assert
        #expect(
            residue == [
                GitWorktreeForkResidue(kind: .nestedAdministration, location: "modules/replaced"),
                GitWorktreeForkResidue(kind: .nestedAdministration, location: "modules/empty-foreign"),
                GitWorktreeForkResidue(kind: .nestedAdministration, location: "modules/foreign"),
            ])
        #expect(GitWorktreeForkFileProbe.exists(emptyForeign))
        #expect(GitWorktreeForkFileProbe.exists(foreign.appending(path: "owner.txt")))
        #expect(GitWorktreeForkFileProbe.exists(replaced.appending(path: "owner.txt")))
    }

    @Test("administrative symlinks are classified internal or external, and mirrored stores may not contain any")
    func administrativeSymlinksAreClassified() throws {
        // Arrange
        let root = try #require(
            realpath(FileManager.default.temporaryDirectory.path, nil).map { pointer in
                defer { free(pointer) }
                return URL(fileURLWithPath: String(cString: pointer))
            }
        ).appending(path: "agentstudio-git-admin-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let administration = root.appending(path: "admin")
        let store = root.appending(path: "store")
        try FileManager.default.createDirectory(
            at: administration.appending(path: "hooks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: administration.appending(path: "hooks-link").path, withDestinationPath: "hooks")
        try FileManager.default.createSymbolicLink(
            at: administration.appending(path: "objects"), withDestinationURL: store)
        try FileManager.default.createSymbolicLink(
            atPath: administration.appending(path: "index.lock").path, withDestinationPath: "/etc")

        // Act
        let classified = try WorktreeForkAdministrativeSymlinks.classify(
            administrationRoot: administration, reportPath: "node/.git")
        try FileManager.default.createSymbolicLink(
            atPath: store.appending(path: "escape").path, withDestinationPath: "/etc")

        // Assert
        #expect(classified["hooks-link"] == .internalTarget(relativeToAdministration: "hooks"))
        guard case .externalStore(let mirroredStore) = classified["objects"] else {
            Issue.record("objects must classify as an external store")
            return
        }
        #expect(mirroredStore.path == store.path)
        #expect(classified.count == 2)
        try FileManager.default.createDirectory(at: store.appending(path: "pack"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: store.appending(path: "info-link").path, withDestinationPath: "pack")
        let rejected = GitWorktreeForkError.entryFailed(
            relativePath: "node/.git", reason: .unresolvableGitAdministration, errorNumber: nil)
        #expect(throws: rejected) {
            try WorktreeForkAdministrativeSymlinks.storeSymlinkTargets(in: store, reportPath: "node/.git")
        }
        try FileManager.default.removeItem(at: store.appending(path: "escape"))
        #expect(
            try WorktreeForkAdministrativeSymlinks.storeSymlinkTargets(in: store, reportPath: "node/.git")
                == ["info-link": "pack"])
        try FileManager.default.createSymbolicLink(
            atPath: store.appending(path: "dangling").path, withDestinationPath: "missing")
        #expect(throws: rejected) {
            try WorktreeForkAdministrativeSymlinks.storeSymlinkTargets(in: store, reportPath: "node/.git")
        }
    }

    @Test("ineligible hosts and volumes are rejected through the client before any mutation")
    func ineligibleHostsAndVolumesAreRejectedBeforeMutation() async throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-fork-eligibility")
        defer { fixture.remove() }
        let sourcePath = try #require(GitWorktreeForkFileProbe.info(fixture.source)).st_dev
        let providers: [(WorktreeForkHostFactsProvider, GitWorktreeForkRejectionReason)] = [
            (
                WorktreeForkHostFactsProvider(operatingSystemMajorVersion: { 15 }, volumeFacts: { _ in Self.apfs }),
                .unsupportedOperatingSystem
            ),
            (
                WorktreeForkHostFactsProvider(
                    operatingSystemMajorVersion: { 26 },
                    volumeFacts: { path in
                        let device = path.path.hasSuffix("/repo") ? sourcePath : sourcePath + 1
                        return WorktreeForkVolumeFacts(
                            fileSystemTypeName: "apfs", deviceID: device, supportsFileCloning: true,
                            isFileProviderManaged: false)
                    }
                ),
                .crossDevice
            ),
        ]

        for (provider, expected) in providers {
            let client = LibGit2AgentStudioGitLocalClient(
                worktreeForkWriter: LibGit2WorktreeForkWriter(hostFacts: provider))

            // Act
            let failure: GitWorktreeForkError?
            do {
                _ = try await client.forkWorktree(fixture.request())
                failure = nil
            } catch {
                failure = error
            }

            // Assert
            #expect(failure == .rejected(reason: expected))
            #expect(!GitWorktreeForkFileProbe.exists(fixture.destination()))
            #expect(try fixture.branchNames() == ["refs/heads/main"])
        }
    }

    private func facts(
        operatingSystem: Int = 26,
        source: WorktreeForkVolumeFacts = apfs,
        destination: WorktreeForkVolumeFacts = apfs,
        stores: [WorktreeForkVolumeFacts] = []
    ) -> WorktreeForkEligibilityFacts {
        WorktreeForkEligibilityFacts(
            operatingSystemMajorVersion: operatingSystem,
            source: source,
            destinationParent: destination,
            mirroredAdministrativeStores: stores
        )
    }

    private func volume(
        type: String = "apfs",
        device: Int32 = 7,
        cloning: Bool = true,
        fileProvider: Bool = false
    ) -> WorktreeForkVolumeFacts {
        WorktreeForkVolumeFacts(
            fileSystemTypeName: type, deviceID: device, supportsFileCloning: cloning,
            isFileProviderManaged: fileProvider)
    }
}

private struct DatalessPolicyObservation: Sendable {
    let established: Bool
    let before: Int32
    let during: Int32
    let after: Int32
}
