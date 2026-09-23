import AgentStudioGitContracts
import Foundation

/// The immutable, pre-mutation description of one fork. Workers, the re-homer, and the validator consume
/// it; none of them rediscovers policy. It is not a snapshot: entries created after their parent was
/// enumerated are absent, and entries are re-checked against their planned identity when realized.
struct WorktreeForkPlan: Sendable {
    let sourceRoot: URL
    let destinationRoot: URL
    let destinationRequestPath: URL
    let worktreeName: String
    let commonDirectory: URL
    let capturedHead: WorktreeForkCapturedHead
    let branchIdentity: WorktreeForkBranchIdentity
    let filesystem: WorktreeForkFilesystemPlan
    let gitTopology: WorktreeForkGitTopology
}

struct WorktreeForkCapturedHead: Equatable, Sendable {
    let commitOID: String
    let treeOID: String
}

/// The validated destination identity; every variant resolves to the captured `HEAD`.
enum WorktreeForkBranchIdentity: Equatable, Sendable {
    case existingBranch(referenceName: String)
    case newBranch(referenceName: String)
    case detached

    var referenceName: String? {
        switch self {
        case .existingBranch(let referenceName), .newBranch(let referenceName):
            referenceName
        case .detached:
            nil
        }
    }
}

enum WorktreeForkLeafKind: Equatable, Sendable {
    case regularFile
    case symbolicLink
    case fifo
}

struct WorktreeForkPlannedLeaf: Equatable, Sendable {
    let name: String
    let relativePath: String
    let kind: WorktreeForkLeafKind
    let identity: WorktreeForkEntryIdentity
}

/// Leaves of one directory, chunked so a huge directory still spreads across workers.
struct WorktreeForkLeafBatch: Equatable, Sendable {
    let directoryRelativePath: String
    let leaves: [WorktreeForkPlannedLeaf]
}

struct WorktreeForkPlannedDirectory: Equatable, Sendable {
    /// Empty for the worktree root, which `git_worktree_add` creates.
    let relativePath: String
    let identity: WorktreeForkEntryIdentity
}

/// Paths inside the source tree that share one regular-file inode. The primary is cloned once; the
/// remaining paths become destination hard links to that clone.
struct WorktreeForkHardLinkGroup: Equatable, Sendable {
    let identity: WorktreeForkEntryIdentity
    let primaryRelativePath: String
    let secondaryRelativePaths: [String]
}

struct WorktreeForkFilesystemPlan: Sendable {
    /// Parent-before-child, root first. Metadata finalization walks this in reverse.
    let directories: [WorktreeForkPlannedDirectory]
    let leafBatches: [WorktreeForkLeafBatch]
    let hardLinkGroups: [WorktreeForkHardLinkGroup]
    let skippedEntries: [GitWorktreeMaterializationSkippedEntry]
    /// Relative paths of `.git` entries below the root. They are never copied as ordinary entries;
    /// Git-topology classification decides how each is realized.
    let nestedGitEntryPaths: [String]

    var createdDirectoryCount: Int {
        directories.count - 1
    }

    func leafCount(of kind: WorktreeForkLeafKind) -> Int {
        leafBatches.reduce(0) { total, batch in total + batch.leaves.filter { $0.kind == kind }.count }
    }

    var hardLinkSecondaryCount: Int {
        hardLinkGroups.reduce(0) { $0 + $1.secondaryRelativePaths.count }
    }
}
