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

/// Selects how the destination worktree receives its filesystem contents.
public enum GitWorktreeForkMaterialization: String, Codable, CaseIterable, Hashable, Sendable {
    /// Strict APFS clone of the source worktree's filesystem.
    case copyOnWrite
    /// Clean checkout of captured HEAD with only the source's carried paths overlaid.
    case changesOnly
}

public enum GitPathPatternError: Error, Equatable, Hashable, Sendable {
    case empty
    case negationNotSupported
    case malformed
}

/// A positive gitignore-style path pattern used by copy and lock policies.
public struct GitPathPattern: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    private let directoryOnly: Bool
    private let anchored: Bool
    private let matchesBasenameOnly: Bool
    private let anchoredSingleComponent: Bool
    private let expression: String

    public init(_ rawValue: String) throws(GitPathPatternError) {
        guard !rawValue.isEmpty else { throw .empty }
        guard !rawValue.hasPrefix("!") else { throw .negationNotSupported }
        var body = rawValue
        directoryOnly = body.hasSuffix("/")
        if directoryOnly { body.removeLast() }
        anchored = body.hasPrefix("/")
        let hadLeadingSlash = anchored
        if anchored { body.removeFirst() }
        guard !body.isEmpty, !body.contains("\n") else { throw .malformed }
        self.rawValue = rawValue
        matchesBasenameOnly = !anchored && !body.contains("/")
        anchoredSingleComponent = hadLeadingSlash && !body.contains("/")
        expression = Self.regex(from: body)
    }

    public func matches(_ path: String, isDirectory: Bool) -> Bool {
        guard !directoryOnly || isDirectory else { return false }
        guard !(anchoredSingleComponent && path.contains("/")) else { return false }
        let subject =
            matchesBasenameOnly
            ? path.split(separator: "/").last.map(String.init) ?? path
            : path
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(expression))$") else {
            return false
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        return regex.firstMatch(in: subject, range: range) != nil
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func regex(from pattern: String) -> String {
        var result = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                let followedBySlash = index + 2 < characters.count && characters[index + 2] == "/"
                result += followedBySlash ? "(?:.*/)?" : ".*"
                index += followedBySlash ? 3 : 2
            } else if character == "*" {
                result += "[^/]*"
                index += 1
            } else if character == "?" {
                result += "[^/]"
                index += 1
            } else {
                result += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }
        return result
    }
}

/// Controls which ignored roots a copy-on-write fork carries from its source worktree.
public enum GitIgnoredPathPolicy: Equatable, Hashable, Sendable {
    case copyAll
    case copyMatching([GitPathPattern])
}

extension GitIgnoredPathPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case patterns
    }

    private enum Kind: String, Codable {
        case copyAll
        case copyMatching
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .copyAll:
            guard Set(container.allKeys) == [.kind] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "copyAll has no patterns")
                )
            }
            self = .copyAll
        case .copyMatching:
            guard Set(container.allKeys) == [.kind, .patterns] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "copyMatching requires patterns")
                )
            }
            self = .copyMatching(try container.decode([GitPathPattern].self, forKey: .patterns))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .copyAll:
            try container.encode(Kind.copyAll, forKey: .kind)
        case .copyMatching(let patterns):
            try container.encode(Kind.copyMatching, forKey: .kind)
            try container.encode(patterns, forKey: .patterns)
        }
    }
}

public struct GitWorktreeCopyRules: Codable, Equatable, Hashable, Sendable {
    public let ignoredPaths: GitIgnoredPathPolicy

    public init(ignoredPaths: GitIgnoredPathPolicy) {
        self.ignoredPaths = ignoredPaths
    }
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
    public let materialization: GitWorktreeForkMaterialization
    public let copyRules: GitWorktreeCopyRules

    public init(
        sourceWorktreePath: URL,
        destinationPath: URL,
        mode: GitForkWorktreeMode,
        materialization: GitWorktreeForkMaterialization,
        copyRules: GitWorktreeCopyRules
    ) {
        self.sourceWorktreePath = sourceWorktreePath
        self.destinationPath = destinationPath
        self.mode = mode
        self.materialization = materialization
        self.copyRules = copyRules
    }
}

public struct GitForkWorktreeResult: Codable, Equatable, Hashable, Sendable {
    public let worktree: GitWorktreeSnapshot
    public let materialization: GitWorktreeMaterializationResult

    public init(worktree: GitWorktreeSnapshot, materialization: GitWorktreeMaterializationResult) {
        self.worktree = worktree
        self.materialization = materialization
    }
}

/// The explicitly tagged materialization evidence returned with a successful fork.
public enum GitWorktreeMaterializationResult: Equatable, Hashable, Sendable {
    case copyOnWrite(GitWorktreeMaterializationReport)
    case changesOnly(GitChangesOnlyMaterializationReport)
}

extension GitWorktreeMaterializationResult: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case clonedRegularFileCount
        case createdDirectoryCount
        case recreatedSymbolicLinkCount
        case preservedHardLinkCount
        case preservedGitRepositoryCount
        case recreatedFIFOCount
        case logicalRegularFileBytes
        case skippedEntries
        case normalizedEntries
        case ignoredIncludedPatterns
        case ignoredExcludedCount
        case nestedWorktreesSkipped
        case trackedChanges
        case untrackedFiles
        case ignoredExcluded
        case largeFiles
    }

    private enum Kind: String, Codable {
        case copyOnWrite
        case changesOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .copyOnWrite:
            let expectedKeys: Set<CodingKeys> = [
                .kind, .clonedRegularFileCount, .createdDirectoryCount, .recreatedSymbolicLinkCount,
                .preservedHardLinkCount, .preservedGitRepositoryCount, .recreatedFIFOCount,
                .logicalRegularFileBytes, .skippedEntries, .normalizedEntries, .ignoredIncludedPatterns,
                .ignoredExcludedCount, .nestedWorktreesSkipped,
            ]
            guard Set(container.allKeys) == expectedKeys else {
                throw Self.invalidPayload(decoder)
            }
            self = .copyOnWrite(
                GitWorktreeMaterializationReport(
                    clonedRegularFileCount: try container.decode(Int.self, forKey: .clonedRegularFileCount),
                    createdDirectoryCount: try container.decode(Int.self, forKey: .createdDirectoryCount),
                    recreatedSymbolicLinkCount: try container.decode(Int.self, forKey: .recreatedSymbolicLinkCount),
                    preservedHardLinkCount: try container.decode(Int.self, forKey: .preservedHardLinkCount),
                    preservedGitRepositoryCount: try container.decode(Int.self, forKey: .preservedGitRepositoryCount),
                    recreatedFIFOCount: try container.decode(Int.self, forKey: .recreatedFIFOCount),
                    logicalRegularFileBytes: try container.decode(Int64.self, forKey: .logicalRegularFileBytes),
                    skippedEntries: try container.decode(
                        [GitWorktreeMaterializationSkippedEntry].self, forKey: .skippedEntries),
                    normalizedEntries: try container.decode(
                        [GitWorktreeMaterializationNormalizedEntry].self, forKey: .normalizedEntries),
                    ignoredIncludedPatterns: try container.decode(
                        [String].self, forKey: .ignoredIncludedPatterns),
                    ignoredExcludedCount: try container.decode(Int.self, forKey: .ignoredExcludedCount),
                    nestedWorktreesSkipped: try container.decode(
                        [String].self, forKey: .nestedWorktreesSkipped)
                )
            )
        case .changesOnly:
            let expectedKeys: Set<CodingKeys> = [
                .kind, .trackedChanges, .untrackedFiles, .ignoredExcluded, .largeFiles,
            ]
            guard Set(container.allKeys) == expectedKeys else {
                throw Self.invalidPayload(decoder)
            }
            let trackedChanges = try container.decode(Int.self, forKey: .trackedChanges)
            let untrackedFiles = try container.decode(Int.self, forKey: .untrackedFiles)
            guard trackedChanges >= 0, untrackedFiles >= 0,
                try container.decode(Bool.self, forKey: .ignoredExcluded)
            else {
                throw Self.invalidPayload(decoder)
            }
            self = .changesOnly(
                GitChangesOnlyMaterializationReport(
                    trackedChanges: trackedChanges,
                    untrackedFiles: untrackedFiles,
                    largeFiles: try container.decode(GitLargeFileFill.self, forKey: .largeFiles)
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .copyOnWrite(let report):
            try container.encode(Kind.copyOnWrite, forKey: .kind)
            try container.encode(report.clonedRegularFileCount, forKey: .clonedRegularFileCount)
            try container.encode(report.createdDirectoryCount, forKey: .createdDirectoryCount)
            try container.encode(report.recreatedSymbolicLinkCount, forKey: .recreatedSymbolicLinkCount)
            try container.encode(report.preservedHardLinkCount, forKey: .preservedHardLinkCount)
            try container.encode(report.preservedGitRepositoryCount, forKey: .preservedGitRepositoryCount)
            try container.encode(report.recreatedFIFOCount, forKey: .recreatedFIFOCount)
            try container.encode(report.logicalRegularFileBytes, forKey: .logicalRegularFileBytes)
            try container.encode(report.skippedEntries, forKey: .skippedEntries)
            try container.encode(report.normalizedEntries, forKey: .normalizedEntries)
            try container.encode(report.ignoredIncludedPatterns, forKey: .ignoredIncludedPatterns)
            try container.encode(report.ignoredExcludedCount, forKey: .ignoredExcludedCount)
            try container.encode(report.nestedWorktreesSkipped, forKey: .nestedWorktreesSkipped)
        case .changesOnly(let report):
            try container.encode(Kind.changesOnly, forKey: .kind)
            try container.encode(report.trackedChanges, forKey: .trackedChanges)
            try container.encode(report.untrackedFiles, forKey: .untrackedFiles)
            try container.encode(report.ignoredExcluded, forKey: .ignoredExcluded)
            try container.encode(report.largeFiles, forKey: .largeFiles)
        }
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "materialization result payload does not match its kind"
            ))
    }
}

/// Net changes carried into a clean HEAD checkout. Ignored files are always excluded.
public struct GitChangesOnlyMaterializationReport: Codable, Equatable, Hashable, Sendable {
    public let trackedChanges: Int
    public let untrackedFiles: Int
    public let ignoredExcluded: Bool
    public let largeFiles: GitLargeFileFill

    public init(trackedChanges: Int, untrackedFiles: Int, largeFiles: GitLargeFileFill) {
        self.trackedChanges = trackedChanges
        self.untrackedFiles = untrackedFiles
        ignoredExcluded = true
        self.largeFiles = largeFiles
    }

    private enum CodingKeys: String, CodingKey {
        case trackedChanges
        case untrackedFiles
        case ignoredExcluded
        case largeFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let trackedChanges = try container.decode(Int.self, forKey: .trackedChanges)
        let untrackedFiles = try container.decode(Int.self, forKey: .untrackedFiles)
        guard trackedChanges >= 0, untrackedFiles >= 0,
            try container.decode(Bool.self, forKey: .ignoredExcluded)
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "changes-only counts must be nonnegative and ignored files excluded"
                ))
        }
        self.trackedChanges = trackedChanges
        self.untrackedFiles = untrackedFiles
        ignoredExcluded = true
        largeFiles = try container.decode(GitLargeFileFill.self, forKey: .largeFiles)
    }

    public func encode(to encoder: Encoder) throws {
        guard trackedChanges >= 0, untrackedFiles >= 0, ignoredExcluded else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "changes-only counts must be nonnegative and ignored files excluded"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackedChanges, forKey: .trackedChanges)
        try container.encode(untrackedFiles, forKey: .untrackedFiles)
        try container.encode(true, forKey: .ignoredExcluded)
        try container.encode(largeFiles, forKey: .largeFiles)
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
    public let ignoredIncludedPatterns: [String]
    public let ignoredExcludedCount: Int
    public let nestedWorktreesSkipped: [String]

    public init(
        clonedRegularFileCount: Int,
        createdDirectoryCount: Int,
        recreatedSymbolicLinkCount: Int,
        preservedHardLinkCount: Int,
        preservedGitRepositoryCount: Int,
        recreatedFIFOCount: Int,
        logicalRegularFileBytes: Int64,
        skippedEntries: [GitWorktreeMaterializationSkippedEntry],
        normalizedEntries: [GitWorktreeMaterializationNormalizedEntry],
        ignoredIncludedPatterns: [String],
        ignoredExcludedCount: Int,
        nestedWorktreesSkipped: [String]
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
        self.ignoredIncludedPatterns = ignoredIncludedPatterns
        self.ignoredExcludedCount = ignoredExcludedCount
        self.nestedWorktreesSkipped = nestedWorktreesSkipped
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

/// Up-front availability of Worktree Fork from host, volume, and File Provider facts only. It never walks
/// the source, so dataless content and Git topology are still decided by `forkWorktree`, whose rejection
/// stays authoritative even after `.available`.
public enum GitWorktreeForkEligibility: Equatable, Hashable, Sendable {
    case available
    case unavailable(GitWorktreeForkRejectionReason)
}

extension GitWorktreeForkEligibility: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case available
        case unavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available:
            guard !container.contains(.reason) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "available fork eligibility must not carry a reason"
                    ))
            }
            self = .available
        case .unavailable:
            self = .unavailable(try container.decode(GitWorktreeForkRejectionReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}
