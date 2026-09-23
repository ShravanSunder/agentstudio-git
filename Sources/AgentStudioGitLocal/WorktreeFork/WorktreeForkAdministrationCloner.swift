import AgentStudioGitContracts
import Darwin
import Foundation

/// Strict-CoW copy of the portable part of a Git administration tree (objects, refs, packed refs, shallow
/// data, configuration, hooks, info). Source indexes, locks, live process endpoints, and in-progress
/// operation state are never copied: the destination index is rebuilt from captured `HEAD`, and an active
/// merge, rebase, cherry-pick, revert, bisect, or sequencer run is not inherited.
struct WorktreeForkAdministrationCloner: Sendable {
    /// Excluded wherever they appear at the administration root.
    static let excludedTopLevelNames: Set<String> = [
        "index", "gitdir", "commondir", "worktrees", "modules",
        "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "MERGE_RR", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD",
        "REBASE_HEAD", "rebase-merge", "rebase-apply", "sequencer",
        "BISECT_LOG", "BISECT_START", "BISECT_TERMS", "BISECT_EXPECTED_REV", "BISECT_ANCESTORS_OK",
        "BISECT_NAMES", "BISECT_RUN", "BISECT_HEAD",
    ]
    /// Rewritten to destination-owned mirrors after the copy.
    static let alternatesRelativePath = "objects/info/alternates"

    let reportPath: String
    /// Link text for every symlink planning classified, keyed by administration-relative path. A symlink
    /// that is not listed (appeared after planning, or inside a mirrored store) fails the transaction.
    var symlinkTargets: [String: String] = [:]

    static func isExcluded(_ relativePath: String) -> Bool {
        let name = WorktreeForkDescriptors.splitParent(relativePath).name
        if name.hasSuffix(".lock") || relativePath == alternatesRelativePath {
            return true
        }
        return !relativePath.contains("/") && excludedTopLevelNames.contains(relativePath)
    }

    /// Copies `source` into the not-yet-existing `destination`, creating missing parent directories.
    /// `created` receives the identity of the root the transaction itself created with an exclusive
    /// `mkdir`, so rollback can prove ownership before deleting anything.
    func cloneTree(
        from source: URL,
        to destination: URL,
        created: (WorktreeForkEntryIdentity) -> Void = { _ in }
    ) throws(GitWorktreeForkError) {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
            () throws(GitWorktreeForkError) in
            try cloneTreeWithMaterializationDenied(from: source, to: destination, created: created)
        }
    }

    private func cloneTreeWithMaterializationDenied(
        from source: URL,
        to destination: URL,
        created: (WorktreeForkEntryIdentity) -> Void
    ) throws(GitWorktreeForkError) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        let sourceRoot = try descriptor(WorktreeForkDescriptors.openRoot(atCanonicalPath: source))
        defer { close(sourceRoot) }
        guard destination.path.withCString({ mkdir($0, 0o755) }) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        if case .success(let info) = WorktreeForkDescriptors.lstatPath(destination) {
            created(WorktreeForkEntryIdentity(info))
        }
        let destinationRoot = try descriptor(WorktreeForkDescriptors.openRoot(atCanonicalPath: destination))
        defer { close(destinationRoot) }
        try cloneDirectory(sourceRoot, destinationRoot, relativePath: "")
    }

    private func cloneDirectory(
        _ source: Int32,
        _ destination: Int32,
        relativePath: String
    ) throws(GitWorktreeForkError) {
        let listingDescriptor = dup(source)
        guard listingDescriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        guard let stream = fdopendir(listingDescriptor) else {
            let failureCode = errno
            close(listingDescriptor)
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failureCode)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let rawEntry = readdir(stream) {
            if let name = withUnsafeBytes(
                of: rawEntry.pointee.d_name,
                { bytes in
                    String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
                }), name != ".", name != ".."
            {
                names.append(name)
            }
        }
        for name in names.sorted() {
            let childPath = WorktreeForkDescriptors.joined(relativePath, name)
            guard !Self.isExcluded(childPath),
                case .success(let info) = WorktreeForkDescriptors.statEntry(in: source, name: name)
            else {
                continue
            }
            try cloneEntry(name, info: info, source, destination, childPath: childPath)
        }
    }

    private func cloneEntry(
        _ name: String,
        info: Darwin.stat,
        _ source: Int32,
        _ destination: Int32,
        childPath: String
    ) throws(GitWorktreeForkError) {
        switch WorktreeForkEntryKind(mode: info.st_mode) {
        case .directory:
            guard name.withCString({ mkdirat(destination, $0, (info.st_mode & 0o7777) | S_IRWXU) }) == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
            }
            let sourceChild = try descriptor(
                WorktreeForkDescriptors.openDirectory(beneath: source, relativePath: name))
            defer { close(sourceChild) }
            let destinationChild = try descriptor(
                WorktreeForkDescriptors.openDirectory(beneath: destination, relativePath: name))
            defer { close(destinationChild) }
            try cloneDirectory(sourceChild, destinationChild, relativePath: childPath)
        case .regularFile:
            let file = name.withCString { openat(source, $0, WorktreeForkLeafWorker.leafOpenFlags) }
            guard file >= 0 else {
                throw .sourceChanged(relativePath: reportPath, reason: .entryMissing)
            }
            defer { close(file) }
            guard name.withCString({ fclonefileat(file, destination, $0, WorktreeForkLeafWorker.cloneFlags) }) == 0
            else {
                throw .entryFailed(relativePath: reportPath, reason: .strictCloneFailed, errorNumber: errno)
            }
        case .symbolicLink:
            guard let target = symlinkTargets[childPath] else {
                throw .sourceChanged(relativePath: reportPath, reason: .entryIdentityChanged)
            }
            let created = target.withCString { targetPointer in
                name.withCString { symlinkat(targetPointer, destination, $0) }
            }
            guard created == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
            }
        case .fifo, .unixSocket, .characterDevice, .blockDevice, .unknown:
            // Live process endpoints (for example the fsmonitor socket) are runtime state, not repository data.
            return
        }
    }

    private func descriptor(_ result: Result<Int32, WorktreeForkErrno>) throws(GitWorktreeForkError) -> Int32 {
        switch result {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }
}
