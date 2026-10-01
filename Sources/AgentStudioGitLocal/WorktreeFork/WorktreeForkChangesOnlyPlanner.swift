import AgentStudioGitContracts
import CLibGit2Local
import CryptoKit
import Darwin
import Foundation

/// Captures the Git-visible overlay without walking ignored or unrelated source content.
struct WorktreeForkChangesOnlyPlanner: Sendable {
    let cancellation: WorktreeForkCancellation

    private static let materialSubmoduleChangeFlags =
        UInt32(GIT_SUBMODULE_STATUS_INDEX_ADDED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_INDEX_DELETED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_INDEX_MODIFIED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_ADDED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_DELETED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_MODIFIED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_INDEX_MODIFIED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_WD_MODIFIED.rawValue)
        | UInt32(GIT_SUBMODULE_STATUS_WD_UNTRACKED.rawValue)

    func plan(
        sourceRootDescriptor: Int32,
        sourceRoot: URL,
        capturedHead: WorktreeForkCapturedHead
    ) throws(GitWorktreeForkError) -> WorktreeForkChangesOnlyPlan {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: ".") { () throws(GitWorktreeForkError) in
            try planWhileMaterializationDenied(
                sourceRootDescriptor: sourceRootDescriptor,
                sourceRoot: sourceRoot,
                capturedHead: capturedHead
            )
        }
    }

    private func planWhileMaterializationDenied(
        sourceRootDescriptor: Int32,
        sourceRoot: URL,
        capturedHead: WorktreeForkCapturedHead
    ) throws(GitWorktreeForkError) -> WorktreeForkChangesOnlyPlan {
        try cancellation.throwIfCancelled()
        guard case .success(let rootInfo) = WorktreeForkDescriptors.statDescriptor(sourceRootDescriptor) else {
            throw .entryFailed(relativePath: ".", reason: .unreadableEntry, errorNumber: errno)
        }
        if rootInfo.st_flags & UInt32(SF_DATALESS) != 0 {
            throw .rejected(reason: .datalessContent)
        }
        let repository = try WorktreeForkGitHandles.openWorktree(sourceRoot)
        defer { git_repository_free(repository) }

        let gitSnapshotReader = WorktreeForkChangesOnlyGitSnapshotReader(cancellation: cancellation)
        let headEntries = try WorktreeForkGitHandles.treeEntries(capturedHead.treeOID, repository: repository)
        guard let gitDirectoryPointer = git_repository_path(repository) else {
            throw .rejected(reason: .sourceNotWorktreeRoot)
        }
        let gitDirectory = URL(fileURLWithPath: String(cString: gitDirectoryPointer))
        if try WorktreeForkSparseCapture.capture(
            repository: repository,
            gitDirectory: gitDirectory,
            treeEntries: headEntries
        ) != nil {
            throw refusal(.sparseOrSkipWorktree)
        }
        let indexPaths = try gitSnapshotReader.inspectIndex(repository)
        let initialRepositoryState = try gitSnapshotReader.repositoryState(
            repository, expectedHead: capturedHead.commitOID)
        if initialRepositoryState.operationState != GIT_REPOSITORY_STATE_NONE.rawValue {
            throw refusal(.operationInProgress)
        }
        let status = try gitSnapshotReader.statusPaths(repository)
        if let changedAttributesPath = status.changedAttributesPath {
            throw refusal(.attributesChanged, path: changedAttributesPath)
        }
        if let changedAttributesPath = try changedWorktreeAttributePath(
            repository: repository,
            headEntries: headEntries,
            sourceRootDescriptor: sourceRootDescriptor
        ) {
            throw refusal(.attributesChanged, path: changedAttributesPath)
        }
        let filters = try gitSnapshotReader.inspectHeadFilters(repository, headEntries: headEntries)
        return try makeChangesOnlyPlan(
            context: WorktreeForkChangesOnlyCaptureContext(
                repository: repository,
                sourceRootDescriptor: sourceRootDescriptor,
                headEntries: headEntries,
                indexPaths: indexPaths,
                status: status,
                filters: filters,
                repositoryState: initialRepositoryState
            ))
    }

    private func makeChangesOnlyPlan(
        context: WorktreeForkChangesOnlyCaptureContext
    ) throws(GitWorktreeForkError) -> WorktreeForkChangesOnlyPlan {
        var candidates = try carriedCandidatePaths(context)
        let largeFilePlan = try planLargeFileRestorations(context: context, candidates: &candidates)
        var trackedChangeCount = largeFilePlan.trackedChangeCount
        var entriesByPath: [String: WorktreeForkChangesOnlyEntry] = [:]
        var untrackedFileCount = 0
        for path in candidates.sorted() {
            try cancellation.throwIfCancelled()
            if context.status.conflictedPaths.contains(path) {
                throw refusal(.conflicts, path: path)
            }
            if context.status.unreadablePaths.contains(path) {
                throw refusal(.unsupportedEntryKind, path: path)
            }
            if Self.overlapsGitlink(path, entries: context.headEntries) {
                throw refusal(.submoduleChanged, path: path)
            }

            let node = try capture(path, rootDescriptor: context.sourceRootDescriptor)
            if node.kind == .directory,
                try containsNestedGitAdministration(path, rootDescriptor: context.sourceRootDescriptor)
            {
                throw refusal(.nestedRepository, path: path)
            }
            if node.kind == .fifo || node.kind == .unixSocket || node.kind == .characterDevice
                || node.kind == .blockDevice || node.kind == .unknown
            {
                throw refusal(.unsupportedEntryKind, path: path)
            }

            let headEntry = context.headEntries[path]
            let tracked = Self.isTracked(path, headEntries: context.headEntries, indexPaths: context.indexPaths)
            if node.kind == .absent, headEntry == nil {
                // A staged addition that has since been removed has no worktree overlay.
                continue
            }
            if try Self.matchesHead(node, entry: headEntry, repository: context.repository) {
                // Index-only changes undone on disk are not carried.
                continue
            }
            if node.kind == .regularFile,
                context.filters.largeFilePointers[path] != nil,
                largeFilePlan.smudgedPaths.contains(path)
            {
                continue
            }

            let entry = WorktreeForkChangesOnlyEntry(
                relativePath: path,
                kind: node.kind.publicKind,
                identity: node.identity,
                mode: node.mode,
                size: node.size,
                contentSHA256: node.contentSHA256,
                symbolicLinkText: node.symbolicLinkText,
                tracked: tracked,
                shouldOverlay: true
            )
            entriesByPath[path] = entry
            if tracked {
                trackedChangeCount += 1
            } else if node.kind == .regularFile || node.kind == .symbolicLink {
                untrackedFileCount += 1
            }
        }

        try addSourceParentDirectories(
            for: Array(entriesByPath.values),
            sourceRootDescriptor: context.sourceRootDescriptor,
            entriesByPath: &entriesByPath
        )
        return WorktreeForkChangesOnlyPlan(
            entries: entriesByPath.values.sorted {
                let leftDepth = $0.relativePath.split(separator: "/").count
                let rightDepth = $1.relativePath.split(separator: "/").count
                return leftDepth == rightDepth ? $0.relativePath < $1.relativePath : leftDepth < rightDepth
            },
            largeFileRestorations: largeFilePlan.restorations.sorted { $0.relativePath < $1.relativePath },
            trackedChangeCount: trackedChangeCount,
            untrackedFileCount: untrackedFileCount,
            repositoryState: context.repositoryState
        )
    }

    func capture(
        _ path: String,
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkChangesOnlySourceNode {
        guard Self.isSafeRelativePath(path) else {
            throw refusal(.unsupportedEntryKind, path: path)
        }
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        let parentDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: parentPath) {
        case .success(let descriptor):
            parentDescriptor = descriptor
        case .failure(let failure) where failure.code == ENOENT || failure.code == ENOTDIR:
            return .absent
        case .failure(let failure):
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: failure.code)
        }
        defer { close(parentDescriptor) }

        let info: Darwin.stat
        switch WorktreeForkDescriptors.statEntry(in: parentDescriptor, name: name) {
        case .success(let stat):
            info = stat
        case .failure(let failure) where failure.code == ENOENT:
            return .absent
        case .failure(let failure):
            throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: failure.code)
        }
        let identity = WorktreeForkEntryIdentity(info)
        let mode = UInt32(info.st_mode)
        let entryKind = WorktreeForkEntryKind(mode: info.st_mode)
        if entryKind == .directory || entryKind == .regularFile, info.st_flags & UInt32(SF_DATALESS) != 0 {
            throw .rejected(reason: .datalessContent)
        }
        switch entryKind {
        case .directory:
            return WorktreeForkChangesOnlySourceNode(
                kind: .directory, identity: identity, mode: mode, size: Int64(info.st_size),
                contentSHA256: nil, symbolicLinkText: nil)
        case .regularFile:
            let descriptor = name.withCString { openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else {
                throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: errno)
            }
            defer { close(descriptor) }
            guard case .success(let openedInfo) = WorktreeForkDescriptors.statDescriptor(descriptor),
                WorktreeForkEntryIdentity(openedInfo) == identity,
                WorktreeForkEntryKind(mode: openedInfo.st_mode) == .regularFile
            else {
                throw .sourceChanged(relativePath: path, reason: .entryIdentityChanged)
            }
            let hash = try hashDescriptor(descriptor, relativePath: path)
            return WorktreeForkChangesOnlySourceNode(
                kind: .regularFile, identity: identity, mode: mode, size: Int64(info.st_size),
                contentSHA256: hash, symbolicLinkText: nil)
        case .symbolicLink:
            var targetBuffer = [CChar](repeating: 0, count: max(2, Int(info.st_size) + 2))
            let targetSize = name.withCString { readlinkat(parentDescriptor, $0, &targetBuffer, targetBuffer.count) }
            guard targetSize >= 0,
                let linkText = String(
                    bytes: targetBuffer.prefix(targetSize).map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else {
                throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: errno)
            }
            return WorktreeForkChangesOnlySourceNode(
                kind: .symbolicLink, identity: identity, mode: mode, size: Int64(targetSize),
                contentSHA256: nil, symbolicLinkText: linkText)
        case .fifo:
            return .special(.fifo, identity: identity, mode: mode, size: Int64(info.st_size))
        case .unixSocket:
            return .special(.unixSocket, identity: identity, mode: mode, size: Int64(info.st_size))
        case .characterDevice:
            return .special(.characterDevice, identity: identity, mode: mode, size: Int64(info.st_size))
        case .blockDevice:
            return .special(.blockDevice, identity: identity, mode: mode, size: Int64(info.st_size))
        case .unknown:
            return .special(.unknown, identity: identity, mode: mode, size: Int64(info.st_size))
        }
    }

    private func addSourceParentDirectories(
        for entries: [WorktreeForkChangesOnlyEntry],
        sourceRootDescriptor: Int32,
        entriesByPath: inout [String: WorktreeForkChangesOnlyEntry]
    ) throws(GitWorktreeForkError) {
        for entry in entries where entry.shouldOverlay && entry.kind != .absent {
            let components = entry.relativePath.split(separator: "/").dropLast()
            var parentPath = ""
            for component in components {
                parentPath = WorktreeForkDescriptors.joined(parentPath, String(component))
                guard entriesByPath[parentPath] == nil else {
                    continue
                }
                let parentNode = try capture(parentPath, rootDescriptor: sourceRootDescriptor)
                guard parentNode.kind == .directory, let identity = parentNode.identity else {
                    throw refusal(.unsupportedEntryKind, path: parentPath)
                }
                entriesByPath[parentPath] = WorktreeForkChangesOnlyEntry(
                    relativePath: parentPath,
                    kind: .directory,
                    identity: identity,
                    mode: parentNode.mode,
                    size: parentNode.size,
                    contentSHA256: nil,
                    symbolicLinkText: nil,
                    tracked: false,
                    shouldOverlay: false
                )
            }
        }
    }

    private func rejectChangedSubmodules(
        in headEntries: [String: WorktreeForkTreeEntry],
        repository: OpaquePointer,
        snapshotReader: WorktreeForkChangesOnlyGitSnapshotReader,
        candidates: inout Set<String>
    ) throws(GitWorktreeForkError) {
        for (path, entry) in headEntries.sorted(by: { $0.key < $1.key })
        where entry.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) {
            try cancellation.throwIfCancelled()
            let status = try snapshotReader.submoduleStatus(path, repository: repository)
            if Self.submoduleHasMaterialChanges(status) {
                throw refusal(.submoduleChanged, path: path)
            }
            // A clean or uninitialized gitlink is not an overlay file. Its state was checked above.
            candidates.remove(path)
        }
    }

    private func carriedCandidatePaths(
        _ context: WorktreeForkChangesOnlyCaptureContext
    ) throws(GitWorktreeForkError) -> Set<String> {
        var candidates = context.status.paths
        candidates.formUnion(context.headEntries.keys)
        candidates.formUnion(context.indexPaths)
        try rejectChangedSubmodules(
            in: context.headEntries,
            repository: context.repository,
            snapshotReader: WorktreeForkChangesOnlyGitSnapshotReader(cancellation: cancellation),
            candidates: &candidates
        )
        return candidates
    }

    private static func submoduleHasMaterialChanges(_ status: UInt32) -> Bool {
        status & materialSubmoduleChangeFlags != 0
    }

    private func containsNestedGitAdministration(_ path: String, rootDescriptor: Int32) throws(GitWorktreeForkError)
        -> Bool
    {
        let directoryDescriptor: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: path) {
        case .success(let descriptor):
            directoryDescriptor = descriptor
        case .failure(let failure):
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: failure.code)
        }
        defer { close(directoryDescriptor) }
        if case .success = WorktreeForkDescriptors.statEntry(in: directoryDescriptor, name: ".git") {
            return true
        }
        return false
    }

    private static func matchesHead(
        _ source: WorktreeForkChangesOnlySourceNode,
        entry: WorktreeForkTreeEntry?,
        repository: OpaquePointer
    ) throws(GitWorktreeForkError) -> Bool {
        guard let entry else {
            return false
        }
        switch source.kind {
        case .absent, .directory, .fifo, .unixSocket, .characterDevice, .blockDevice, .unknown:
            return false
        case .regularFile:
            guard
                entry.mode == UInt32(GIT_FILEMODE_BLOB.rawValue)
                    || entry.mode == UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue),
                let contentHash = source.contentSHA256
            else {
                return false
            }
            let modeMatches =
                (source.mode & 0o111 != 0)
                == (entry.mode == UInt32(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue))
            let headContentHash = try WorktreeForkChangesOnlyGitSnapshotReader.blobSHA256(
                entry.oid, repository: repository)
            return modeMatches && contentHash == headContentHash
        case .symbolicLink:
            guard entry.mode == UInt32(GIT_FILEMODE_LINK.rawValue),
                let linkText = source.symbolicLinkText
            else {
                return false
            }
            guard
                let data = try WorktreeForkChangesOnlyGitSnapshotReader.blobData(
                    entry.oid, repository: repository)
            else {
                return false
            }
            return data == Data(linkText.utf8)
        }
    }

    private static func isTracked(
        _ path: String,
        headEntries: [String: WorktreeForkTreeEntry],
        indexPaths: Set<String>
    ) -> Bool {
        headEntries.keys.contains { overlaps($0, path) } || indexPaths.contains { overlaps($0, path) }
    }

    private static func overlapsGitlink(_ path: String, entries: [String: WorktreeForkTreeEntry]) -> Bool {
        entries.contains { candidate, entry in
            entry.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) && overlaps(candidate, path)
        }
    }

    private static func overlaps(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }

    private func hashDescriptor(_ descriptor: Int32, relativePath: String) throws(GitWorktreeForkError)
        -> String
    {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try cancellation.throwIfCancelled()
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                break
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                throw .entryFailed(relativePath: relativePath, reason: .unreadableEntry, errorNumber: errno)
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func refusal(_ reason: GitWorktreeWorkingStateRefusalReason, path: String? = nil)
        -> GitWorktreeForkError
    {
        .workingStateUnsupported(GitWorktreeWorkingStateRefusal(reason: reason, relativePath: path))
    }
}

struct WorktreeForkChangesOnlySourceNode {
    let kind: WorktreeForkChangesOnlySourceKind
    let identity: WorktreeForkEntryIdentity?
    let mode: UInt32
    let size: Int64
    let contentSHA256: String?
    let symbolicLinkText: String?

    static var absent: Self {
        Self(kind: .absent, identity: nil, mode: 0, size: 0, contentSHA256: nil, symbolicLinkText: nil)
    }

    static func special(_ kind: WorktreeForkEntryKind, identity: WorktreeForkEntryIdentity, mode: UInt32, size: Int64)
        -> Self
    {
        Self(
            kind: kind.changesOnlyKind,
            identity: identity,
            mode: mode,
            size: size,
            contentSHA256: nil,
            symbolicLinkText: nil
        )
    }
}

struct WorktreeForkChangesOnlyCaptureContext {
    let repository: OpaquePointer
    let sourceRootDescriptor: Int32
    let headEntries: [String: WorktreeForkTreeEntry]
    let indexPaths: Set<String>
    let status: WorktreeForkChangesOnlyStatus
    let filters: WorktreeForkHeadFilters
    let repositoryState: WorktreeForkRepositoryStateSnapshot
}

extension WorktreeForkEntryKind {
    var changesOnlyKind: WorktreeForkChangesOnlySourceKind {
        switch self {
        case .directory: .directory
        case .regularFile: .regularFile
        case .symbolicLink: .symbolicLink
        case .fifo: .fifo
        case .unixSocket: .unixSocket
        case .characterDevice: .characterDevice
        case .blockDevice: .blockDevice
        case .unknown: .unknown
        }
    }
}

enum WorktreeForkChangesOnlySourceKind: Equatable, Sendable {
    case absent
    case directory
    case regularFile
    case symbolicLink
    case fifo
    case unixSocket
    case characterDevice
    case blockDevice
    case unknown

    var publicKind: WorktreeForkChangesOnlyEntryKind {
        switch self {
        case .absent: .absent
        case .directory: .directory
        case .regularFile: .regularFile
        case .symbolicLink: .symbolicLink
        case .fifo, .unixSocket, .characterDevice, .blockDevice, .unknown: .absent
        }
    }
}
