import Foundation

/// Selects the destination Git identity of a Worktree Fork. Every mode resolves to the source
/// worktree's captured `HEAD`; there is deliberately no start point, because a different base
/// would turn the copied filesystem into an ambiguous overlay.
public enum GitForkWorktreeMode: Equatable, Hashable, Sendable {
    /// Check out an existing local branch that already points at the captured `HEAD` and is not
    /// checked out in another worktree.
    case existingBranch(name: String)
    /// Create a new local branch at the captured `HEAD`.
    case newBranch(name: String)
    /// Detach the destination at the captured `HEAD` without creating any branch.
    case detached
}

extension GitForkWorktreeMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case existingBranch
        case newBranch
        case detached
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .existingBranch:
            self = .existingBranch(name: try container.decode(String.self, forKey: .name))
        case .newBranch:
            self = .newBranch(name: try container.decode(String.self, forKey: .name))
        case .detached:
            guard !container.contains(.name) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "detached fork modes must not carry a branch name"
                    ))
            }
            self = .detached
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .existingBranch(let name):
            try container.encode(Kind.existingBranch, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .newBranch(let name):
            try container.encode(Kind.newBranch, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .detached:
            try container.encode(Kind.detached, forKey: .kind)
        }
    }
}

public struct GitForkWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    /// An existing main or linked worktree whose current filesystem state is captured.
    public let sourceWorktreePath: URL
    /// A nonexistent destination whose parent exists on the source's clone-capable APFS volume.
    public let destinationPath: URL
    public let mode: GitForkWorktreeMode

    public init(sourceWorktreePath: URL, destinationPath: URL, mode: GitForkWorktreeMode) {
        self.sourceWorktreePath = sourceWorktreePath
        self.destinationPath = destinationPath
        self.mode = mode
    }
}

public struct GitForkWorktreeResult: Codable, Equatable, Hashable, Sendable {
    public let worktree: GitWorktreeSnapshot
    public let materialization: GitWorktreeMaterializationReport

    public init(worktree: GitWorktreeSnapshot, materialization: GitWorktreeMaterializationReport) {
        self.worktree = worktree
        self.materialization = materialization
    }
}

/// What a successful fork created, plus the entries it intentionally did not reproduce exactly.
/// A skipped entry has no destination node; a normalized entry exists with reported metadata loss.
public struct GitWorktreeMaterializationReport: Codable, Equatable, Hashable, Sendable {
    public let clonedRegularFileCount: Int
    public let createdDirectoryCount: Int
    public let recreatedSymbolicLinkCount: Int
    /// Destination paths realized as hard links to an already-cloned member of the same source inode group.
    public let preservedHardLinkCount: Int
    /// Initialized submodules and nested repositories given destination-owned administration.
    public let preservedGitRepositoryCount: Int
    public let recreatedFIFOCount: Int
    public let logicalRegularFileBytes: Int64
    public let skippedEntries: [GitWorktreeMaterializationSkippedEntry]
    public let normalizedEntries: [GitWorktreeMaterializationNormalizedEntry]

    public init(
        clonedRegularFileCount: Int,
        createdDirectoryCount: Int,
        recreatedSymbolicLinkCount: Int,
        preservedHardLinkCount: Int,
        preservedGitRepositoryCount: Int,
        recreatedFIFOCount: Int,
        logicalRegularFileBytes: Int64,
        skippedEntries: [GitWorktreeMaterializationSkippedEntry],
        normalizedEntries: [GitWorktreeMaterializationNormalizedEntry]
    ) {
        self.clonedRegularFileCount = clonedRegularFileCount
        self.createdDirectoryCount = createdDirectoryCount
        self.recreatedSymbolicLinkCount = recreatedSymbolicLinkCount
        self.preservedHardLinkCount = preservedHardLinkCount
        self.preservedGitRepositoryCount = preservedGitRepositoryCount
        self.recreatedFIFOCount = recreatedFIFOCount
        self.logicalRegularFileBytes = logicalRegularFileBytes
        self.skippedEntries = skippedEntries
        self.normalizedEntries = normalizedEntries
    }
}

public struct GitWorktreeMaterializationSkippedEntry: Codable, Equatable, Hashable, Sendable {
    /// Path relative to the worktree root; never absolute.
    public let relativePath: String
    public let kind: GitWorktreeFilesystemEntryKind
    public let reason: GitWorktreeMaterializationSkipReason

    public init(
        relativePath: String,
        kind: GitWorktreeFilesystemEntryKind,
        reason: GitWorktreeMaterializationSkipReason
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.reason = reason
    }
}

public struct GitWorktreeMaterializationNormalizedEntry: Codable, Equatable, Hashable, Sendable {
    /// Path relative to the worktree root; never absolute.
    public let relativePath: String
    public let attribute: GitWorktreeMetadataAttribute
    public let reason: GitWorktreeMetadataNormalizationReason

    public init(
        relativePath: String,
        attribute: GitWorktreeMetadataAttribute,
        reason: GitWorktreeMetadataNormalizationReason
    ) {
        self.relativePath = relativePath
        self.attribute = attribute
        self.reason = reason
    }
}

public enum GitWorktreeFilesystemEntryKind: String, Codable, CaseIterable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case fifo
    case unixSocket
    case characterDevice
    case blockDevice
    case unknown
}

public enum GitWorktreeMaterializationSkipReason: String, Codable, CaseIterable, Sendable {
    /// A socket pathname names a live endpoint, not data; recreating it would not recreate a listener.
    case unixSocketNotReproducible
}

public enum GitWorktreeMetadataAttribute: String, Codable, CaseIterable, Sendable {
    case ownerUser
    case ownerGroup
    case setUserIDBit
    case setGroupIDBit
}

public enum GitWorktreeMetadataNormalizationReason: String, Codable, CaseIterable, Sendable {
    /// An unprivileged caller cannot assign the source owner, so the destination belongs to the caller.
    case ownershipNotAssignable
    /// APFS clears setuid/setgid on a cloned regular file.
    case clearedByCopyOnWriteClone
}
