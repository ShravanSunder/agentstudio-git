import AgentStudioGitContracts
import Darwin
import Foundation

/// Re-homing rewrites cloned administrative files (`HEAD`, alternates, sparse state, configuration) by
/// swapping a new inode in at the path: our own temporary-file rename, or libgit2's lock-file rename. A fresh
/// inode drops the replaced file's metadata, and a user-immutable or append-only flag or a `deny delete` ACL
/// entry forbids the swap itself. The specification makes loss of ACL access semantics, extended attributes,
/// or file flags a failure, so every such rewrite goes through here.
enum WorktreeForkMetadataPreservingRewrite {
    /// Runs `swapInReplacement`, which leaves a new regular file at `url`, then gives that file the mode,
    /// extended attributes, ACL, and flags of `template` (a source counterpart whose destination copy was
    /// removed or never existed), falling back to the file being replaced. With neither, the new file keeps
    /// the swap's own mode and is reported as nothing. Protection on the replaced file is lifted only from our
    /// own clone; every replaced file is a per-file clone made by this fork, so that never reaches another path.
    /// A swap may also leave the original in place (libgit2 skips an edit that changes nothing); then only the
    /// lifted protection goes back.
    static func rewrite(
        _ url: URL,
        metadataFrom template: URL? = nil,
        reportPath: String,
        swapInReplacement: () throws(GitWorktreeForkError) -> Void
    ) throws(GitWorktreeForkError) {
        let protection = try WorktreeForkReplacementProtection.lift(at: url, reportPath: reportPath)
        do throws(GitWorktreeForkError) {
            var metadata: WorktreeForkFileMetadata?
            if let template {
                metadata = try WorktreeForkFileMetadata.capture(from: template, reportPath: reportPath)
            }
            if metadata == nil {
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

/// The mode, flags, extended ACL, and extended attributes a rewritten file must carry. Extended attributes
/// are read through `descriptor` when applied, which keeps the template's inode alive even after the swap
/// unlinks it.
private final class WorktreeForkFileMetadata {
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
        let accessControlList = try WorktreeForkReplacementProtection.accessControlList(
            at: template, reportPath: reportPath)
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

    /// Applies everything to the regular file now at `url`: extended attributes while it is still writable,
    /// then mode and ACL, and flags last because an immutable file accepts no further change.
    func apply(to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        let replacement = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard replacement >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        defer { _ = close(replacement) }
        try WorktreeForkEntryMetadata.copyExtendedAttributes(
            from: descriptor, to: replacement, relativePath: reportPath)
        guard fchmod(replacement, mode) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        if let accessControlList, acl_set_fd_np(replacement, accessControlList, ACL_TYPE_EXTENDED) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
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
private final class WorktreeForkReplacementProtection {
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
        guard info.st_flags & systemProtectionFlags == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: EPERM)
        }
        let protection = WorktreeForkReplacementProtection(info)
        do throws(GitWorktreeForkError) {
            try protection.lift(at: url, reportPath: reportPath)
        } catch {
            try? protection.restore(at: url, reportPath: reportPath)
            throw error
        }
        return protection
    }

    private func lift(at url: URL, reportPath: String) throws(GitWorktreeForkError) {
        if flags & Self.userProtectionFlags != 0, lchflags(url.path, flags & ~Self.userProtectionFlags) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        accessControlList = try Self.accessControlList(at: url, reportPath: reportPath)
        if accessControlList != nil {
            let failure = Self.removeAccessControlList(at: url)
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
        if mode & S_IRUSR == 0, lchmod(url.path, mode | S_IRUSR) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
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

    /// Puts the lifted mode, ACL, and flags back on whichever file is at `url`, flags last.
    func restore(at url: URL, reportPath: String) throws(GitWorktreeForkError) {
        guard lchmod(url.path, mode) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        if let accessControlList, acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        guard lchflags(url.path, flags) == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    /// The file's extended ACL, or nil when it has none. The owner may always read an ACL, even one that
    /// denies reading the file.
    static func accessControlList(at url: URL, reportPath: String) throws(GitWorktreeForkError) -> acl_t? {
        if let accessControlList = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) {
            return accessControlList
        }
        guard errno == ENOENT else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        return nil
    }

    /// Setting an empty extended ACL removes it. Returns the failing errno, or 0.
    private static func removeAccessControlList(at url: URL) -> Int32 {
        guard let empty = acl_init(0) else {
            return errno
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty) == 0 ? 0 : errno
    }
}
