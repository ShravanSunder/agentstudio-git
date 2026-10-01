import AgentStudioGitContracts
import CryptoKit
import Darwin
import Foundation

/// Applies captured source paths over a clean checkout, using root-relative descriptors throughout.
struct WorktreeForkChangesOnlyMaterializer: Sendable {
    let cancellation: WorktreeForkCancellation
    let faults: WorktreeForkFaultInjector

    func apply(
        _ plan: WorktreeForkChangesOnlyPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: ".") { () throws(GitWorktreeForkError) in
            try applyWhileMaterializationDenied(
                plan,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor
            )
        }
    }

    private func applyWhileMaterializationDenied(
        _ plan: WorktreeForkChangesOnlyPlan,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let overlayEntries = plan.entries.filter(\.shouldOverlay)
        for entry in overlayEntries where entry.kind != .directory {
            try cancellation.throwIfCancelled()
            try removeDestinationNode(entry.relativePath, rootDescriptor: destinationRootDescriptor)
        }
        for entry in overlayEntries where entry.kind == .directory {
            try cancellation.throwIfCancelled()
            if try destinationKind(entry.relativePath, rootDescriptor: destinationRootDescriptor) != .directory {
                try removeDestinationNode(entry.relativePath, rootDescriptor: destinationRootDescriptor)
            }
        }

        for entry in plan.entries where entry.kind == .directory {
            try cancellation.throwIfCancelled()
            try ensureDirectory(entry.relativePath, rootDescriptor: destinationRootDescriptor)
        }
        for entry in overlayEntries {
            try cancellation.throwIfCancelled()
            switch entry.kind {
            case .absent, .directory:
                continue
            case .regularFile:
                try faults.reach(.beforeChangesOnlyFileCopy(relativePath: entry.relativePath))
                try copyRegularFile(
                    entry,
                    sourceRootDescriptor: sourceRootDescriptor,
                    destinationRootDescriptor: destinationRootDescriptor
                )
            case .symbolicLink:
                try createSymbolicLink(
                    entry,
                    sourceRootDescriptor: sourceRootDescriptor,
                    destinationRootDescriptor: destinationRootDescriptor
                )
            }
        }
        for restoration in plan.largeFileRestorations {
            try cancellation.throwIfCancelled()
            try copyLargeFileRestoration(
                restoration,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor
            )
        }
        for entry in overlayEntries.reversed() where entry.kind == .directory {
            try applyDirectoryMode(
                entry,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor)
        }
    }

    private func copyRegularFile(
        _ entry: WorktreeForkChangesOnlyEntry,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let source = try openSourceRegularFile(
            entry.relativePath,
            expectedIdentity: entry.identity,
            expectedSize: entry.size,
            expectedMode: entry.mode,
            rootDescriptor: sourceRootDescriptor
        )
        defer { close(source.descriptor) }
        let destinationParent = try ensureParentDirectory(
            entry.relativePath, rootDescriptor: destinationRootDescriptor)
        defer { close(destinationParent.descriptor) }
        let destination = entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath
        let destinationDescriptor = destination.withCString {
            openat(
                destinationParent.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard destinationDescriptor >= 0 else {
            throw .entryFailed(relativePath: entry.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
        defer { close(destinationDescriptor) }
        try copyAndVerify(
            sourceDescriptor: source.descriptor,
            destinationDescriptor: destinationDescriptor,
            path: entry.relativePath,
            expectedSize: entry.size,
            expectedSHA256: entry.contentSHA256
        )
        guard fchmod(destinationDescriptor, mode_t(entry.mode & 0o777)) == 0 else {
            throw .entryFailed(relativePath: entry.relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    private func copyLargeFileRestoration(
        _ restoration: WorktreeForkLargeFileRestoration,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let source = try openSourceRegularFile(
            restoration.relativePath,
            expectedIdentity: restoration.identity,
            expectedSize: restoration.size,
            expectedMode: restoration.mode,
            rootDescriptor: sourceRootDescriptor
        )
        defer { close(source.descriptor) }
        let destination = try openDestinationRegularFile(
            restoration.relativePath, rootDescriptor: destinationRootDescriptor)
        defer { close(destination.descriptor) }
        try copyAndVerify(
            sourceDescriptor: source.descriptor,
            destinationDescriptor: destination.descriptor,
            path: restoration.relativePath,
            expectedSize: restoration.size,
            expectedSHA256: restoration.contentSHA256
        )
        guard fchmod(destination.descriptor, mode_t(restoration.mode & 0o777)) == 0 else {
            throw .entryFailed(
                relativePath: restoration.relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    private func createSymbolicLink(
        _ entry: WorktreeForkChangesOnlyEntry,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(entry.relativePath)
        let sourceParent = try openDirectory(sourceRootDescriptor, parentPath, path: entry.relativePath)
        defer { close(sourceParent) }
        let destinationParent = try ensureParentDirectory(
            entry.relativePath, rootDescriptor: destinationRootDescriptor)
        defer { close(destinationParent.descriptor) }
        var info = Darwin.stat()
        guard name.withCString({ fstatat(sourceParent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
            let expectedIdentity = entry.identity,
            WorktreeForkEntryIdentity(info) == expectedIdentity,
            WorktreeForkEntryKind(mode: info.st_mode) == .symbolicLink
        else {
            throw .sourceChanged(relativePath: entry.relativePath, reason: .entryIdentityChanged)
        }
        let sourceText = try readLink(parentDescriptor: sourceParent, name: name, path: entry.relativePath)
        var finalInfo = Darwin.stat()
        guard name.withCString({ fstatat(sourceParent, $0, &finalInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
            WorktreeForkEntryIdentity(finalInfo) == expectedIdentity,
            sourceText == entry.symbolicLinkText,
            let target = entry.symbolicLinkText
        else {
            throw .sourceChanged(relativePath: entry.relativePath, reason: .contentChanged)
        }
        let destinationName = entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath
        let result = target.withCString { targetPointer in
            destinationName.withCString { namePointer in
                symlinkat(targetPointer, destinationParent.descriptor, namePointer)
            }
        }
        guard result == 0 else {
            throw .entryFailed(relativePath: entry.relativePath, reason: .entryCreationFailed, errorNumber: errno)
        }
    }

    private func applyDirectoryMode(
        _ entry: WorktreeForkChangesOnlyEntry,
        sourceRootDescriptor: Int32,
        destinationRootDescriptor: Int32
    ) throws(GitWorktreeForkError) {
        let source = try openDirectory(sourceRootDescriptor, entry.relativePath, path: entry.relativePath)
        defer { close(source) }
        guard case .success(let sourceInfo) = WorktreeForkDescriptors.statDescriptor(source),
            let identity = entry.identity,
            WorktreeForkEntryIdentity(sourceInfo) == identity
        else {
            throw .sourceChanged(relativePath: entry.relativePath, reason: .entryIdentityChanged)
        }
        let destination = try openDirectory(destinationRootDescriptor, entry.relativePath, path: entry.relativePath)
        defer { close(destination) }
        guard fchmod(destination, mode_t(entry.mode & 0o777)) == 0 else {
            throw .entryFailed(relativePath: entry.relativePath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    private func openSourceRegularFile(
        _ path: String,
        expectedIdentity: WorktreeForkEntryIdentity?,
        expectedSize: Int64,
        expectedMode: UInt32,
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkOpenedFile {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        let parent = try openDirectory(rootDescriptor, parentPath, path: path)
        defer { close(parent) }
        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: path, errorNumber: errno)
        }
        guard case .success(let info) = WorktreeForkDescriptors.statDescriptor(descriptor),
            WorktreeForkEntryKind(mode: info.st_mode) == .regularFile,
            let expectedIdentity,
            WorktreeForkEntryIdentity(info) == expectedIdentity,
            Int64(info.st_size) == expectedSize,
            (UInt32(info.st_mode) & 0o777) == (expectedMode & 0o777),
            info.st_flags & UInt32(SF_DATALESS) == 0
        else {
            close(descriptor)
            throw .sourceChanged(relativePath: path, reason: .entryIdentityChanged)
        }
        return WorktreeForkOpenedFile(descriptor: descriptor, parentPath: parentPath, name: name)
    }

    private func openDestinationRegularFile(
        _ path: String,
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkOpenedFile {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        let parent = try openDirectory(rootDescriptor, parentPath, path: path)
        defer { close(parent) }
        var info = Darwin.stat()
        guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
            WorktreeForkEntryKind(mode: info.st_mode) == .regularFile
        else {
            throw .validationFailed(reason: .entryKindMismatch, relativePath: path)
        }
        let descriptor = name.withCString { openat(parent, $0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: path, reason: .entryCreationFailed, errorNumber: errno)
        }
        return WorktreeForkOpenedFile(descriptor: descriptor, parentPath: parentPath, name: name)
    }

    private func copyAndVerify(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        path: String,
        expectedSize: Int64,
        expectedSHA256: String?
    ) throws(GitWorktreeForkError) {
        var hasher = SHA256()
        var copiedBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try cancellation.throwIfCancelled()
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 {
                break
            }
            guard readCount > 0 else {
                if errno == EINTR {
                    continue
                }
                throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: errno)
            }
            let chunk = Data(buffer.prefix(readCount))
            hasher.update(data: chunk)
            copiedBytes += Int64(readCount)
            try writeAll(chunk, destinationDescriptor: destinationDescriptor, path: path)
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copiedBytes == expectedSize, actualHash == expectedSHA256 else {
            throw .sourceChanged(relativePath: path, reason: .contentChanged)
        }
    }

    private func writeAll(_ data: Data, destinationDescriptor: Int32, path: String) throws(GitWorktreeForkError) {
        let failureCode = data.withUnsafeBytes { bytes -> Int32? in
            guard let base = bytes.baseAddress else {
                return nil
            }
            var offset = 0
            while offset < bytes.count {
                let written = write(destinationDescriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                if written <= 0 {
                    return errno
                }
                offset += written
            }
            return nil
        }
        if let failureCode {
            throw .entryFailed(relativePath: path, reason: .entryCreationFailed, errorNumber: failureCode)
        }
    }

    private func ensureDirectory(_ path: String, rootDescriptor: Int32) throws(GitWorktreeForkError) {
        try cancellation.throwIfCancelled()
        if path.isEmpty {
            return
        }
        if case .success(let descriptor) = WorktreeForkDescriptors.openDirectory(
            beneath: rootDescriptor, relativePath: path)
        {
            close(descriptor)
            return
        }
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        try ensureDirectory(parentPath, rootDescriptor: rootDescriptor)
        let parent = try openDirectory(rootDescriptor, parentPath, path: path)
        defer { close(parent) }
        if name.withCString({ mkdirat(parent, $0, 0o700) }) == 0 {
            return
        }
        if errno == EEXIST,
            case .success(let descriptor) = WorktreeForkDescriptors.openDirectory(
                beneath: rootDescriptor, relativePath: path)
        {
            close(descriptor)
            return
        }
        throw .entryFailed(relativePath: path, reason: .entryCreationFailed, errorNumber: errno)
    }

    private func ensureParentDirectory(
        _ path: String,
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkOpenedFile {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        try ensureDirectory(parentPath, rootDescriptor: rootDescriptor)
        return WorktreeForkOpenedFile(
            descriptor: try openDirectory(rootDescriptor, parentPath, path: path), parentPath: parentPath, name: name)
    }

    private func openDirectory(
        _ rootDescriptor: Int32,
        _ path: String,
        path reportPath: String
    ) throws(GitWorktreeForkError)
        -> Int32
    {
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: path) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw WorktreeForkSourceWalker.sourceFailure(relativePath: reportPath, errorNumber: failure.code)
        }
    }

    private func destinationKind(
        _ path: String,
        rootDescriptor: Int32
    ) throws(GitWorktreeForkError) -> WorktreeForkEntryKind? {
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        let parent = try openDirectory(rootDescriptor, parentPath, path: path)
        defer { close(parent) }
        switch WorktreeForkDescriptors.statEntry(in: parent, name: name) {
        case .success(let info):
            return WorktreeForkEntryKind(mode: info.st_mode)
        case .failure(let failure) where failure.code == ENOENT:
            return nil
        case .failure(let failure):
            throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private func removeDestinationNode(_ path: String, rootDescriptor: Int32) throws(GitWorktreeForkError) {
        try cancellation.throwIfCancelled()
        guard !path.isEmpty else {
            throw .validationFailed(reason: .transactionArtifactRemains, relativePath: ".")
        }
        let (parentPath, name) = WorktreeForkDescriptors.splitParent(path)
        let parent: Int32
        switch WorktreeForkDescriptors.openDirectory(beneath: rootDescriptor, relativePath: parentPath) {
        case .success(let opened):
            parent = opened
        case .failure(let failure) where failure.code == ENOENT || failure.code == ENOTDIR:
            // A shallower overlay entry may replace this path's non-directory parent.
            return
        case .failure(let failure):
            throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: failure.code)
        }
        defer { close(parent) }
        let info: Darwin.stat
        switch WorktreeForkDescriptors.statEntry(in: parent, name: name) {
        case .success(let current):
            info = current
        case .failure(let failure) where failure.code == ENOENT:
            return
        case .failure(let failure):
            throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: failure.code)
        }
        if WorktreeForkEntryKind(mode: info.st_mode) == .directory {
            let directory = try openDirectory(rootDescriptor, path, path: path)
            guard let stream = fdopendir(directory) else {
                close(directory)
                throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: errno)
            }
            var names: [String] = []
            while let rawEntry = readdir(stream) {
                guard let child = WorktreeForkDescriptors.entryName(rawEntry) else {
                    closedir(stream)
                    throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: EILSEQ)
                }
                if child != ".", child != ".." {
                    names.append(child)
                }
            }
            closedir(stream)
            for child in names {
                try cancellation.throwIfCancelled()
                try removeDestinationNode(WorktreeForkDescriptors.joined(path, child), rootDescriptor: rootDescriptor)
            }
            guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
                throw .entryFailed(relativePath: path, reason: .entryCreationFailed, errorNumber: errno)
            }
        } else if name.withCString({ unlinkat(parent, $0, 0) }) != 0 {
            throw .entryFailed(relativePath: path, reason: .entryCreationFailed, errorNumber: errno)
        }
    }

    private func readLink(parentDescriptor: Int32, name: String, path: String) throws(GitWorktreeForkError) -> String {
        var info = Darwin.stat()
        guard name.withCString({ fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw .sourceChanged(relativePath: path, reason: .entryMissing)
        }
        var buffer = [CChar](repeating: 0, count: max(2, Int(info.st_size) + 2))
        let count = name.withCString { readlinkat(parentDescriptor, $0, &buffer, buffer.count) }
        guard count >= 0,
            let linkText = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        else {
            throw .entryFailed(relativePath: path, reason: .unreadableEntry, errorNumber: errno)
        }
        return linkText
    }
}

private struct WorktreeForkOpenedFile {
    let descriptor: Int32
    let parentPath: String
    let name: String
}
