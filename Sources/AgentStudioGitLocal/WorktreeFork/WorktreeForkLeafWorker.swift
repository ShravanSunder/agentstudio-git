import AgentStudioGitContracts
import Darwin
import Foundation

/// Realizes one planned leaf batch. Each leaf is re-checked against its planned kind and identity at the
/// moment it is realized; a disappearance, replacement, or escape fails the transaction instead of
/// silently realizing something the plan did not classify.
struct WorktreeForkLeafWorker: Sendable {
    static let cloneFlags = UInt32(CLONE_NOFOLLOW | CLONE_ACL)
    static let leafOpenFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    let sourceRootDescriptor: Int32
    let destinationRootDescriptor: Int32

    func realize(
        _ batch: WorktreeForkLeafBatch,
        into observations: inout WorktreeForkMaterializationObservations
    ) throws(GitWorktreeForkError) {
        let sourceDirectory = try openDirectory(sourceRootDescriptor, batch.directoryRelativePath, isSource: true)
        defer { close(sourceDirectory) }
        let destinationDirectory = try openDirectory(
            destinationRootDescriptor, batch.directoryRelativePath, isSource: false)
        defer { close(destinationDirectory) }

        for leaf in batch.leaves {
            switch leaf.kind {
            case .regularFile:
                try cloneRegularFile(leaf, sourceDirectory, destinationDirectory, &observations)
            case .symbolicLink:
                try recreateSymbolicLink(leaf, sourceDirectory, destinationDirectory, &observations)
            case .fifo:
                try recreateFIFO(leaf, sourceDirectory, destinationDirectory, &observations)
            }
        }
    }

    private func cloneRegularFile(
        _ leaf: WorktreeForkPlannedLeaf,
        _ sourceDirectory: Int32,
        _ destinationDirectory: Int32,
        _ observations: inout WorktreeForkMaterializationObservations
    ) throws(GitWorktreeForkError) {
        let sourceDescriptor = leaf.name.withCString { openat(sourceDirectory, $0, Self.leafOpenFlags) }
        guard sourceDescriptor >= 0 else {
            throw raceFailure(leaf, errorNumber: errno)
        }
        defer { close(sourceDescriptor) }
        let sourceInfo = try verifiedInfo(of: sourceDescriptor, matching: leaf)
        if sourceInfo.st_flags & UInt32(SF_DATALESS) != 0 {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .datalessFile, errorNumber: nil)
        }
        let cloneResult = leaf.name.withCString {
            fclonefileat(sourceDescriptor, destinationDirectory, $0, Self.cloneFlags)
        }
        guard cloneResult == 0 else {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .strictCloneFailed, errorNumber: errno)
        }
        let destinationInfo = try destinationInfo(leaf, destinationDirectory, expectedKind: .regularFile)
        observations.normalizedEntries += try WorktreeForkEntryMetadata.normalization(
            source: sourceInfo,
            destination: destinationInfo,
            relativePath: leaf.relativePath
        )
        observations.clonedRegularFileCount += 1
        observations.logicalRegularFileBytes += destinationInfo.st_size
        if WorktreeForkObservedStat(sourceInfo) == leaf.plannedStat {
            observations.statMatchedClonePaths.insert(leaf.relativePath)
        }
    }

    private func recreateSymbolicLink(
        _ leaf: WorktreeForkPlannedLeaf,
        _ sourceDirectory: Int32,
        _ destinationDirectory: Int32,
        _ observations: inout WorktreeForkMaterializationObservations
    ) throws(GitWorktreeForkError) {
        let sourceDescriptor = leaf.name.withCString { openat(sourceDirectory, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC) }
        guard sourceDescriptor >= 0 else {
            throw raceFailure(leaf, errorNumber: errno)
        }
        defer { close(sourceDescriptor) }
        let sourceInfo = try verifiedInfo(of: sourceDescriptor, matching: leaf)
        let target = try linkText(leaf, sourceDirectory, expectedLength: Int(sourceInfo.st_size))
        let createResult = target.withUnsafeBufferPointer { targetBytes in
            leaf.name.withCString { symlinkat(targetBytes.baseAddress, destinationDirectory, $0) }
        }
        guard createResult == 0 else {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
        let destinationDescriptor = leaf.name.withCString {
            openat(destinationDirectory, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        }
        guard destinationDescriptor >= 0 else {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
        defer { close(destinationDescriptor) }
        observations.normalizedEntries += try WorktreeForkEntryMetadata.copyInodeMetadata(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            sourceInfo: sourceInfo,
            relativePath: leaf.relativePath
        )
        observations.recreatedSymbolicLinkCount += 1
    }

    private func recreateFIFO(
        _ leaf: WorktreeForkPlannedLeaf,
        _ sourceDirectory: Int32,
        _ destinationDirectory: Int32,
        _ observations: inout WorktreeForkMaterializationObservations
    ) throws(GitWorktreeForkError) {
        let sourceDescriptor = leaf.name.withCString { openat(sourceDirectory, $0, Self.leafOpenFlags) }
        guard sourceDescriptor >= 0 else {
            throw raceFailure(leaf, errorNumber: errno)
        }
        defer { close(sourceDescriptor) }
        let sourceInfo = try verifiedInfo(of: sourceDescriptor, matching: leaf)
        guard leaf.name.withCString({ mkfifoat(destinationDirectory, $0, 0o600) }) == 0 else {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
        let destinationDescriptor = leaf.name.withCString { openat(destinationDirectory, $0, Self.leafOpenFlags) }
        guard destinationDescriptor >= 0 else {
            throw .entryFailed(relativePath: leaf.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
        defer { close(destinationDescriptor) }
        observations.normalizedEntries += try WorktreeForkEntryMetadata.copyInodeMetadata(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            sourceInfo: sourceInfo,
            relativePath: leaf.relativePath
        )
        observations.recreatedFIFOCount += 1
    }

    private func verifiedInfo(
        of descriptor: Int32,
        matching leaf: WorktreeForkPlannedLeaf
    ) throws(GitWorktreeForkError) -> Darwin.stat {
        switch WorktreeForkDescriptors.statDescriptor(descriptor) {
        case .success(let info):
            guard Self.leafKind(of: info) == leaf.kind else {
                throw .sourceChanged(relativePath: leaf.relativePath, reason: .entryKindChanged)
            }
            guard WorktreeForkEntryIdentity(info) == leaf.identity else {
                throw .sourceChanged(relativePath: leaf.relativePath, reason: .entryIdentityChanged)
            }
            return info
        case .failure(let failure):
            throw .entryFailed(relativePath: leaf.relativePath, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private func destinationInfo(
        _ leaf: WorktreeForkPlannedLeaf,
        _ destinationDirectory: Int32,
        expectedKind: WorktreeForkLeafKind
    ) throws(GitWorktreeForkError) -> Darwin.stat {
        switch WorktreeForkDescriptors.statEntry(in: destinationDirectory, name: leaf.name) {
        case .success(let info) where Self.leafKind(of: info) == expectedKind:
            return info
        case .success:
            // The source was swapped for another kind between the check and the clone.
            throw .sourceChanged(relativePath: leaf.relativePath, reason: .entryKindChanged)
        case .failure(let failure):
            throw .entryFailed(relativePath: leaf.relativePath, reason: .entryCreationFailed, errorNumber: failure.code)
        }
    }

    private func linkText(
        _ leaf: WorktreeForkPlannedLeaf,
        _ sourceDirectory: Int32,
        expectedLength: Int
    ) throws(GitWorktreeForkError) -> [CChar] {
        let capacity = max(expectedLength, 1) + 1
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = leaf.name.withCString { readlinkat(sourceDirectory, $0, &buffer, capacity) }
        guard length >= 0 else {
            throw raceFailure(leaf, errorNumber: errno)
        }
        guard length < capacity else {
            throw .sourceChanged(relativePath: leaf.relativePath, reason: .entryIdentityChanged)
        }
        // Link text is raw bytes; keep it byte-exact and NUL-terminated for symlinkat.
        return Array(buffer.prefix(length)) + [0]
    }

    private func openDirectory(
        _ rootDescriptor: Int32,
        _ relativePath: String,
        isSource: Bool
    ) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: relativePath) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            let reportPath = relativePath.isEmpty ? "." : relativePath
            if isSource {
                throw WorktreeForkSourceWalker.sourceFailure(relativePath: reportPath, errorNumber: failure.code)
            }
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure.code)
        }
    }

    private func raceFailure(_ leaf: WorktreeForkPlannedLeaf, errorNumber: Int32) -> GitWorktreeForkError {
        switch errorNumber {
        case ENOENT:
            .sourceChanged(relativePath: leaf.relativePath, reason: .entryMissing)
        case ELOOP, EINVAL:
            .sourceChanged(relativePath: leaf.relativePath, reason: .entryKindChanged)
        default:
            .entryFailed(relativePath: leaf.relativePath, reason: .unreadableEntry, errorNumber: errorNumber)
        }
    }

    private static func leafKind(of info: Darwin.stat) -> WorktreeForkLeafKind? {
        switch WorktreeForkEntryKind(mode: info.st_mode) {
        case .regularFile: .regularFile
        case .symbolicLink: .symbolicLink
        case .fifo: .fifo
        default: nil
        }
    }
}
