import AgentStudioGitContracts
import CLibGit2Local
import CryptoKit
import Foundation

/// Reads the immutable Git-side facts changes-only planning compares again before publication.
struct WorktreeForkChangesOnlyGitSnapshotReader: Sendable {
    let cancellation: WorktreeForkCancellation

    func inspectIndex(_ repository: OpaquePointer) throws(GitWorktreeForkError) -> Set<String> {
        var index: OpaquePointer?
        let lookupResult = git_repository_index(&index, repository)
        guard lookupResult >= 0, let index else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_index_free(index) }
        let readResult = git_index_read(index, 1)
        guard readResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: readResult))
        }

        let skipWorktree = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        let intentToAdd = UInt16(GIT_INDEX_ENTRY_INTENT_TO_ADD.rawValue)
        let assumeUnchanged = UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
        var paths = Set<String>()
        for position in 0..<git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee, let pathPointer = entry.path else {
                continue
            }
            let path = String(cString: pathPointer)
            guard git_index_entry_stage(&entry) == 0 else {
                throw refusal(.conflicts, path: path)
            }
            if entry.flags_extended & intentToAdd != 0 {
                throw refusal(.intentToAdd, path: path)
            }
            if entry.flags_extended & skipWorktree != 0 || entry.flags & assumeUnchanged != 0 {
                throw refusal(.sparseOrSkipWorktree, path: path)
            }
            paths.insert(path)
        }
        return paths
    }

    func statusPaths(_ repository: OpaquePointer) throws(GitWorktreeForkError) -> WorktreeForkChangesOnlyStatus {
        var options = git_status_options()
        let initResult = git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        guard initResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: initResult))
        }
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags =
            GIT_STATUS_OPT_NO_REFRESH.rawValue
            | GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_INCLUDE_UNREADABLE.rawValue

        var list: OpaquePointer?
        let listResult = git_status_list_new(&list, repository, &options)
        guard listResult >= 0, let list else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: listResult))
        }
        defer { git_status_list_free(list) }

        var paths = Set<String>()
        var conflictedPaths = Set<String>()
        var unreadablePaths = Set<String>()
        for position in 0..<git_status_list_entrycount(list) {
            guard let entryPointer = git_status_byindex(list, position) else {
                continue
            }
            let entry = entryPointer.pointee
            var entryPaths = Set<String>()
            Self.addPaths(entry.head_to_index, to: &entryPaths)
            Self.addPaths(entry.index_to_workdir, to: &entryPaths)
            guard !entryPaths.isEmpty else {
                throw .gitFailure(
                    LibGit2ErrorCapture.fallbackFailure(
                        code: -1, message: "libgit2 returned a status entry without a path"))
            }
            paths.formUnion(entryPaths)
            if entry.status.rawValue & GIT_STATUS_CONFLICTED.rawValue != 0 {
                conflictedPaths.formUnion(entryPaths)
            }
            if entry.status.rawValue & GIT_STATUS_WT_UNREADABLE.rawValue != 0 {
                unreadablePaths.formUnion(entryPaths)
            }
        }
        return WorktreeForkChangesOnlyStatus(
            paths: paths,
            conflictedPaths: conflictedPaths,
            unreadablePaths: unreadablePaths
        )
    }

    func inspectHeadFilters(
        _ repository: OpaquePointer,
        headEntries: [String: WorktreeForkTreeEntry]
    ) throws(GitWorktreeForkError) -> WorktreeForkHeadFilters {
        var options = git_attr_options()
        options.version = UInt32(GIT_ATTR_OPTIONS_VERSION)
        options.flags = UInt32(GIT_ATTR_CHECK_INCLUDE_HEAD)
        var largeFilePointers: [String: LargeFilePointer] = [:]
        for (path, entry) in headEntries.sorted(by: { $0.key < $1.key }) {
            try cancellation.throwIfCancelled()
            var value: UnsafePointer<CChar>?
            let result = path.withCString { pathPointer in
                "filter".withCString { attributePointer in
                    git_attr_get_ext(&value, repository, &options, pathPointer, attributePointer)
                }
            }
            guard result >= 0 else {
                throw .gitFailure(LibGit2ErrorCapture.failure(code: result))
            }
            guard let value, git_attr_value(value) == GIT_ATTR_VALUE_STRING else {
                continue
            }
            let filterName = String(cString: value)
            guard filterName == "lfs" else {
                throw refusal(.customFilter, path: path)
            }
            guard entry.mode != UInt32(GIT_FILEMODE_COMMIT.rawValue),
                let pointerData = try Self.blobData(entry.oid, repository: repository),
                let pointer = LargeFilePointer(data: pointerData)
            else {
                continue
            }
            largeFilePointers[path] = pointer
        }
        return WorktreeForkHeadFilters(largeFilePointers: largeFilePointers)
    }

    func repositoryState(
        _ repository: OpaquePointer,
        expectedHead: String
    ) throws(GitWorktreeForkError) -> WorktreeForkRepositoryStateSnapshot {
        var index: OpaquePointer?
        let lookupResult = git_repository_index(&index, repository)
        guard lookupResult >= 0, let index else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: lookupResult))
        }
        defer { git_index_free(index) }
        let readResult = git_index_read(index, 1)
        guard readResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: readResult))
        }
        var fingerprintInput = Data()
        for position in 0..<git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee, let path = entry.path else {
                continue
            }
            var oid = entry.id
            fingerprintInput.append(contentsOf: String(cString: path).utf8)
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: oidString(&oid).utf8)
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: String(entry.mode).utf8)
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: String(git_index_entry_stage(&entry)).utf8)
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: String(entry.flags_extended).utf8)
            fingerprintInput.append(10)
        }
        var headOID = git_oid()
        let headResult = git_reference_name_to_id(&headOID, repository, "HEAD")
        guard headResult >= 0 else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: headResult))
        }
        let headCommitOID = oidString(&headOID)
        guard headCommitOID == expectedHead else {
            throw .sourceChanged(relativePath: ".", reason: .repositoryStateChanged)
        }
        return WorktreeForkRepositoryStateSnapshot(
            headCommitOID: headCommitOID,
            indexFingerprint: Self.sha256Hex(fingerprintInput),
            operationState: git_repository_state(repository)
        )
    }

    static func blobData(_ objectID: String, repository: OpaquePointer) throws(GitWorktreeForkError) -> Data? {
        guard var oid = WorktreeForkObjectID.parse(objectID) else {
            throw .gitFailure(.requiredObjectNotFound(oid: objectID))
        }
        var blob: OpaquePointer?
        let result = git_blob_lookup(&blob, repository, &oid)
        guard result >= 0, let blob else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: result))
        }
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size < LibGit2LargeFilePointerCleanliness.maximumPointerByteCount else {
            return nil
        }
        guard let content = git_blob_rawcontent(blob) else {
            return size == 0 ? Data() : nil
        }
        return Data(bytes: content, count: size)
    }

    static func blobSHA256(_ objectID: String, repository: OpaquePointer) throws(GitWorktreeForkError) -> String {
        guard var oid = WorktreeForkObjectID.parse(objectID) else {
            throw .gitFailure(.requiredObjectNotFound(oid: objectID))
        }
        var blob: OpaquePointer?
        let result = git_blob_lookup(&blob, repository, &oid)
        guard result >= 0, let blob else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: result))
        }
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        if size == 0 {
            return sha256Hex(Data())
        }
        guard let content = git_blob_rawcontent(blob) else {
            throw .gitFailure(.requiredObjectNotFound(oid: objectID))
        }
        var hasher = SHA256()
        var offset = 0
        while offset < size {
            let count = min(1_048_576, size - offset)
            hasher.update(data: Data(bytes: content.advanced(by: offset), count: count))
            offset += count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func addPaths(_ delta: UnsafePointer<git_diff_delta>?, to paths: inout Set<String>) {
        guard let delta else {
            return
        }
        for pathPointer in [delta.pointee.old_file.path, delta.pointee.new_file.path].compactMap({ $0 }) {
            var path = String(cString: pathPointer)
            while path.hasSuffix("/") {
                path.removeLast()
            }
            if !path.isEmpty {
                paths.insert(path)
            }
        }
    }

    private func refusal(_ reason: GitWorktreeWorkingStateRefusalReason, path: String? = nil)
        -> GitWorktreeForkError
    {
        .workingStateUnsupported(GitWorktreeWorkingStateRefusal(reason: reason, relativePath: path))
    }
}

struct WorktreeForkChangesOnlyStatus {
    let paths: Set<String>
    let conflictedPaths: Set<String>
    let unreadablePaths: Set<String>

    var changedAttributesPath: String? {
        paths.sorted().first { path in
            path == ".gitattributes" || path.hasSuffix("/.gitattributes")
        }
    }
}

struct WorktreeForkHeadFilters {
    let largeFilePointers: [String: LargeFilePointer]
}
