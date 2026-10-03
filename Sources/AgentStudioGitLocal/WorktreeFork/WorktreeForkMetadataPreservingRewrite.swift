import AgentStudioGitContracts
import Darwin
import Foundation

/// Re-homing rewrites cloned administrative files (`HEAD`, alternates, sparse state, configuration) by
/// swapping a new inode in at the path: our own temporary-file rename, or libgit2's lock-file rename. A fresh
/// inode drops the replaced file's metadata, and a user-immutable or append-only flag or a `deny delete` ACL
/// entry forbids the swap itself. The specification makes loss of ACL access semantics, extended attributes,
/// or file flags a failure, so every such rewrite goes through here.
enum WorktreeForkMetadataPreservingRewrite {
    /// Where a rewritten file's metadata comes from. Each caller names it: a destination copy can stand for a
    /// different source file than the one being written (a flattened linked worktree's cloned `HEAD` is the
    /// common repository's), so the file being replaced is never a fallback.
    enum MetadataSource {
        /// The source file this destination file stands for. When it is not a regular file, the new file
        /// keeps the swap's own mode and nothing is reported.
        case sourceCounterpart(URL)
        /// The file being edited in place (a libgit2 configuration edit): its metadata before the edit.
        case editedFile
    }

    /// Runs `swapInReplacement`, which leaves a new regular file at `url`, then gives that file the mode,
    /// extended attributes, ACL, and flags `metadataSource` names. Protection on the replaced file is lifted
    /// only from our own destination copy so the swap can rename over it. A swap may also leave the original in
    /// place (libgit2 skips an edit that changes nothing); then only the lifted protection goes back.
    ///
    /// A replaced file with other hard links (a copied store's file the materializer linked to an alias) is
    /// refused before anything changes: swapping one name would split the destination hard-link group, and the
    /// other names may need different pointer text, so neither a split nor an in-place edit is faithful.
    static func rewrite(
        _ url: URL,
        metadataFrom metadataSource: MetadataSource,
        reportPath: String,
        swapInReplacement: () throws(GitWorktreeForkError) -> Void
    ) throws(GitWorktreeForkError) {
        if case .success(let info) = WorktreeForkDescriptors.lstatPath(url), info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink > 1
        {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: nil)
        }
        let protection = try WorktreeForkReplacementProtection.lift(at: url, reportPath: reportPath)
        do throws(GitWorktreeForkError) {
            let metadata: WorktreeForkFileMetadata?
            switch metadataSource {
            case .sourceCounterpart(let template):
                metadata = try WorktreeForkFileMetadata.capture(from: template, reportPath: reportPath)
            case .editedFile:
                metadata = try protection?.originalMetadata(at: url, reportPath: reportPath)
            }
            try swapInReplacement()
            if let protection, protection.isOriginal(at: url) {
                try protection.restore(at: url, reportPath: reportPath)
            } else {
                try metadata?.apply(to: url, reportPath: reportPath)
            }
        } catch {
            try? protection?.restore(at: url, reportPath: reportPath)
            throw error
        }
    }
}

/// Where a metadata operation lands: a path whose final component is never followed, or an open descriptor.
/// Lifting and restoring protection run the same steps through either, so a caller that holds descriptors
/// (descriptor-relative counterpart cloning) never re-resolves a path.
enum WorktreeForkMetadataTarget {
    case path(URL)
    case descriptor(Int32)

    /// Returns errno, or 0.
    func setFlags(_ flags: UInt32) -> Int32 {
        let result =
            switch self {
            case .path(let url): lchflags(url.path, flags)
            case .descriptor(let descriptor): fchflags(descriptor, flags)
            }
        return result == 0 ? 0 : errno
    }

    /// Returns errno, or 0.
    func setMode(_ mode: mode_t) -> Int32 {
        let result =
            switch self {
            case .path(let url): lchmod(url.path, mode)
            case .descriptor(let descriptor): fchmod(descriptor, mode)
            }
        return result == 0 ? 0 : errno
    }

    /// The extended ACL, or nil when there is none. The owner may always read an ACL, even one that denies
    /// reading the file.
    func accessControlList(reportPath: String) throws(GitWorktreeForkError) -> acl_t? {
        let accessControlList =
            switch self {
            case .path(let url): acl_get_link_np(url.path, ACL_TYPE_EXTENDED)
            case .descriptor(let descriptor): acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
            }
        if let accessControlList {
            return accessControlList
        }
        guard errno == ENOENT else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        return nil
    }

    /// Returns errno, or 0.
    func setAccessControlList(_ accessControlList: acl_t) -> Int32 {
        let result =
            switch self {
            case .path(let url): acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList)
            case .descriptor(let descriptor): acl_set_fd_np(descriptor, accessControlList, ACL_TYPE_EXTENDED)
            }
        return result == 0 ? 0 : errno
    }

    /// Setting an empty extended ACL removes it. Returns errno, or 0.
    func removeAccessControlList() -> Int32 {
        guard let empty = acl_init(0) else {
            return errno
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return setAccessControlList(empty)
    }
}

/// The mode, flags, extended ACL, and extended attributes a rewritten file must carry. Extended attributes
/// are read through `descriptor` when applied, which keeps the template's inode alive even after the swap
/// unlinks it.
final class WorktreeForkFileMetadata {
    private let mode: mode_t
    private let flags: UInt32
    private let accessControlList: acl_t?
    private let descriptor: Int32

    /// Takes ownership of `descriptor` and `accessControlList`.
    init(mode: mode_t, flags: UInt32, accessControlList: acl_t?, descriptor: Int32) {
        self.mode = mode
        self.flags = flags
        self.accessControlList = accessControlList
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
        if let accessControlList {
            acl_free(UnsafeMutableRawPointer(accessControlList))
        }
    }

    /// Nil when no regular file is at `template`. Never changes the template, which may be source state.
    static func capture(from template: URL, reportPath: String) throws(GitWorktreeForkError)
        -> WorktreeForkFileMetadata?
    {
        var info = Darwin.stat()
        guard template.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        let accessControlList = try WorktreeForkMetadataTarget.path(template).accessControlList(reportPath: reportPath)
        let descriptor = template.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            let failure = errno
            if let accessControlList {
                acl_free(UnsafeMutableRawPointer(accessControlList))
            }
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure)
        }
        return WorktreeForkFileMetadata(
            mode: info.st_mode & 0o7777, flags: info.st_flags, accessControlList: accessControlList,
            descriptor: descriptor)
    }

    /// Captures through a caller-owned descriptor of a regular file; the metadata keeps its own duplicate.
    static func capture(
        fromDescriptor source: Int32,
        reportPath: String
    ) throws(GitWorktreeForkError) -> WorktreeForkFileMetadata {
        let info: Darwin.stat
        switch WorktreeForkDescriptors.statDescriptor(source) {
        case .success(let sourceInfo) where sourceInfo.st_mode & S_IFMT == S_IFREG:
            info = sourceInfo
        case .success:
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: nil)
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure.code)
        }
        let accessControlList = try WorktreeForkMetadataTarget.descriptor(source).accessControlList(
            reportPath: reportPath)
        let descriptor = dup(source)
        guard descriptor >= 0 else {
            let failure = errno
            if let accessControlList {
                acl_free(UnsafeMutableRawPointer(accessControlList))
            }
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure)
        }
        return WorktreeForkFileMetadata(
            mode: info.st_mode & 0o7777, flags: info.st_flags, accessControlList: accessControlList,
            descriptor: descriptor)
    }

    /// Applies everything to the regular file now at `url`.
    func apply(to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        let replacement = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard replacement >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        defer { _ = close(replacement) }
        try applyAttributesAndMode(toDescriptor: replacement, reportPath: reportPath)
        try applyAccessControlAndFlags(toDescriptor: replacement, reportPath: reportPath)
    }

    /// Extended attributes while the file is still writable, then mode. Neither blocks a later rename.
    func applyAttributesAndMode(toDescriptor replacement: Int32, reportPath: String) throws(GitWorktreeForkError) {
        try WorktreeForkEntryMetadata.copyExtendedAttributes(
            from: descriptor, to: replacement, relativePath: reportPath)
        guard fchmod(replacement, mode) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    /// ACL, then flags last because an immutable file accepts no further change. Either can forbid renaming the
    /// file, so a caller swapping it into place applies these after the rename.
    func applyAccessControlAndFlags(
        toDescriptor replacement: Int32,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        if let accessControlList {
            let failure = WorktreeForkMetadataTarget.descriptor(replacement).setAccessControlList(accessControlList)
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure)
            }
        }
        let reproducibleFlags = flags & WorktreeForkEntryMetadata.reproducibleFlagMask
        if reproducibleFlags != 0, fchflags(replacement, reproducibleFlags) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }
}

/// What was lifted from the file about to be replaced so that a swap can rename over it, plus the original
/// values needed to put it back. The swap needs neither user flags nor a `deny delete` entry on the target,
/// and reading the original (by libgit2 or for its extended attributes) needs owner read.
final class WorktreeForkReplacementProtection {
    /// Flags the owner may clear that forbid renaming over a file. System flags need privilege and fail.
    private static let userProtectionFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    private static let systemProtectionFlags = UInt32(SF_IMMUTABLE | SF_APPEND)

    private let mode: mode_t
    private let flags: UInt32
    private let identity: WorktreeForkEntryIdentity
    private var accessControlList: acl_t?

    private init(_ info: Darwin.stat) {
        mode = info.st_mode & 0o7777
        flags = info.st_flags
        identity = WorktreeForkEntryIdentity(info)
    }

    deinit {
        if let accessControlList {
            acl_free(UnsafeMutableRawPointer(accessControlList))
        }
    }

    /// Nil when no regular file is at `url`. On failure the original keeps its protection.
    static func lift(at url: URL, reportPath: String) throws(GitWorktreeForkError) -> WorktreeForkReplacementProtection?
    {
        var info = Darwin.stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return try lift(.path(url), originalInfo: info, reportPath: reportPath)
    }

    /// Lifts protection from the regular file `target` names, whose state before any change is `originalInfo`.
    /// On failure the original keeps its protection.
    static func lift(
        _ target: WorktreeForkMetadataTarget,
        originalInfo info: Darwin.stat,
        reportPath: String
    ) throws(GitWorktreeForkError) -> WorktreeForkReplacementProtection {
        guard info.st_flags & systemProtectionFlags == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: EPERM)
        }
        let protection = WorktreeForkReplacementProtection(info)
        do throws(GitWorktreeForkError) {
            try protection.lift(target, reportPath: reportPath)
        } catch {
            try? protection.restore(on: target, reportPath: reportPath)
            throw error
        }
        return protection
    }

    private func lift(_ target: WorktreeForkMetadataTarget, reportPath: String) throws(GitWorktreeForkError) {
        if flags & Self.userProtectionFlags != 0 {
            let failure = target.setFlags(flags & ~Self.userProtectionFlags)
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
        accessControlList = try target.accessControlList(reportPath: reportPath)
        if accessControlList != nil {
            let failure = target.removeAccessControlList()
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
        if mode & S_IRUSR == 0 {
            let failure = target.setMode(mode | S_IRUSR)
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
    }

    /// The replaced file's own metadata as it was before lifting, for a rewrite with no other template.
    func originalMetadata(at url: URL, reportPath: String) throws(GitWorktreeForkError) -> WorktreeForkFileMetadata {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        return WorktreeForkFileMetadata(
            mode: mode, flags: flags, accessControlList: accessControlList.flatMap { acl_dup($0) },
            descriptor: descriptor)
    }

    /// Whether the file at `url` is still the inode protection was lifted from.
    func isOriginal(at url: URL) -> Bool {
        guard case .success(let info) = WorktreeForkDescriptors.lstatPath(url) else {
            return false
        }
        return WorktreeForkEntryIdentity(info) == identity
    }

    /// Puts the lifted mode, ACL, and flags back on whichever file `target` names, flags last.
    func restore(at url: URL, reportPath: String) throws(GitWorktreeForkError) {
        try restore(on: .path(url), reportPath: reportPath)
    }

    func restore(on target: WorktreeForkMetadataTarget, reportPath: String) throws(GitWorktreeForkError) {
        var failure = target.setMode(mode)
        if failure == 0, let accessControlList {
            failure = target.setAccessControlList(accessControlList)
        }
        if failure == 0 {
            failure = target.setFlags(flags)
        }
        guard failure == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure)
        }
    }
}
