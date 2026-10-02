import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Where one re-homed Git node now lives.
struct WorktreeForkRehomedNode: Sendable {
    let node: WorktreeForkGitNode
    let destinationWorktree: URL
    let destinationAdministration: URL
}

/// Gives every initialized nested Git node destination-owned administration: submodules beneath the fork's
/// own `$GIT_DIR/modules/...` (as Git lays out a linked worktree's submodules), independent repositories as
/// embedded `.git` directories, and every object alternate a destination-owned CoW mirror. No administrative
/// pointer is copied as final; each is rewritten for the destination.
struct GitRepositoryStateRehomer: Sendable {
    let plan: WorktreeForkPlan
    let cancellation: WorktreeForkCancellation
    let lockTracker: WorktreeForkLockTracker

    init(
        plan: WorktreeForkPlan,
        cancellation: WorktreeForkCancellation,
        lockTracker: WorktreeForkLockTracker = WorktreeForkLockTracker()
    ) {
        self.plan = plan
        self.cancellation = cancellation
        self.lockTracker = lockTracker
    }

    var rootAdministration: URL {
        plan.commonDirectory.appending(path: "worktrees").appending(path: plan.worktreeName)
    }

    func rehome(journal: inout WorktreeForkRollbackJournal) throws(GitWorktreeForkError) -> [WorktreeForkRehomedNode] {
        let topology = plan.gitTopology
        if let rootSparse = topology.rootSparse {
            try writeSparseState(rootSparse, administration: rootAdministration, reportPath: ".")
        }
        let mirrorByStore = try mirrorObjectStores(topology.mirroredObjectStores, journal: &journal)
        var administrationByNode: [String: URL] = [:]
        var rehomed: [WorktreeForkRehomedNode] = []
        for node in topology.nodes {
            try cancellation.throwIfCancelled()
            let destinationWorktree = plan.destinationRoot.appending(path: node.relativePath)
            let administration = destinationAdministration(for: node, administrationByNode: administrationByNode)
            try requireBeneath(administration, reportPath: "\(node.relativePath)/.git")
            administrationByNode[node.relativePath] = administration
            if case .submodule = node.kind {
                journal.record(
                    .nestedAdministration(
                        path: administration,
                        reportLocation: String(administration.path.dropFirst(plan.commonDirectory.path.count + 1)),
                        identity: nil
                    ))
            }
            try rehome(
                node, worktree: destinationWorktree, administration: administration, mirrorByStore: mirrorByStore
            ) { identity in
                journal.confirmNestedAdministration(at: administration, identity: identity)
            }
            rehomed.append(
                WorktreeForkRehomedNode(
                    node: node, destinationWorktree: destinationWorktree, destinationAdministration: administration))
        }
        return rehomed
    }

    /// Defense in depth behind the planner's name rule: destination administration must sit beneath the
    /// fork's own administration or the destination tree, compared by path components, never by prefix.
    private func requireBeneath(_ administration: URL, reportPath: String) throws(GitWorktreeForkError) {
        let components = administration.pathComponents
        let isBeneath = [rootAdministration, plan.destinationRoot].contains { root in
            let rootComponents = root.pathComponents
            return components.count > rootComponents.count
                && Array(components.prefix(rootComponents.count)) == rootComponents
        }
        guard isBeneath, !components.contains(".."), !components.contains(".") else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
    }

    private func destinationAdministration(
        for node: WorktreeForkGitNode,
        administrationByNode: [String: URL]
    ) -> URL {
        switch node.kind {
        case .submodule(let name):
            let parentAdministration =
                node.parentRelativePath.flatMap { administrationByNode[$0] } ?? rootAdministration
            return parentAdministration.appending(path: "modules").appending(path: name)
        case .embeddedRepository, .flattenedRepository:
            return plan.destinationRoot.appending(path: node.relativePath).appending(path: ".git")
        }
    }

    private func rehome(
        _ node: WorktreeForkGitNode,
        worktree: URL,
        administration: URL,
        mirrorByStore: [URL: URL],
        created: (WorktreeForkEntryIdentity) -> Void
    ) throws(GitWorktreeForkError) {
        let reportPath = "\(node.relativePath)/.git"
        var cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
        cloner.symlinkTargets = try symlinkTargets(node, administration: administration, mirrorByStore: mirrorByStore)
        try cloner.cloneTree(from: node.sourceCommonDirectory, to: administration, created: created)
        if node.sourceGitDirectory != node.sourceCommonDirectory {
            try overlayPrivateAdministration(node, administration: administration, reportPath: reportPath)
        }
        try writeText(headContents(node), to: administration.appending(path: "HEAD"), reportPath: reportPath)
        try writeAlternates(node, administration: administration, mirrorByStore: mirrorByStore, reportPath: reportPath)

        var configurationEdits: [WorktreeForkConfigurationEdit] = [.setBool("core.bare", false)]
        switch node.kind {
        case .submodule:
            configurationEdits.append(
                .setString("core.worktree", WorktreeForkRelativePath.from(administration, to: worktree)))
        case .embeddedRepository, .flattenedRepository:
            configurationEdits.append(.delete("core.worktree"))
        }
        if node.sparse != nil {
            configurationEdits.append(.setBool("index.sparse", false))
        }
        try WorktreeForkConfigurationFile.apply(
            configurationEdits,
            to: administration.appending(path: "config"),
            lockTracker: lockTracker
        )
        if case .submodule = node.kind {
            let pointer = "gitdir: \(WorktreeForkRelativePath.from(worktree, to: administration))\n"
            try writeText(pointer, to: worktree.appending(path: ".git"), reportPath: reportPath)
        }
        if let sparse = node.sparse {
            try writeSparseState(sparse, administration: administration, reportPath: reportPath)
        }
        try sanitizeWorktreeConfiguration(in: administration)
    }

    /// Destination link text for each classified administrative symlink: internal links point at the
    /// destination copy of their target, external stores at their destination-owned mirror.
    private func symlinkTargets(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL]
    ) throws(GitWorktreeForkError) -> [String: String] {
        var targets: [String: String] = [:]
        for (relativePath, symlink) in node.administrativeSymlinks {
            switch symlink {
            case .internalTarget(let relativeTarget):
                let linkDirectory = administration.appending(path: relativePath).deletingLastPathComponent()
                targets[relativePath] = WorktreeForkRelativePath.from(
                    linkDirectory, to: administration.appending(path: relativeTarget))
            case .externalStore(let store):
                guard let mirror = mirrorByStore[store] else {
                    throw .entryFailed(
                        relativePath: "\(node.relativePath)/.git", reason: .unresolvableGitAdministration,
                        errorNumber: nil)
                }
                targets[relativePath] = mirror.path
            }
        }
        return targets
    }

    /// A gitfile-reached node keeps its worktree-private identity (`HEAD` is rewritten from the plan) and
    /// worktree configuration; its common administration was cloned above.
    private func overlayPrivateAdministration(
        _ node: WorktreeForkGitNode,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        // The cloned common directory's config.worktree belongs to that repository's main worktree, not
        // to this one; only the node's own worktree-private configuration may carry over.
        let destinationConfiguration = administration.appending(path: "config.worktree")
        if case .success = WorktreeForkDescriptors.lstatPath(destinationConfiguration),
            (try? FileManager.default.removeItem(at: destinationConfiguration)) == nil
        {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: nil)
        }
        let privateConfiguration = node.sourceGitDirectory.appending(path: "config.worktree")
        if let contents = try? Data(contentsOf: privateConfiguration) {
            try writeData(contents, to: destinationConfiguration, reportPath: reportPath)
        }
    }

    /// A worktree-scoped `core.worktree` (Git moves the main worktree's there when worktree config is
    /// enabled) or `core.bare` would point the destination at the source; neither is ever carried over.
    private func sanitizeWorktreeConfiguration(in administration: URL) throws(GitWorktreeForkError) {
        let configuration = administration.appending(path: "config.worktree")
        guard case .success = WorktreeForkDescriptors.lstatPath(configuration) else {
            return
        }
        try WorktreeForkConfigurationFile.apply(
            [.delete("core.worktree"), .delete("core.bare")], to: configuration, lockTracker: lockTracker)
    }

    private func headContents(_ node: WorktreeForkGitNode) -> String {
        if let headReferenceName = node.headReferenceName {
            return "ref: \(headReferenceName)\n"
        }
        return "\(node.capturedHead?.commitOID ?? "")\n"
    }

    private func writeAlternates(
        _ node: WorktreeForkGitNode,
        administration: URL,
        mirrorByStore: [URL: URL],
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let direct = try Self.directAlternates(node.sourceCommonDirectory.appending(path: "objects"), reportPath)
        guard !direct.isEmpty else {
            return
        }
        let lines = direct.compactMap { mirrorByStore[$0]?.path }
        guard lines.count == direct.count else {
            throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
        }
        try writeText(
            lines.joined(separator: "\n") + "\n",
            to: administration.appending(path: WorktreeForkAdministrationCloner.alternatesRelativePath),
            reportPath: reportPath
        )
    }

    /// Mirrors each borrowed object store once, beneath the fork's own administration, and points each
    /// mirror's own alternates at the corresponding mirrors so the closure never leaves destination state.
    private func mirrorObjectStores(
        _ stores: [URL],
        journal: inout WorktreeForkRollbackJournal
    ) throws(GitWorktreeForkError) -> [URL: URL] {
        var mirrorByStore: [URL: URL] = [:]
        for (index, store) in stores.enumerated() {
            let mirror = rootAdministration.appending(path: "agentstudio-object-mirrors").appending(path: "\(index)")
            let location = "worktrees/\(plan.worktreeName)/agentstudio-object-mirrors/\(index)"
            journal.record(.nestedAdministration(path: mirror, reportLocation: location, identity: nil))
            var cloner = WorktreeForkAdministrationCloner(reportPath: location)
            cloner.symlinkTargets = plan.gitTopology.mirroredStoreSymlinks[store] ?? [:]
            try cloner.cloneTree(from: store, to: mirror) { identity in
                journal.confirmNestedAdministration(at: mirror, identity: identity)
            }
            mirrorByStore[store] = mirror
        }
        for store in stores {
            guard let mirror = mirrorByStore[store] else {
                continue
            }
            let direct = try Self.directAlternates(store, "")
            if !direct.isEmpty {
                let lines = direct.compactMap { mirrorByStore[$0]?.path }.joined(separator: "\n")
                try writeText(lines + "\n", to: mirror.appending(path: "info/alternates"), reportPath: ".")
            }
        }
        return mirrorByStore
    }

    private func writeSparseState(
        _ sparse: WorktreeForkSparsePlan,
        administration: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        try writeData(
            sparse.patternFile, to: administration.appending(path: "info/sparse-checkout"), reportPath: reportPath)
        guard let worktreeConfiguration = sparse.worktreeConfiguration else {
            return
        }
        let destination = administration.appending(path: "config.worktree")
        try writeData(worktreeConfiguration, to: destination, reportPath: reportPath)
        try WorktreeForkConfigurationFile.apply(
            [.setBool("index.sparse", false), .delete("core.worktree"), .delete("core.bare")],
            to: destination,
            lockTracker: lockTracker
        )
    }

    static func directAlternates(_ objectsDirectory: URL, _ reportPath: String) throws(GitWorktreeForkError) -> [URL] {
        try WorktreeForkGitTopologyPlanner.alternateLines(objectsDirectory).map { line throws(GitWorktreeForkError) in
            let candidate = line.hasPrefix("/") ? URL(fileURLWithPath: line) : objectsDirectory.appending(path: line)
            guard case .success(let canonical) = WorktreeForkDescriptors.realpathURL(candidate) else {
                throw .entryFailed(relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: nil)
            }
            return canonical
        }
    }

    private func writeText(_ text: String, to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        try writeData(Data(text.utf8), to: url, reportPath: reportPath)
    }

    private func writeData(_ data: Data, to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .entryFailed(
                relativePath: reportPath, reason: .entryCreationFailed, errorNumber: Self.errorNumber(of: error))
        }
        try replaceFilePreservingMetadata(url, with: data, reportPath: reportPath)
    }

    /// Replaces `url` with `data` on a fresh same-directory inode renamed into place. Cloned administration
    /// keeps the source's metadata: SwiftPM makes `.git/HEAD` read-only, and a user-immutable or append-only
    /// flag or a `deny delete` ACL entry forbids writing in place and renaming over the file alike. That
    /// protection is lifted from our own clone, and the new inode receives the replaced file's mode, extended
    /// attributes, ACL, and flags, the flags last. Every replaced file is a per-file clone made by this fork,
    /// so lifting its protection never reaches another path.
    private func replaceFilePreservingMetadata(
        _ url: URL,
        with data: Data,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let replaced = try WorktreeForkReplacedFile.liftProtection(from: url, reportPath: reportPath)
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).agentstudio-\(UUID().uuidString).tmp")
        do throws(GitWorktreeForkError) {
            try Self.writeReplacement(data, at: temporary, replacing: replaced, reportPath: reportPath)
            guard rename(temporary.path, url.path) == 0 else {
                let failure = errno
                _ = unlink(temporary.path)
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        } catch {
            replaced?.restoreProtection(at: url)
            throw error
        }
        try replaced?.reapplyProtection(to: url, reportPath: reportPath)
    }

    /// Creates `temporary` holding `data` with the replaced file's mode and extended attributes, or 0644 and
    /// none when nothing is replaced. Removes it again on failure.
    private static func writeReplacement(
        _ data: Data,
        at temporary: URL,
        replacing replaced: WorktreeForkReplacedFile?,
        reportPath: String
    ) throws(GitWorktreeForkError) {
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        do throws(GitWorktreeForkError) {
            var failure: Int32?
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count, failure == nil {
                    let written = write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno != EINTR { failure = errno }
                    } else {
                        offset += written
                    }
                }
            }
            if let failure {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
            if let replaced {
                try WorktreeForkEntryMetadata.copyExtendedAttributes(
                    from: replaced.descriptor, to: descriptor, relativePath: reportPath)
            }
            guard fchmod(descriptor, replaced?.mode ?? 0o644) == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
            }
        } catch {
            _ = close(descriptor)
            _ = unlink(temporary.path)
            throw error
        }
        guard close(descriptor) == 0 else {
            let failure = errno
            _ = unlink(temporary.path)
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
        }
    }

    private static func errorNumber(of error: Error) -> Int32? {
        ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { Int32($0.code) }
    }
}

/// A cloned regular file about to be replaced, with the protection that would block replacing it lifted. It
/// keeps what the replacement must reproduce: mode, flags, the extended ACL, and a descriptor through which
/// the original's extended attributes are read.
private final class WorktreeForkReplacedFile {
    /// Flags the owner may clear that forbid renaming over a file. System flags need privilege and fail.
    private static let userProtectionFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    private static let systemProtectionFlags = UInt32(SF_IMMUTABLE | SF_APPEND)

    let mode: mode_t
    private(set) var descriptor: Int32 = -1
    private let flags: UInt32
    private var accessControlList: acl_t?

    private init(_ info: Darwin.stat) {
        mode = info.st_mode & 0o7777
        flags = info.st_flags
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
        if let accessControlList {
            acl_free(UnsafeMutableRawPointer(accessControlList))
        }
    }

    /// Nil when no regular file is at `url`; the replacement is then a new 0644 file with no inherited
    /// metadata. On failure the original keeps its protection.
    static func liftProtection(
        from url: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) -> WorktreeForkReplacedFile? {
        var info = Darwin.stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        guard info.st_flags & systemProtectionFlags == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: EPERM)
        }
        let replaced = WorktreeForkReplacedFile(info)
        do throws(GitWorktreeForkError) {
            try replaced.lift(at: url, reportPath: reportPath)
        } catch {
            replaced.restoreProtection(at: url)
            throw error
        }
        return replaced
    }

    private func lift(at url: URL, reportPath: String) throws(GitWorktreeForkError) {
        if flags & Self.userProtectionFlags != 0, lchflags(url.path, flags & ~Self.userProtectionFlags) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        // The owner may always read and replace a file's ACL, even one that denies reading the file.
        accessControlList = acl_get_link_np(url.path, ACL_TYPE_EXTENDED)
        if accessControlList == nil, errno != ENOENT {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
        if accessControlList != nil {
            let failure = Self.removeAccessControlList(at: url)
            guard failure == 0 else {
                throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
        // Reading extended attributes needs a readable descriptor, which the original's mode may withhold.
        descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if descriptor < 0, errno == EACCES, lchmod(url.path, mode | S_IRUSR) == 0 {
            descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        }
        guard descriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
    }

    /// Puts the lifted protection back on the original while it is still at `url`. Best effort: the caller is
    /// already failing the fork.
    func restoreProtection(at url: URL) {
        _ = lchmod(url.path, mode)
        if let accessControlList {
            _ = acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList)
        }
        _ = lchflags(url.path, flags)
    }

    /// Gives the replacement now at `url` the original's ACL and flags. Both are applied after the rename
    /// because each can forbid it; flags go last because an immutable file accepts no further change.
    func reapplyProtection(to url: URL, reportPath: String) throws(GitWorktreeForkError) {
        let reproducibleFlags = flags & WorktreeForkEntryMetadata.reproducibleFlagMask
        if let accessControlList, acl_set_link_np(url.path, ACL_TYPE_EXTENDED, accessControlList) != 0 {
            let failure = errno
            _ = lchflags(url.path, reproducibleFlags)
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: failure)
        }
        if reproducibleFlags != 0, lchflags(url.path, reproducibleFlags) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .metadataNotReproducible, errorNumber: errno)
        }
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

enum WorktreeForkConfigurationEdit: Sendable {
    case setBool(String, Bool)
    case setString(String, String)
    case delete(String)
}

/// Edits one Git configuration file through libgit2 so its syntax and locking stay Git's.
enum WorktreeForkConfigurationFile {
    static func apply(
        _ edits: [WorktreeForkConfigurationEdit],
        to path: URL,
        lockTracker: WorktreeForkLockTracker? = nil
    ) throws(GitWorktreeForkError) {
        var configuration: OpaquePointer?
        let openResult = path.path.withCString { git_config_open_ondisk(&configuration, $0) }
        guard openResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: openResult))
        }
        defer { git_config_free(configuration) }
        let lockFact = GitLockFact(
            path: URL(fileURLWithPath: "\(path.path).lock").standardizedFileURL,
            resource: .config
        )
        for edit in edits {
            lockTracker?.beginAttempt(for: [lockFact])
            errno = 0
            let result: Int32
            switch edit {
            case .setBool(let name, let value):
                result = git_config_set_bool(configuration, name, value ? 1 : 0)
            case .setString(let name, let value):
                result = git_config_set_string(configuration, name, value)
            case .delete(let name):
                let deleteResult = git_config_delete_entry(configuration, name)
                result = deleteResult == GIT_ENOTFOUND.rawValue ? 0 : deleteResult
            }
            let systemErrorCode = errno
            guard result >= 0 else {
                lockTracker?.recordFailure(for: [lockFact])
                throw .gitFailure(
                    LibGit2ErrorCapture.failure(
                        code: result,
                        lockFacts: [lockFact],
                        systemErrorCode: systemErrorCode
                    ))
            }
        }
    }
}

enum WorktreeForkRelativePath {
    /// Relative path from directory `origin` to `target`; both are canonical absolute paths.
    static func from(_ origin: URL, to target: URL) -> String {
        let originComponents = origin.pathComponents
        let targetComponents = target.pathComponents
        var shared = 0
        while shared < min(originComponents.count, targetComponents.count),
            originComponents[shared] == targetComponents[shared]
        {
            shared += 1
        }
        let ascent = Array(repeating: "..", count: originComponents.count - shared)
        let descent = targetComponents[shared...]
        let components = ascent + descent
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}
