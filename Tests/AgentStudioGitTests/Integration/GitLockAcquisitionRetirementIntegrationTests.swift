import AgentStudioGitContracts
import AgentStudioGitLockSupport
import Darwin
import Foundation
import Testing
import os

@testable import AgentStudioGitLocal

@Suite("Git lock acquisition retirement integration", .serialized)
struct GitLockAcquisitionRetirementIntegrationTests {
    @Test("fork ownership survives inaccessible then readable observations without an absence")
    func forkOwnershipSurvivesUnreadableToReadableObservation() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-lock-retirement-readable")
        defer { fixture.remove() }
        let lockFact = Self.forkIndexLockFact(fixture)
        let observationCount = OSAllocatedUnfairLock(initialState: 0)
        let acquiredIdentity = OSAllocatedUnfairLock(initialState: Optional<WorktreeForkEntryIdentity>.none)
        let tracker = WorktreeForkLockTracker(pathObserver: { _ -> WorktreeForkLockTracker.ObservedPath in
            let count = observationCount.withLock { value in
                value += 1
                return value
            }
            switch count {
            case 1:
                return .absent
            case 2, 3:
                return .inaccessible
            default:
                return acquiredIdentity.withLock { $0 }.map(WorktreeForkLockTracker.ObservedPath.present)
                    ?? .inaccessible
            }
        })
        tracker.beginAttempt(for: [lockFact])
        try Data("acquired lock\n".utf8).write(to: lockFact.path)
        let acquiredInfo = try #require(GitWorktreeForkFileProbe.info(lockFact.path))
        acquiredIdentity.withLock {
            $0 = WorktreeForkEntryIdentity(acquiredInfo)
        }

        // Act
        tracker.recordAcquisition(of: lockFact)
        let inaccessibleResidue = tracker.ownedResidue()
        let readableResidue = tracker.ownedResidue()

        // Assert
        #expect(inaccessibleResidue == [lockFact])
        #expect(readableResidue == [lockFact])
    }

    @Test("fork absence retires unknown acquisition before a foreign file appears")
    func forkAbsenceRetiresUnknownAcquisition() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-lock-retirement-foreign")
        defer { fixture.remove() }
        let lockFact = Self.forkIndexLockFact(fixture)
        let observationCount = OSAllocatedUnfairLock(initialState: 0)
        let foreignIdentity = OSAllocatedUnfairLock(initialState: Optional<WorktreeForkEntryIdentity>.none)
        let tracker = WorktreeForkLockTracker(pathObserver: { _ -> WorktreeForkLockTracker.ObservedPath in
            let count = observationCount.withLock { value in
                value += 1
                return value
            }
            switch count {
            case 1:
                return .absent
            case 2:
                return .inaccessible
            case 3:
                return .absent
            default:
                return foreignIdentity.withLock { $0 }.map(WorktreeForkLockTracker.ObservedPath.present)
                    ?? .inaccessible
            }
        })
        tracker.beginAttempt(for: [lockFact])
        try Data("acquired lock before observed release\n".utf8).write(to: lockFact.path)
        tracker.recordAcquisition(of: lockFact)
        try FileManager.default.removeItem(at: lockFact.path)

        // Act
        let residueAfterAbsence = tracker.ownedResidue()
        let foreignBytes = Data("foreign replacement lock\n".utf8)
        try foreignBytes.write(to: lockFact.path)
        let foreignInfo = try #require(GitWorktreeForkFileProbe.info(lockFact.path))
        foreignIdentity.withLock {
            $0 = WorktreeForkEntryIdentity(foreignInfo)
        }
        let residueAfterForeignReplacement = tracker.ownedResidue()
        let activeCandidates = tracker.activeLocks()

        // Assert
        #expect(residueAfterAbsence.isEmpty)
        #expect(residueAfterForeignReplacement.isEmpty)
        #expect(activeCandidates == [lockFact])
        #expect(try Data(contentsOf: lockFact.path) == foreignBytes)
    }

    @Test("fork acquisition-time absence does not own a later file")
    func forkAcquisitionObservedAbsentDoesNotClaimLaterFile() throws {
        // Arrange
        let fixture = try GitWorktreeForkFixture.make(prefix: "agentstudio-git-lock-retirement-acquire-absent")
        defer { fixture.remove() }
        let lockFact = Self.forkIndexLockFact(fixture)
        let observationCount = OSAllocatedUnfairLock(initialState: 0)
        let laterIdentity = OSAllocatedUnfairLock(initialState: Optional<WorktreeForkEntryIdentity>.none)
        let tracker = WorktreeForkLockTracker(pathObserver: { _ -> WorktreeForkLockTracker.ObservedPath in
            let count = observationCount.withLock { value in
                value += 1
                return value
            }
            if count < 3 {
                return .absent
            }
            return laterIdentity.withLock { $0 }.map(WorktreeForkLockTracker.ObservedPath.present) ?? .inaccessible
        })
        tracker.beginAttempt(for: [lockFact])
        tracker.recordAcquisition(of: lockFact)
        let foreignBytes = Data("later unproven lock\n".utf8)
        try foreignBytes.write(to: lockFact.path)
        let laterInfo = try #require(GitWorktreeForkFileProbe.info(lockFact.path))
        laterIdentity.withLock {
            $0 = WorktreeForkEntryIdentity(laterInfo)
        }

        // Act
        let residue = tracker.ownedResidue()

        // Assert
        #expect(residue.isEmpty)
        #expect(tracker.activeLocks() == [lockFact])
        #expect(try Data(contentsOf: lockFact.path) == foreignBytes)
    }

    @Test("deletion absence retires unknown acquisition before a foreign file appears")
    func deletionAbsenceRetiresUnknownAcquisition() throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-lock-retirement")
        let referenceDirectory = fixture.gitDirectory.appending(path: "refs/heads")
        let lockPath = referenceDirectory.appending(path: "topic.lock").standardizedFileURL
        var originalDirectoryStatus = stat()
        let statResult = referenceDirectory.path.withCString { stat($0, &originalDirectoryStatus) }
        guard statResult == 0 else {
            fixture.remove()
            Issue.record("could not stat the local branch reference directory")
            return
        }
        let originalMode = originalDirectoryStatus.st_mode
        defer {
            _ = referenceDirectory.path.withCString { chmod($0, originalMode) }
            fixture.remove()
        }
        try Data("acquired lock with unreadable identity\n".utf8).write(to: lockPath)
        let unreadableMode = referenceDirectory.path.withCString { chmod($0, mode_t(0)) }
        guard unreadableMode == 0 else {
            Issue.record("could not make the reference directory unsearchable")
            return
        }
        var ledger = GitBranchDeletionLockLedger()
        ledger.recordSuccessfulAcquisition(at: lockPath)
        _ = referenceDirectory.path.withCString { chmod($0, originalMode) }
        try FileManager.default.removeItem(at: lockPath)

        // Act
        let residueAfterAbsence = ledger.residue(using: .live)
        let foreignBytes = Data("foreign replacement lock\n".utf8)
        try foreignBytes.write(to: lockPath)
        let residueAfterForeignReplacement = ledger.residue(using: .live)

        // Assert
        #expect(residueAfterAbsence.isEmpty)
        #expect(residueAfterForeignReplacement.isEmpty)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
    }

    @Test("deletion acquisition-time absence does not own a later file")
    func deletionAcquisitionObservedAbsentDoesNotClaimLaterFile() throws {
        // Arrange
        let fixture = try GitBranchDeletionFixture.make(prefix: "agentstudio-git-delete-acquire-absent")
        defer { fixture.remove() }
        let lockPath = fixture.gitDirectory.appending(path: "refs/heads/topic.lock").standardizedFileURL
        var ledger = GitBranchDeletionLockLedger()
        ledger.recordSuccessfulAcquisition(at: lockPath)
        let foreignBytes = Data("later unproven lock\n".utf8)
        try foreignBytes.write(to: lockPath)

        // Act
        let residue = ledger.residue(using: .live)

        // Assert
        #expect(residue.isEmpty)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
    }

    private static func forkIndexLockFact(_ fixture: GitWorktreeForkFixture) -> GitLockFact {
        let path = fixture.source.appending(path: ".git/index.lock").standardizedFileURL
        return GitLockFact(path: path, resource: .index(worktreePath: fixture.source))
    }
}
