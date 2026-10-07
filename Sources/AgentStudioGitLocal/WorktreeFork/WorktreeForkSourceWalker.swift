import AgentStudioGitContracts
import Darwin
import Foundation

/// Iterative, descriptor-relative classification of the source tree. Every source-root child is planned
/// except the exact root `.git` entry; inclusion does not depend on Git tracked or ignored status. A nested
/// `.git` entry is recorded, not entered; once the planner knows it belongs to an independent repository,
/// `walkPlainGitEntries` plans it like any other content.
struct WorktreeForkSourceWalker: Sendable {
    static let leafBatchSize = 256

    let cancellation: WorktreeForkCancellation

    /// Walks under the thread-scoped deny-materialization policy: listing a dataless directory without it
    /// would download that listing.
    func walk(sourceRootDescriptor: Int32) throws(GitWorktreeForkError) -> WorktreeForkFilesystemPlan {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: ".") { () throws(GitWorktreeForkError) in
            var walked = WorktreeForkWalkedEntries()
            try walkDirectories(from: [""], rootDescriptor: sourceRootDescriptor, plainContent: false, into: &walked)
            return walked.filesystemPlan()
        }
    }

    /// Plans each given nested `.git` entry, and everything beneath it, as ordinary content: an independent
    /// repository's administration is copied byte for byte, never opened. Inside, a `.git` name is ordinary
    /// and nothing is a Git directory candidate. Merge the result with `addingPlainGitEntries`.
    func walkPlainGitEntries(
        _ gitEntryPaths: [String],
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkFilesystemPlan {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: ".") { () throws(GitWorktreeForkError) in
            var walked = WorktreeForkWalkedEntries()
            for gitEntryPath in gitEntryPaths {
                try cancellation.throwIfCancelled()
                let (parentPath, name) = WorktreeForkDescriptors.splitParent(gitEntryPath)
                let info = try entryInfo(rootDescriptor, parentPath: parentPath, name: name)
                var leaves: [WorktreeForkPlannedLeaf] = []
                var childDirectories: [String] = []
                try plan(
                    WorktreeForkDirectoryEntry(name: name, info: info), relativePath: gitEntryPath,
                    leaves: &leaves, childDirectories: &childDirectories, into: &walked)
                walked.leafBatches.append(contentsOf: batches(of: leaves, in: parentPath))
                try walkDirectories(
                    from: childDirectories, rootDescriptor: rootDescriptor, plainContent: true, into: &walked)
            }
            return walked.filesystemPlan()
        }
    }

    /// Depth-first from `startPaths`, parent before child. `plainContent` plans `.git` names like any other
    /// entry and records no Git directory candidates.
    private func walkDirectories(
        from startPaths: [String],
        rootDescriptor: Int32,
        plainContent: Bool,
        into walked: inout WorktreeForkWalkedEntries
    ) throws(GitWorktreeForkError) {
        var pendingDirectories = Array(startPaths.reversed())
        while let directoryRelativePath = pendingDirectories.popLast() {
            try cancellation.throwIfCancelled()
            let listing = try listDirectory(rootDescriptor, relativePath: directoryRelativePath)
            walked.directories.append(
                WorktreeForkPlannedDirectory(relativePath: directoryRelativePath, identity: listing.identity))
            if !plainContent, !directoryRelativePath.isEmpty, Self.looksLikeGitDirectory(listing.entries) {
                walked.gitDirectoryCandidatePaths.append(directoryRelativePath)
            }

            var leaves: [WorktreeForkPlannedLeaf] = []
            var childDirectories: [String] = []
            for entry in listing.entries {
                let relativePath = WorktreeForkDescriptors.joined(directoryRelativePath, entry.name)
                if !plainContent, entry.name == ".git" {
                    if !directoryRelativePath.isEmpty {
                        walked.nestedGitEntryPaths.append(relativePath)
                    }
                    continue
                }
                try plan(
                    entry, relativePath: relativePath, leaves: &leaves, childDirectories: &childDirectories,
                    into: &walked)
            }
            walked.leafBatches.append(contentsOf: batches(of: leaves, in: directoryRelativePath))
            pendingDirectories.append(contentsOf: childDirectories.reversed())
        }
    }

    private func plan(
        _ entry: WorktreeForkDirectoryEntry,
        relativePath: String,
        leaves: inout [WorktreeForkPlannedLeaf],
        childDirectories: inout [String],
        into walked: inout WorktreeForkWalkedEntries
    ) throws(GitWorktreeForkError) {
        let identity = WorktreeForkEntryIdentity(entry.info)
        let kind = WorktreeForkEntryKind(mode: entry.info.st_mode)
        switch WorktreeForkEntryPolicy.disposition(for: kind, flags: entry.info.st_flags) {
        case .descend:
            childDirectories.append(relativePath)
        case .rejectDataless:
            throw .rejected(reason: .datalessContent)
        case .realize(.regularFile):
            if entry.info.st_nlink > 1 {
                walked.regularFilePathsByIdentity[identity, default: []].append(relativePath)
            }
            leaves.append(leaf(entry, relativePath, .regularFile, identity))
        case .realize(let leafKind):
            leaves.append(leaf(entry, relativePath, leafKind, identity))
        case .skip(let kind, let reason):
            walked.skippedEntries.append(
                GitWorktreeMaterializationSkippedEntry(relativePath: relativePath, kind: kind, reason: reason))
        case .unsupported:
            throw .entryFailed(relativePath: relativePath, reason: .unsupportedEntryKind, errorNumber: nil)
        }
    }

    /// The lstat of one entry the planner already saw, read through its parent beneath the root.
    private func entryInfo(
        _ rootDescriptor: Int32,
        parentPath: String,
        name: String
    ) throws(GitWorktreeForkError) -> Darwin.stat {
        let parent: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: parentPath) {
        case .success(let opened):
            parent = opened
        case .failure(let failure):
            throw Self.sourceFailure(relativePath: parentPath, errorNumber: failure.code)
        }
        defer { close(parent) }
        let relativePath = WorktreeForkDescriptors.joined(parentPath, name)
        switch WorktreeForkDescriptors.statEntry(in: parent, name: name) {
        case .success(let info):
            return info
        case .failure(let failure):
            throw Self.sourceFailure(relativePath: relativePath, errorNumber: failure.code)
        }
    }

    /// Git's own shape test for a Git directory: a `HEAD` entry beside `objects/` and `refs/` directories.
    /// Bare caches and separate Git directories inside ordinary content have this shape without a `.git` name.
    private static func looksLikeGitDirectory(_ entries: [WorktreeForkDirectoryEntry]) -> Bool {
        var kindByName: [String: WorktreeForkEntryKind] = [:]
        for entry in entries where ["HEAD", "objects", "refs"].contains(entry.name) {
            kindByName[entry.name] = WorktreeForkEntryKind(mode: entry.info.st_mode)
        }
        guard let headKind = kindByName["HEAD"], headKind != .directory else {
            return false
        }
        return kindByName["objects"] == .directory && kindByName["refs"] == .directory
    }

    private func listDirectory(
        _ rootDescriptor: Int32,
        relativePath: String
    ) throws(GitWorktreeForkError) -> WorktreeForkDirectoryListing {
        let descriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: relativePath) {
        case .success(let opened):
            descriptor = opened
        case .failure(let failure):
            throw Self.sourceFailure(relativePath: relativePath, errorNumber: failure.code)
        }
        guard let directoryStream = fdopendir(descriptor) else {
            let failureCode = errno
            close(descriptor)
            throw .entryFailed(relativePath: relativePath, reason: .unreadableEntry, errorNumber: failureCode)
        }
        defer { closedir(directoryStream) }

        let identity: WorktreeForkEntryIdentity
        switch WorktreeForkDescriptors.statDescriptor(descriptor) {
        case .success(let info):
            identity = WorktreeForkEntryIdentity(info)
        case .failure(let failure):
            throw .entryFailed(relativePath: relativePath, reason: .unreadableEntry, errorNumber: failure.code)
        }

        var entries: [WorktreeForkDirectoryEntry] = []
        while let rawEntry = readdir(directoryStream) {
            // APFS stores names as UTF-8, so a name that does not decode is not a name this walker can plan.
            guard
                let name = WorktreeForkDescriptors.entryName(rawEntry)
            else {
                throw .entryFailed(relativePath: relativePath, reason: .unreadableEntry, errorNumber: EILSEQ)
            }
            guard name != ".", name != ".." else {
                continue
            }
            switch WorktreeForkDescriptors.statEntry(in: descriptor, name: name) {
            case .success(let info):
                entries.append(WorktreeForkDirectoryEntry(name: name, info: info))
            case .failure(let failure) where failure.code == ENOENT:
                // Removed after enumeration: the mixed-time contract allows its absence.
                continue
            case .failure(let failure):
                throw .entryFailed(
                    relativePath: WorktreeForkDescriptors.joined(relativePath, name),
                    reason: .unreadableEntry,
                    errorNumber: failure.code
                )
            }
        }
        return WorktreeForkDirectoryListing(
            identity: identity,
            entries: entries.sorted { $0.name < $1.name }
        )
    }

    private func leaf(
        _ entry: WorktreeForkDirectoryEntry,
        _ relativePath: String,
        _ kind: WorktreeForkLeafKind,
        _ identity: WorktreeForkEntryIdentity
    ) -> WorktreeForkPlannedLeaf {
        WorktreeForkPlannedLeaf(
            name: entry.name,
            relativePath: relativePath,
            kind: kind,
            identity: identity,
            plannedStat: WorktreeForkObservedStat(entry.info)
        )
    }

    private func batches(
        of leaves: [WorktreeForkPlannedLeaf],
        in directoryRelativePath: String
    ) -> [WorktreeForkLeafBatch] {
        stride(from: 0, to: leaves.count, by: Self.leafBatchSize).map { start in
            WorktreeForkLeafBatch(
                directoryRelativePath: directoryRelativePath,
                leaves: Array(leaves[start..<min(start + Self.leafBatchSize, leaves.count)])
            )
        }
    }

    /// A planned directory that cannot be opened beneath the root is either a race or an escape attempt.
    static func sourceFailure(relativePath: String, errorNumber: Int32) -> GitWorktreeForkError {
        switch errorNumber {
        case ENOENT:
            .sourceChanged(relativePath: relativePath, reason: .entryMissing)
        case ELOOP, ENOTDIR:
            .sourceChanged(relativePath: relativePath, reason: .containmentEscape)
        default:
            .entryFailed(relativePath: relativePath, reason: .unreadableEntry, errorNumber: errorNumber)
        }
    }
}

/// The explicit per-kind safety rule. Sockets name live endpoints and are skipped with a report; devices
/// and unknown kinds fail rather than being silently omitted or transformed; a dataless (not-downloaded)
/// file or directory is rejected before mutation, because strict CoW never authorizes a download.
enum WorktreeForkEntryPolicy {
    enum Disposition: Equatable {
        case descend
        case realize(WorktreeForkLeafKind)
        case skip(GitWorktreeFilesystemEntryKind, GitWorktreeMaterializationSkipReason)
        case rejectDataless
        case unsupported
    }

    static func disposition(for kind: WorktreeForkEntryKind, flags: UInt32) -> Disposition {
        if kind == .directory || kind == .regularFile, flags & UInt32(SF_DATALESS) != 0 {
            return .rejectDataless
        }
        return switch kind {
        case .directory: .descend
        case .regularFile: .realize(.regularFile)
        case .symbolicLink: .realize(.symbolicLink)
        case .fifo: .realize(.fifo)
        case .unixSocket: .skip(.unixSocket, .unixSocketNotReproducible)
        case .characterDevice, .blockDevice, .unknown: .unsupported
        }
    }
}

/// What one or more walks found, before hard-link secondaries are separated from clone leaves.
private struct WorktreeForkWalkedEntries {
    var directories: [WorktreeForkPlannedDirectory] = []
    var leafBatches: [WorktreeForkLeafBatch] = []
    var skippedEntries: [GitWorktreeMaterializationSkippedEntry] = []
    var nestedGitEntryPaths: [String] = []
    var gitDirectoryCandidatePaths: [String] = []
    var regularFilePathsByIdentity: [WorktreeForkEntryIdentity: [String]] = [:]

    func filesystemPlan() -> WorktreeForkFilesystemPlan {
        let hardLinkGroups = hardLinkGroups()
        let secondaryPaths = Set(hardLinkGroups.flatMap(\.secondaryRelativePaths))
        let primaryLeafBatches =
            secondaryPaths.isEmpty
            ? leafBatches
            : leafBatches.compactMap { batch -> WorktreeForkLeafBatch? in
                let leaves = batch.leaves.filter { !secondaryPaths.contains($0.relativePath) }
                return leaves.isEmpty
                    ? nil : WorktreeForkLeafBatch(directoryRelativePath: batch.directoryRelativePath, leaves: leaves)
            }
        return WorktreeForkFilesystemPlan(
            directories: directories,
            leafBatches: primaryLeafBatches,
            hardLinkGroups: hardLinkGroups,
            skippedEntries: skippedEntries.sorted { $0.relativePath < $1.relativePath },
            nestedGitEntryPaths: nestedGitEntryPaths.sorted(),
            gitDirectoryCandidatePaths: gitDirectoryCandidatePaths.sorted()
        )
    }

    private func hardLinkGroups() -> [WorktreeForkHardLinkGroup] {
        regularFilePathsByIdentity.compactMap { identity, paths -> WorktreeForkHardLinkGroup? in
            let sortedPaths = paths.sorted()
            guard sortedPaths.count > 1, let primary = sortedPaths.first else {
                return nil
            }
            return WorktreeForkHardLinkGroup(
                identity: identity,
                primaryRelativePath: primary,
                secondaryRelativePaths: Array(sortedPaths.dropFirst())
            )
        }
        .sorted { $0.primaryRelativePath < $1.primaryRelativePath }
    }
}

private struct WorktreeForkDirectoryEntry {
    let name: String
    let info: Darwin.stat
}

private struct WorktreeForkDirectoryListing {
    let identity: WorktreeForkEntryIdentity
    let entries: [WorktreeForkDirectoryEntry]
}
