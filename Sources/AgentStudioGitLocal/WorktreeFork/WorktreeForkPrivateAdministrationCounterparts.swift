import AgentStudioGitContracts
import Darwin
import Foundation

/// Gives a re-homed configuration value the right file to name. Re-homing re-aims a value that names a
/// captured worktree's private administration (an `allowed_signers` or included `extra.conf` there) at the
/// destination administration, but only the files re-homing writes itself come from that private source. Git
/// silently ignores a missing include or signer file, and a flattened node's administration is cloned from
/// the common administration, which may hold a different file under the same name. Git reads the
/// worktree-private file, so the private source wins: a missing counterpart is strictly cloned, and an
/// existing one that is not equivalent to it is replaced through the metadata-preserving rewrite. A source
/// entry that does not exist stays absent, exactly as Git finds nothing in the source either.
///
/// Every traversal is descriptor-relative beneath the two administration roots, so a symlink swapped into
/// either path fails instead of escaping. Every counterpart lands inside administration the rollback journal
/// already owns (the destination tree, nested `modules/` administration, or the fork's own administration),
/// so it needs no entry of its own.
struct WorktreeForkPrivateAdministrationCounterparts: Sendable {
    /// Private files re-homing writes itself from their source (rewritten or rebuilt), so a value naming one
    /// already has its counterpart and its bytes legitimately differ from the source.
    static let filesWrittenByRehoming: Set<String> = ["HEAD", "config.worktree", "info/sparse-checkout", "index"]

    /// What one realization produced.
    enum Realization: Sendable {
        case unchanged
        case clonedFile([GitWorktreeMaterializationNormalizedEntry])
        case clonedDirectory(WorktreeForkClonedAdministrationTree)
    }

    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation
    /// Directories cloned here; their metadata is reproduced with the rest of the cloned administration.
    private(set) var administrationTrees: [WorktreeForkClonedAdministrationTree] = []
    private(set) var normalizedEntries: [GitWorktreeMaterializationNormalizedEntry] = []

    init(plan: WorktreeForkPlan, relocation: WorktreeForkSourcePathRelocation) {
        self.plan = plan
        self.relocation = relocation
    }

    /// Realizes the counterpart of `source` (canonical) when it lies in a captured private administration.
    mutating func materializeCounterpart(of source: URL) throws(GitWorktreeForkError) {
        guard let match = relocation.privateAdministrationMatch(of: source),
            !Self.filesWrittenByRehoming.contains(match.remainder)
        else {
            return
        }
        let plan = plan
        let realization = try Self.realize(match) { remainder in
            WorktreeForkDestinationOwnership.reportLocation(
                of: match.destinationAdministration.appending(path: remainder), plan: plan)
        }
        switch realization {
        case .unchanged:
            return
        case .clonedFile(let normalized):
            normalizedEntries += normalized
        case .clonedDirectory(let tree):
            administrationTrees.append(tree)
        }
    }

    /// Walks `match.remainder` beneath both administration roots one component at a time. The topmost
    /// destination entry that is missing is cloned from its source; an existing regular-file target that is
    /// not equivalent to its source is replaced. `reportPath` maps a remainder prefix to its report location.
    static func realize(
        _ match: WorktreeForkSourcePathRelocation.PrivateAdministrationMatch,
        reportPath: (String) -> String
    ) throws(GitWorktreeForkError) -> Realization {
        let sourceRoot = try openRoot(match.sourceAdministration, reportPath: reportPath(""))
        defer { close(sourceRoot) }
        let destinationRoot = try openRoot(match.destinationAdministration, reportPath: reportPath(""))
        defer { close(destinationRoot) }
        let components = match.remainder.split(separator: "/").map(String.init)
        var parentPath = ""
        for (index, name) in components.enumerated() {
            let entryPath = WorktreeForkDescriptors.joined(parentPath, name)
            let report = reportPath(entryPath)
            let sourceParent = try openContainedDirectory(sourceRoot, parentPath, report, isSource: true)
            defer { close(sourceParent) }
            let destinationParent = try openContainedDirectory(destinationRoot, parentPath, report, isSource: false)
            defer { close(destinationParent) }
            guard let sourceInfo = try entryInfo(in: sourceParent, name: name, report: report) else {
                return .unchanged
            }
            let destinationInfo = try entryInfo(in: destinationParent, name: name, report: report)
            let sourceKind = WorktreeForkEntryKind(mode: sourceInfo.st_mode)
            let isTarget = index == components.count - 1
            switch (sourceKind, destinationInfo.map { WorktreeForkEntryKind(mode: $0.st_mode) }) {
            case (.symbolicLink, _):
                guard isTarget else {
                    throw .sourceChanged(relativePath: report, reason: .containmentEscape)
                }
                throw .entryFailed(relativePath: report, reason: .unsupportedEntryKind, errorNumber: nil)
            case (.directory, nil):
                let cloner = WorktreeForkAdministrationCloner(reportPath: report)
                return .clonedDirectory(
                    try cloner.cloneTree(
                        from: match.sourceAdministration.appending(path: entryPath),
                        to: match.destinationAdministration.appending(path: entryPath)))
            case (.directory, .directory) where !isTarget:
                parentPath = entryPath
            case (.regularFile, nil) where isTarget:
                return .clonedFile(
                    try cloneFile(name, from: sourceParent, into: destinationParent, report: report))
            case (.regularFile, .regularFile) where isTarget:
                return try replaceIfDifferent(
                    name, sourceParent: sourceParent, destinationParent: destinationParent,
                    destination: match.destinationAdministration.appending(path: entryPath), report: report)
            case (.regularFile, _) where !isTarget:
                return .unchanged
            case (.fifo, _), (.unixSocket, _), (.characterDevice, _), (.blockDevice, _), (.unknown, _):
                throw .entryFailed(relativePath: report, reason: .unsupportedEntryKind, errorNumber: nil)
            default:
                // A destination entry of another kind, or an existing directory target, cannot be made the
                // private source's counterpart without discarding what is there.
                throw .entryFailed(relativePath: report, reason: .unresolvableGitAdministration, errorNumber: nil)
            }
        }
        return .unchanged
    }

    private static func replaceIfDifferent(
        _ name: String,
        sourceParent: Int32,
        destinationParent: Int32,
        destination: URL,
        report: String
    ) throws(GitWorktreeForkError) -> Realization {
        let source = try openSourceFile(name, in: sourceParent, report: report)
        defer { close(source) }
        let existing = name.withCString {
            openat(destinationParent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if existing >= 0 {
            defer { close(existing) }
            if WorktreeForkFileEquivalence.isEquivalent(source, existing) {
                return .unchanged
            }
        }
        try WorktreeForkMetadataPreservingRewrite.rewrite(
            destination, metadataFrom: .sourceDescriptor(source), reportPath: report
        ) { () throws(GitWorktreeForkError) in
            let temporary = ".\(name).agentstudio-\(UUID().uuidString).tmp"
            try cloneUnprotected(source, as: temporary, into: destinationParent, report: report)
            let renamed = temporary.withCString { temporaryName in
                name.withCString { renameat(destinationParent, temporaryName, destinationParent, $0) }
            }
            guard renamed == 0 else {
                let failure = errno
                _ = temporary.withCString { unlinkat(destinationParent, $0, 0) }
                throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: failure)
            }
        }
        return .clonedFile(try normalization(source: source, name: name, in: destinationParent, report: report))
    }

    private static func cloneFile(
        _ name: String,
        from sourceParent: Int32,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        let source = try openSourceFile(name, in: sourceParent, report: report)
        defer { close(source) }
        try strictClone(source, as: name, into: destinationParent, report: report)
        return try normalization(source: source, name: name, in: destinationParent, report: report)
    }

    /// Clones under a temporary name with the clone's flags and ACL cleared and owner write granted, because a
    /// user-immutable flag or a `deny delete` entry would forbid renaming it into place and a read-only mode
    /// would refuse its extended attributes; the rewrite then applies the source's mode, ACL, and flags.
    private static func cloneUnprotected(
        _ source: Int32,
        as temporary: String,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) {
        try strictClone(source, as: temporary, into: destinationParent, report: report)
        let clone = temporary.withCString { openat(destinationParent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        var failure: Int32?
        if clone < 0 {
            failure = errno
        } else {
            if fchflags(clone, 0) != 0 { failure = errno }
            if failure == nil, fchmod(clone, 0o600) != 0 { failure = errno }
            if failure == nil, let empty = acl_init(0) {
                if acl_set_fd_np(clone, empty, ACL_TYPE_EXTENDED) != 0 { failure = errno }
                acl_free(UnsafeMutableRawPointer(empty))
            }
            close(clone)
        }
        if let failure {
            _ = temporary.withCString { unlinkat(destinationParent, $0, 0) }
            throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: failure)
        }
    }

    private static func strictClone(
        _ source: Int32,
        as name: String,
        into destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) {
        try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: report) {
            () throws(GitWorktreeForkError) in
            let cloned = name.withCString {
                fclonefileat(source, destinationParent, $0, WorktreeForkLeafWorker.cloneFlags)
            }
            guard cloned == 0 else {
                throw .entryFailed(relativePath: report, reason: .strictCloneFailed, errorNumber: errno)
            }
        }
    }

    private static func openSourceFile(
        _ name: String,
        in sourceParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> Int32 {
        let source = name.withCString { openat(sourceParent, $0, WorktreeForkLeafWorker.leafOpenFlags) }
        guard source >= 0 else {
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: errno)
        }
        switch WorktreeForkDescriptors.statDescriptor(source) {
        case .success(let info) where info.st_mode & S_IFMT == S_IFREG:
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
                close(source)
                throw .entryFailed(relativePath: report, reason: .datalessFile, errorNumber: nil)
            }
            return source
        case .success:
            close(source)
            throw .sourceChanged(relativePath: report, reason: .entryKindChanged)
        case .failure(let failure):
            close(source)
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private static func normalization(
        source: Int32,
        name: String,
        in destinationParent: Int32,
        report: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        guard case .success(let sourceInfo) = WorktreeForkDescriptors.statDescriptor(source) else {
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: nil)
        }
        switch WorktreeForkDescriptors.statEntry(in: destinationParent, name: name) {
        case .success(let destinationInfo):
            return try WorktreeForkEntryMetadata.normalization(
                source: sourceInfo, destination: destinationInfo, relativePath: report)
        case .failure(let failure):
            throw .entryFailed(relativePath: report, reason: .entryCreationFailed, errorNumber: failure.code)
        }
    }

    /// The entry's lstat information, or nil when it does not exist.
    private static func entryInfo(
        in parent: Int32,
        name: String,
        report: String
    ) throws(GitWorktreeForkError) -> Darwin.stat? {
        switch WorktreeForkDescriptors.statEntry(in: parent, name: name) {
        case .success(let info):
            return info
        case .failure(let failure) where failure.code == ENOENT:
            return nil
        case .failure(let failure):
            throw .entryFailed(relativePath: report, reason: .unreadableEntry, errorNumber: failure.code)
        }
    }

    private static func openRoot(_ root: URL, reportPath: String) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openRoot(atCanonicalPath: root) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure):
            throw .entryFailed(
                relativePath: reportPath, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }

    /// Opens `relativePath` beneath `root` with no symlink anywhere in it. A symlink in the source path is a
    /// containment escape; anything else that stops the open fails the counterpart.
    private static func openContainedDirectory(
        _ root: Int32,
        _ relativePath: String,
        _ report: String,
        isSource: Bool
    ) throws(GitWorktreeForkError) -> Int32 {
        switch WorktreeForkDescriptors.openDirectory(beneath: root, relativePath: relativePath) {
        case .success(let descriptor):
            return descriptor
        case .failure(let failure) where isSource && (failure.code == ELOOP || failure.code == ENOTDIR):
            throw .sourceChanged(relativePath: report, reason: .containmentEscape)
        case .failure(let failure):
            throw .entryFailed(
                relativePath: report, reason: .unresolvableGitAdministration, errorNumber: failure.code)
        }
    }
}
