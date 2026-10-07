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
    /// The source worktree's private administration; the common directory itself for a main worktree.
    let sourceGitDirectory: URL
    /// Canonical directory that `~/` names in configuration paths, captured once from the host facts.
    let homeDirectory: URL
    let capturedHead: WorktreeForkCapturedHead
    let branchIdentity: WorktreeForkBranchIdentity
    let materialization: GitWorktreeForkMaterialization
    let filesystem: WorktreeForkFilesystemPlan
    let ignoredIncludedPatterns: [String]
    let ignoredExcludedCount: Int
    let nestedWorktreesSkipped: [String]
    let changesOnly: WorktreeForkChangesOnlyPlan?
    let gitTopology: WorktreeForkGitTopology
}

struct WorktreeForkChangesOnlyPlan: Sendable {
    let entries: [WorktreeForkChangesOnlyEntry]
    let largeFileRestorations: [WorktreeForkLargeFileRestoration]
    let trackedChangeCount: Int
    let untrackedFileCount: Int
    let repositoryState: WorktreeForkRepositoryStateSnapshot
}

struct WorktreeForkChangesOnlyEntry: Equatable, Sendable {
    let relativePath: String
    let kind: WorktreeForkChangesOnlyEntryKind
    let identity: WorktreeForkEntryIdentity?
    let mode: UInt32
    let size: Int64
    let contentSHA256: String?
    let symbolicLinkText: String?
    let tracked: Bool
    let shouldOverlay: Bool
}

enum WorktreeForkChangesOnlyEntryKind: Equatable, Sendable {
    case absent
    case directory
    case regularFile
    case symbolicLink
}

struct WorktreeForkLargeFileRestoration: Equatable, Sendable {
    let relativePath: String
    let identity: WorktreeForkEntryIdentity
    let mode: UInt32
    let size: Int64
    let contentSHA256: String
}

struct WorktreeForkRepositoryStateSnapshot: Equatable, Sendable {
    let headCommitOID: String
    let indexFingerprint: String
    let operationState: Int32
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
    /// The stat observed while planning; a clone whose source descriptor still matches it is byte-identical
    /// to what the source index vouched for.
    let plannedStat: WorktreeForkObservedStat
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
    /// Relative paths of `.git` entries below the root that are not ordinary entries. The walker records every
    /// one; once Git-topology classification has added an independent repository's entry as ordinary content
    /// (`addingPlainGitEntries`), only submodules remain, realized by re-homing.
    let nestedGitEntryPaths: [String]
    /// Directories shaped like a Git directory but not named `.git`. They are copied as ordinary entries;
    /// Git-topology classification decides which are repositories whose copied pointers need re-homing.
    let gitDirectoryCandidatePaths: [String]

    static let empty = Self(
        directories: [], leafBatches: [], hardLinkGroups: [], skippedEntries: [], nestedGitEntryPaths: [],
        gitDirectoryCandidatePaths: [])

    var createdDirectoryCount: Int {
        max(0, directories.count - 1)
    }

    static func isPath(_ path: String, within subtree: String) -> Bool {
        path == subtree || (path.utf8.starts(with: subtree.utf8) && path.utf8.dropFirst(subtree.utf8.count).first == 47)
    }

    /// Every path in the walk, before the walker separates hard-link secondaries from clone leaves.
    var allPlannedLeaves: [WorktreeForkPlannedLeaf] {
        let primaries = Dictionary(uniqueKeysWithValues: leafBatches.flatMap(\.leaves).map { ($0.relativePath, $0) })
        return Array(primaries.values)
            + hardLinkGroups.flatMap { group -> [WorktreeForkPlannedLeaf] in
                guard let template = primaries[group.primaryRelativePath] else { return [] }
                return group.secondaryRelativePaths.map { path in
                    Self.relocatedLeaf(template, to: path)
                }
            }
    }

    private static func relocatedLeaf(_ template: WorktreeForkPlannedLeaf, to path: String) -> WorktreeForkPlannedLeaf {
        WorktreeForkPlannedLeaf(
            name: WorktreeForkDescriptors.splitParent(path).name, relativePath: path,
            kind: template.kind, identity: template.identity, plannedStat: template.plannedStat)
    }

    /// Excludes subtrees once. Hard-link groups retain their kept members and elect a kept member as
    /// the clone source when necessary; exclusion never changes inode sharing among retained paths.
    func excludingSubtrees(_ subtrees: [String]) throws(GitWorktreeForkError) -> Self {
        guard !subtrees.isEmpty else { return self }
        let excluded = Set(subtrees.map { $0[...] })
        func isExcluded(_ path: String) -> Bool {
            var candidate = path[...]
            while true {
                if excluded.contains(candidate) { return true }
                guard let slash = candidate.lastIndex(of: "/") else { return false }
                candidate = candidate[..<slash]
            }
        }
        let primaryLeaves = Dictionary(
            uniqueKeysWithValues: leafBatches.flatMap(\.leaves).map { ($0.relativePath, $0) })
        var keptGroups: [WorktreeForkHardLinkGroup] = []
        var electedLeaves: [WorktreeForkPlannedLeaf] = []
        for group in hardLinkGroups {
            let kept = ([group.primaryRelativePath] + group.secondaryRelativePaths).filter { !isExcluded($0) }
            guard let primary = kept.first else { continue }
            if primary != group.primaryRelativePath {
                guard let template = primaryLeaves[group.primaryRelativePath] else {
                    throw .validationFailed(reason: .hardLinkGroupBroken, relativePath: primary)
                }
                electedLeaves.append(Self.relocatedLeaf(template, to: primary))
            }
            if kept.count > 1 {
                keptGroups.append(
                    WorktreeForkHardLinkGroup(
                        identity: group.identity,
                        primaryRelativePath: primary, secondaryRelativePaths: Array(kept.dropFirst())))
            }
        }
        var batches = leafBatches.compactMap { batch -> WorktreeForkLeafBatch? in
            let leaves = batch.leaves.filter { !isExcluded($0.relativePath) }
            return leaves.isEmpty
                ? nil : WorktreeForkLeafBatch(directoryRelativePath: batch.directoryRelativePath, leaves: leaves)
        }
        batches += electedLeaves.map { leaf in
            WorktreeForkLeafBatch(
                directoryRelativePath: WorktreeForkDescriptors.splitParent(leaf.relativePath).parent,
                leaves: [leaf])
        }
        return Self(
            directories: directories.filter { !isExcluded($0.relativePath) }, leafBatches: batches,
            hardLinkGroups: keptGroups, skippedEntries: skippedEntries.filter { !isExcluded($0.relativePath) },
            nestedGitEntryPaths: nestedGitEntryPaths.filter { !isExcluded($0) },
            gitDirectoryCandidatePaths: gitDirectoryCandidatePaths.filter { !isExcluded($0) })
    }

    /// Adds `walked`, the plain walk of independent repositories' `.git` entries (`walkPlainGitEntries`), which
    /// then stop counting as nested Git entries. Regular files sharing one inode across both walks form one
    /// hard-link group. Each side's earliest path keeps its leaf, so the merged primary, the earliest of all,
    /// always has one.
    func addingPlainGitEntries(_ gitEntryPaths: [String], walked: Self) -> Self {
        guard !gitEntryPaths.isEmpty else { return self }
        let walkedFiles = walked.allPlannedLeaves.filter { $0.kind == .regularFile }
        let walkedIdentities = Set(walkedFiles.map(\.identity))
        var pathsByIdentity: [WorktreeForkEntryIdentity: [String]] = [:]
        for leaf in allPlannedLeaves where leaf.kind == .regularFile && walkedIdentities.contains(leaf.identity) {
            pathsByIdentity[leaf.identity, default: []].append(leaf.relativePath)
        }
        for leaf in walkedFiles where pathsByIdentity[leaf.identity] != nil {
            pathsByIdentity[leaf.identity]?.append(leaf.relativePath)
        }
        let regrouped = pathsByIdentity.compactMap { identity, paths -> WorktreeForkHardLinkGroup? in
            let sortedPaths = paths.sorted()
            guard let primary = sortedPaths.first else { return nil }
            return WorktreeForkHardLinkGroup(
                identity: identity, primaryRelativePath: primary, secondaryRelativePaths: Array(sortedPaths.dropFirst())
            )
        }
        let secondaries = Set(regrouped.flatMap(\.secondaryRelativePaths))
        let plainEntries = Set(gitEntryPaths)
        return Self(
            directories: directories + walked.directories,
            leafBatches: (leafBatches + walked.leafBatches).compactMap { batch -> WorktreeForkLeafBatch? in
                let leaves = batch.leaves.filter { !secondaries.contains($0.relativePath) }
                return leaves.isEmpty
                    ? nil : WorktreeForkLeafBatch(directoryRelativePath: batch.directoryRelativePath, leaves: leaves)
            },
            hardLinkGroups: ((hardLinkGroups + walked.hardLinkGroups).filter { pathsByIdentity[$0.identity] == nil }
                + regrouped).sorted { $0.primaryRelativePath < $1.primaryRelativePath },
            skippedEntries: (skippedEntries + walked.skippedEntries).sorted { $0.relativePath < $1.relativePath },
            nestedGitEntryPaths: nestedGitEntryPaths.filter { !plainEntries.contains($0) },
            gitDirectoryCandidatePaths: gitDirectoryCandidatePaths)
    }

    func leafCount(of kind: WorktreeForkLeafKind) -> Int {
        leafBatches.reduce(0) { total, batch in total + batch.leaves.filter { $0.kind == kind }.count }
    }

    var hardLinkSecondaryCount: Int {
        hardLinkGroups.reduce(0) { $0 + $1.secondaryRelativePaths.count }
    }
}
