import Darwin
import Testing

@testable import AgentStudioGitLocal

@Suite("Worktree fork clean-entry adoption")
struct WorktreeForkCleanEntryAdoptionTests {
    private static let blob = "1111111111111111111111111111111111111111"
    private static let stat = WorktreeForkObservedStat(
        deviceID: 16_777_230, inode: 42, size: 12, mtimeSeconds: 1_600_000_000, mtimeNanoseconds: 5,
        ctimeSeconds: 1_600_000_000, ctimeNanoseconds: 5, mode: 0o100644)

    @Test("an entry Git itself would call clean and whose clone matched the plan is adopted")
    func provablyCleanEntryIsAdopted() {
        #expect(decision() == true)
    }

    @Test(
        "each broken condition sends the entry to the refresh instead",
        arguments: [
            AdoptionBreak.sourceObjectDiffersFromCapturedTree,
            .sourceModeDiffersFromCapturedTree,
            .sourceStatDiffersFromPlannedStat,
            .racilyClean,
            .cloneNotVerified,
            .noSourceEntry,
            .noPlannedStat,
        ]
    )
    func eachBrokenConditionSendsTheEntryToRefresh(broken: AdoptionBreak) {
        #expect(decision(breaking: broken) == false)
    }

    @Test("observed stat canonicalizes the mode the way Git records it and truncates to index widths")
    func observedStatCanonicalizesModeLikeGit() {
        // Arrange
        var executable = Darwin.stat()
        executable.st_mode = S_IFREG | 0o775
        executable.st_ino = 0x1_0000_0002
        var plain = Darwin.stat()
        plain.st_mode = S_IFREG | 0o664

        // Act / Assert
        #expect(WorktreeForkObservedStat(executable).mode == 0o100755)
        #expect(WorktreeForkObservedStat(executable).inode == 2)
        #expect(WorktreeForkObservedStat(plain).mode == 0o100644)
    }

    private func decision(breaking broken: AdoptionBreak? = nil) -> Bool {
        var sourceStat = Self.stat
        var sourceObject = Self.blob
        var sourceMode: UInt32 = 0o100644
        var indexTime = WorktreeForkIndexTimestamp(seconds: 1_600_000_100, nanoseconds: 0)
        var plannedStat: WorktreeForkObservedStat? = Self.stat
        var cloneVerified = true
        var hasSourceEntry = true
        switch broken {
        case .sourceObjectDiffersFromCapturedTree: sourceObject = "2222222222222222222222222222222222222222"
        case .sourceModeDiffersFromCapturedTree: sourceMode = 0o100755
        case .sourceStatDiffersFromPlannedStat:
            sourceStat = WorktreeForkObservedStat(
                deviceID: Self.stat.deviceID, inode: Self.stat.inode, size: 13, mtimeSeconds: Self.stat.mtimeSeconds,
                mtimeNanoseconds: Self.stat.mtimeNanoseconds, ctimeSeconds: Self.stat.ctimeSeconds,
                ctimeNanoseconds: Self.stat.ctimeNanoseconds, mode: Self.stat.mode)
        case .racilyClean: indexTime = WorktreeForkIndexTimestamp(seconds: 1_600_000_000, nanoseconds: 5)
        case .cloneNotVerified: cloneVerified = false
        case .noSourceEntry: hasSourceEntry = false
        case .noPlannedStat: plannedStat = nil
        case nil: break
        }
        let snapshot = WorktreeForkSourceIndexSnapshot(
            modificationTime: indexTime,
            entries: hasSourceEntry
                ? [
                    "src/a.txt": WorktreeForkSourceIndexEntry(
                        objectID: sourceObject, mode: sourceMode, stat: sourceStat)
                ]
                : [:]
        )
        return WorktreeForkCleanEntryAdoption.isAdoptable(
            path: "src/a.txt",
            capturedObjectID: Self.blob,
            capturedMode: 0o100644,
            sourceIndex: snapshot,
            plannedStat: plannedStat,
            cloneVerified: cloneVerified
        )
    }
}

enum AdoptionBreak: CaseIterable, Sendable {
    case sourceObjectDiffersFromCapturedTree
    case sourceModeDiffersFromCapturedTree
    case sourceStatDiffersFromPlannedStat
    case racilyClean
    case cloneNotVerified
    case noSourceEntry
    case noPlannedStat
}
