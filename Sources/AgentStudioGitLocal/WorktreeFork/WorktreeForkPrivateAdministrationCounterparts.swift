import AgentStudioGitContracts
import Darwin
import Foundation

/// Gives a re-homed configuration value a real file to name. Re-homing re-aims a value that names a captured
/// worktree's private administration (an `allowed_signers` or included `extra.conf` there) at the destination
/// administration, but only the files re-homing writes itself exist there. Git silently ignores a missing
/// include or signer file, so the named entry is strictly cloned from the source, with its metadata. A
/// source entry that does not exist stays absent, exactly as Git finds nothing in the source either.
///
/// Every counterpart lands inside administration the rollback journal already owns (the destination tree,
/// nested `modules/` administration, or the fork's own administration), so it needs no entry of its own.
struct WorktreeForkPrivateAdministrationCounterparts: Sendable {
    let plan: WorktreeForkPlan
    let relocation: WorktreeForkSourcePathRelocation
    /// Directories cloned here; their metadata is reproduced with the rest of the cloned administration.
    private(set) var administrationTrees: [WorktreeForkClonedAdministrationTree] = []
    private(set) var normalizedEntries: [GitWorktreeMaterializationNormalizedEntry] = []

    init(plan: WorktreeForkPlan, relocation: WorktreeForkSourcePathRelocation) {
        self.plan = plan
        self.relocation = relocation
    }

    /// Clones the topmost missing entry on the way from the destination administration to the counterpart of
    /// `source` (canonical), when `source` lies in a captured private administration and exists.
    mutating func materializeCounterpart(of source: URL) throws(GitWorktreeForkError) {
        guard let match = relocation.privateAdministrationMatch(of: source),
            case .success = WorktreeForkDescriptors.lstatPath(source)
        else {
            return
        }
        var sourceEntry = match.sourceAdministration
        var destinationEntry = match.destinationAdministration
        for component in match.remainder.split(separator: "/").map(String.init) {
            sourceEntry.append(path: component)
            destinationEntry.append(path: component)
            if case .failure = WorktreeForkDescriptors.lstatPath(destinationEntry) {
                try clone(sourceEntry, to: destinationEntry)
                return
            }
        }
    }

    private mutating func clone(_ source: URL, to destination: URL) throws(GitWorktreeForkError) {
        let reportPath = WorktreeForkDestinationOwnership.reportLocation(of: destination, plan: plan)
        let sourceInfo: Darwin.stat
        switch WorktreeForkDescriptors.lstatPath(source) {
        case .success(let info):
            sourceInfo = info
        case .failure(let failure) where failure.code == ENOENT:
            throw .sourceChanged(relativePath: reportPath, reason: .entryMissing)
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failure.code)
        }
        switch WorktreeForkEntryKind(mode: sourceInfo.st_mode) {
        case .regularFile:
            normalizedEntries += try WorktreeForkDatalessPolicy.withMaterializationDenied(reportPath: reportPath) {
                () throws(GitWorktreeForkError) in
                try Self.cloneRegularFile(source, to: destination, reportPath: reportPath)
            }
        case .directory:
            let cloner = WorktreeForkAdministrationCloner(reportPath: reportPath)
            administrationTrees.append(try cloner.cloneTree(from: source, to: destination))
        case .symbolicLink, .fifo, .unixSocket, .characterDevice, .blockDevice, .unknown:
            throw .entryFailed(relativePath: reportPath, reason: .unsupportedEntryKind, errorNumber: nil)
        }
    }

    private static func cloneRegularFile(
        _ source: URL,
        to destination: URL,
        reportPath: String
    ) throws(GitWorktreeForkError) -> [GitWorktreeMaterializationNormalizedEntry] {
        let sourceDescriptor = source.path.withCString { open($0, WorktreeForkLeafWorker.leafOpenFlags) }
        guard sourceDescriptor >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: errno)
        }
        defer { close(sourceDescriptor) }
        let sourceInfo: Darwin.stat
        switch WorktreeForkDescriptors.statDescriptor(sourceDescriptor) {
        case .success(let info) where info.st_mode & S_IFMT == S_IFREG:
            sourceInfo = info
        case .success:
            throw .sourceChanged(relativePath: reportPath, reason: .entryKindChanged)
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .unreadableEntry, errorNumber: failure.code)
        }
        if sourceInfo.st_flags & UInt32(SF_DATALESS) != 0 {
            throw .entryFailed(relativePath: reportPath, reason: .datalessFile, errorNumber: nil)
        }
        let parent = destination.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parent >= 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: errno)
        }
        defer { close(parent) }
        let cloned = destination.lastPathComponent.withCString {
            fclonefileat(sourceDescriptor, parent, $0, WorktreeForkLeafWorker.cloneFlags)
        }
        guard cloned == 0 else {
            throw .entryFailed(relativePath: reportPath, reason: .strictCloneFailed, errorNumber: errno)
        }
        switch WorktreeForkDescriptors.lstatPath(destination) {
        case .success(let destinationInfo):
            return try WorktreeForkEntryMetadata.normalization(
                source: sourceInfo, destination: destinationInfo, relativePath: reportPath)
        case .failure(let failure):
            throw .entryFailed(relativePath: reportPath, reason: .entryCreationFailed, errorNumber: failure.code)
        }
    }
}
