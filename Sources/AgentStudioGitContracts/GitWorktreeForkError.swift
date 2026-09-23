import Foundation

/// Failures of a Worktree Fork. This is a separate union rather than new `GitDataPlaneError` cases so
/// downstream exhaustive switches over the existing error keep compiling; Git failures ride inside
/// `gitFailure`. Paths are worktree-relative unless the failing value is the public input path itself.
public indirect enum GitWorktreeForkError: Error, Equatable, Sendable {
    /// Rejected before any mutation: host, volume, request, or branch-mode preconditions.
    case rejected(reason: GitWorktreeForkRejectionReason)
    case gitFailure(GitDataPlaneError)
    /// The live source changed in a way the mixed-time contract does not admit.
    case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
    /// A strict-clone or entry-policy failure. `errorNumber` is the Darwin `errno` when one exists.
    case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errorNumber: Int32?)
    case cancelled
    case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
    /// Rollback could not remove everything the transaction created; `residue` is ordered and redacted.
    case cleanupIncomplete(primary: Self, residue: [GitWorktreeForkResidue])
}

public enum GitWorktreeForkRejectionReason: String, Codable, CaseIterable, Sendable {
    /// The `AgentStudioGitLocalClient` conformer does not implement Worktree Fork.
    case clientCapabilityUnavailable
    case unsupportedOperatingSystem
    case sourceFilesystemNotAPFS
    case destinationFilesystemNotAPFS
    case crossDevice
    case cloneCapabilityUnavailable
    case administrativeStoreOnDifferentDevice
    case sourceNotWorktreeRoot
    case sourceHeadUnavailable
    case invalidDestinationPath
    case destinationParentMissing
    case destinationExists
    case overlappingRoots
    case linkedWorktreeNameInUse
    case invalidBranchName
    case branchNotFound
    case branchAlreadyExists
    case branchNotAtCapturedHead
    case branchCheckedOut
    /// The source root or destination parent is managed by a File Provider (iCloud Drive, CloudStorage).
    case fileProviderManagedLocation
    /// The source contains a dataless (not-downloaded) regular file or directory.
    case datalessContent
}

public enum GitWorktreeForkSourceRaceReason: String, Codable, CaseIterable, Sendable {
    case entryMissing
    case entryKindChanged
    case entryIdentityChanged
    case containmentEscape
}

public enum GitWorktreeForkEntryFailureReason: String, Codable, CaseIterable, Sendable {
    case unsupportedEntryKind
    case datalessFile
    case datalessPolicyUnavailable
    case strictCloneFailed
    case entryCreationFailed
    case metadataNotReproducible
    case unreadableEntry
    case unresolvableGitAdministration
}

public enum GitWorktreeForkValidationFailureReason: String, Codable, CaseIterable, Sendable {
    case worktreeRegistrationInvalid
    case headMismatch
    case branchMismatch
    case entryCountMismatch
    case entryKindMismatch
    case hardLinkGroupBroken
    case indexTreeMismatch
    case indexStatNotRefreshed
    case sparseStateMismatch
    case submoduleStateMismatch
    case nestedRepositoryUnusable
    case sourceAdministrationReference
    case transactionArtifactRemains
}

public struct GitWorktreeForkResidue: Codable, Equatable, Hashable, Sendable {
    public let kind: GitWorktreeForkResidueKind
    /// Redacted location: destination-relative for content, common-directory-relative for
    /// administration, and a full ref name for branches.
    public let location: String

    public init(kind: GitWorktreeForkResidueKind, location: String) {
        self.kind = kind
        self.location = location
    }
}

public enum GitWorktreeForkResidueKind: String, Codable, CaseIterable, Sendable {
    case destinationContent
    case linkedWorktreeAdministration
    case nestedAdministration
    case createdBranch
    case temporaryArtifact
}

extension GitWorktreeForkError: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rejected
        case gitFailure
        case sourceChanged
        case entryFailed
        case cancelled
        case validationFailed
        case cleanupIncomplete
    }

    private enum PayloadKeys: String, CodingKey {
        case reason
        case error
        case relativePath
        case errorNumber
        case primary
        case residue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCases = CodingKeys.allCases.filter { container.contains($0) }
        guard decodedCases.count == 1, let decodedCase = decodedCases.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "GitWorktreeForkError payload must contain exactly one known case"
                ))
        }
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: decodedCase)
        switch decodedCase {
        case .rejected:
            self = .rejected(reason: try payload.decode(GitWorktreeForkRejectionReason.self, forKey: .reason))
        case .gitFailure:
            self = .gitFailure(try payload.decode(GitDataPlaneError.self, forKey: .error))
        case .sourceChanged:
            self = .sourceChanged(
                relativePath: try payload.decode(String.self, forKey: .relativePath),
                reason: try payload.decode(GitWorktreeForkSourceRaceReason.self, forKey: .reason)
            )
        case .entryFailed:
            self = .entryFailed(
                relativePath: try payload.decode(String.self, forKey: .relativePath),
                reason: try payload.decode(GitWorktreeForkEntryFailureReason.self, forKey: .reason),
                errorNumber: try payload.decodeIfPresent(Int32.self, forKey: .errorNumber)
            )
        case .cancelled:
            self = .cancelled
        case .validationFailed:
            self = .validationFailed(
                reason: try payload.decode(GitWorktreeForkValidationFailureReason.self, forKey: .reason),
                relativePath: try payload.decodeIfPresent(String.self, forKey: .relativePath)
            )
        case .cleanupIncomplete:
            self = .cleanupIncomplete(
                primary: try payload.decode(GitWorktreeForkError.self, forKey: .primary),
                residue: try payload.decode([GitWorktreeForkResidue].self, forKey: .residue)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rejected(let reason):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .rejected)
            try payload.encode(reason, forKey: .reason)
        case .gitFailure(let error):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .gitFailure)
            try payload.encode(error, forKey: .error)
        case .sourceChanged(let relativePath, let reason):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .sourceChanged)
            try payload.encode(relativePath, forKey: .relativePath)
            try payload.encode(reason, forKey: .reason)
        case .entryFailed(let relativePath, let reason, let errorNumber):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .entryFailed)
            try payload.encode(relativePath, forKey: .relativePath)
            try payload.encode(reason, forKey: .reason)
            try payload.encodeIfPresent(errorNumber, forKey: .errorNumber)
        case .cancelled:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .cancelled)
        case .validationFailed(let reason, let relativePath):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .validationFailed)
            try payload.encode(reason, forKey: .reason)
            try payload.encodeIfPresent(relativePath, forKey: .relativePath)
        case .cleanupIncomplete(let primary, let residue):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .cleanupIncomplete)
            try payload.encode(primary, forKey: .primary)
            try payload.encode(residue, forKey: .residue)
        }
    }
}
