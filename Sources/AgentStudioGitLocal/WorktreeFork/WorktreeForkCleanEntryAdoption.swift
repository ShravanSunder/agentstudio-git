import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// The stat fields Git caches per index entry, at the index's own widths. Git's clean test compares these
/// against the working file; the fork uses the same comparison to prove a clone is byte-identical.
struct WorktreeForkObservedStat: Equatable, Hashable, Sendable {
    let deviceID: UInt32
    let inode: UInt32
    let size: UInt32
    let mtimeSeconds: Int32
    let mtimeNanoseconds: UInt32
    let ctimeSeconds: Int32
    let ctimeNanoseconds: UInt32
    /// Git's recorded mode: `100755` when the owner may execute, otherwise `100644`.
    let mode: UInt32

    init(
        deviceID: UInt32, inode: UInt32, size: UInt32, mtimeSeconds: Int32, mtimeNanoseconds: UInt32,
        ctimeSeconds: Int32, ctimeNanoseconds: UInt32, mode: UInt32
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.ctimeSeconds = ctimeSeconds
        self.ctimeNanoseconds = ctimeNanoseconds
        self.mode = mode
    }

    init(_ info: Darwin.stat) {
        deviceID = UInt32(truncatingIfNeeded: info.st_dev)
        inode = UInt32(truncatingIfNeeded: info.st_ino)
        size = UInt32(truncatingIfNeeded: info.st_size)
        mtimeSeconds = Int32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
        mtimeNanoseconds = UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
        ctimeSeconds = Int32(truncatingIfNeeded: info.st_ctimespec.tv_sec)
        ctimeNanoseconds = UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec)
        mode = info.st_mode & S_IXUSR != 0 ? 0o100755 : 0o100644
    }

    init(_ entry: git_index_entry) {
        deviceID = entry.dev
        inode = entry.ino
        size = entry.file_size
        mtimeSeconds = entry.mtime.seconds
        mtimeNanoseconds = entry.mtime.nanoseconds
        ctimeSeconds = entry.ctime.seconds
        ctimeNanoseconds = entry.ctime.nanoseconds
        mode = entry.mode
    }
}

struct WorktreeForkIndexTimestamp: Comparable, Sendable {
    let seconds: Int64
    let nanoseconds: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

struct WorktreeForkSourceIndexEntry: Equatable, Sendable {
    let objectID: String
    let mode: UInt32
    let stat: WorktreeForkObservedStat
}

/// Stage-0, non-skip-worktree, non-intent-to-add entries of a source index libgit2 could read, plus the
/// index file's own mtime for Git's racy-clean test. Evidence of cleanliness only; no stat is reused.
struct WorktreeForkSourceIndexSnapshot: Sendable {
    let modificationTime: WorktreeForkIndexTimestamp
    let entries: [String: WorktreeForkSourceIndexEntry]
}

/// Decides which destination index entries may take the clone's own `lstat` without hashing. Every
/// condition must hold; anything unproven goes through the `GIT_DIFF_UPDATE_INDEX` refresh. The validator
/// cannot detect a wrong adoption, so these conditions are the correctness boundary.
enum WorktreeForkCleanEntryAdoption {
    static func isAdoptable(
        path: String,
        capturedObjectID: String,
        capturedMode: UInt32,
        sourceIndex: WorktreeForkSourceIndexSnapshot,
        plannedStat: WorktreeForkObservedStat?,
        cloneVerified: Bool
    ) -> Bool {
        guard cloneVerified, let plannedStat, let source = sourceIndex.entries[path] else {
            return false
        }
        let cachedModification = WorktreeForkIndexTimestamp(
            seconds: Int64(source.stat.mtimeSeconds), nanoseconds: Int64(source.stat.mtimeNanoseconds))
        return source.objectID == capturedObjectID
            && source.mode == capturedMode
            && source.stat == plannedStat
            && cachedModification < sourceIndex.modificationTime
    }

    /// Reads the source index when libgit2 can open it; a sparse index or any unsupported extension yields
    /// nil, which sends every entry of that node through the refresh.
    static func captureSourceIndex(gitDirectory: URL) -> WorktreeForkSourceIndexSnapshot? {
        let indexPath = gitDirectory.appending(path: "index")
        guard case .success(let indexInfo) = WorktreeForkDescriptors.lstatPath(indexPath) else {
            return nil
        }
        var index: OpaquePointer?
        guard indexPath.path.withCString({ git_index_open(&index, $0) }) >= 0, let index else {
            return nil
        }
        defer { git_index_free(index) }
        let excludedFlags = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue | GIT_INDEX_ENTRY_INTENT_TO_ADD.rawValue)
        var entries: [String: WorktreeForkSourceIndexEntry] = [:]
        for position in 0..<git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee, let path = entry.path,
                git_index_entry_stage(&entry) == 0, entry.flags_extended & excludedFlags == 0
            else {
                continue
            }
            var oid = entry.id
            entries[String(cString: path)] = WorktreeForkSourceIndexEntry(
                objectID: oidString(&oid), mode: entry.mode, stat: WorktreeForkObservedStat(entry))
        }
        return WorktreeForkSourceIndexSnapshot(
            modificationTime: WorktreeForkIndexTimestamp(
                seconds: Int64(indexInfo.st_mtimespec.tv_sec), nanoseconds: Int64(indexInfo.st_mtimespec.tv_nsec)),
            entries: entries
        )
    }
}

/// Per-node inputs for adoption: the node's source index snapshot and the materializer's evidence, keyed by
/// fork-root-relative path (a node's index paths are prefixed with the node path to look them up).
struct WorktreeForkAdoptionContext: Sendable {
    let sourceIndex: WorktreeForkSourceIndexSnapshot
    let nodePrefix: String
    let plannedStats: [String: WorktreeForkObservedStat]
    let verifiedClonePaths: Set<String>
}

/// Internal proof seam: receives each node's index evidence (root is ""). Production ignores it.
struct WorktreeForkIndexObserver: Sendable {
    static let production = Self { _, _ in }

    let observe: @Sendable (_ nodeRelativePath: String, _ evidence: WorktreeForkIndexRefreshEvidence) -> Void
}
