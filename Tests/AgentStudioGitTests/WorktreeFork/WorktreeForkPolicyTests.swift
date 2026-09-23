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
