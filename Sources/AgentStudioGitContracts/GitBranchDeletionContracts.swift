import Foundation

public struct GitDeleteLocalBranchRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let branchName: String
    public let expectedCommit: String

    public init(repositoryPath: URL, branchName: String, expectedCommit: String) {
        self.repositoryPath = repositoryPath
        self.branchName = branchName
        self.expectedCommit = expectedCommit
    }
}

public struct GitBranchMetadataCleanup: Codable, Equatable, Hashable, Sendable {
    public let configuration: GitBranchMetadataDisposition
    public let reflog: GitBranchMetadataDisposition

    public init(configuration: GitBranchMetadataDisposition, reflog: GitBranchMetadataDisposition) {
        self.configuration = configuration
        self.reflog = reflog
    }
}

public enum GitBranchMetadataDisposition: Equatable, Hashable, Sendable {
    case removed
    case absent
    case leftInPlace(GitBranchMetadataLeftInPlaceReason)
}

extension GitBranchMetadataDisposition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case removed
        case absent
        case leftInPlace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .removed:
            try Self.requireNoReason(in: container, decoder: decoder)
            self = .removed
        case .absent:
            try Self.requireNoReason(in: container, decoder: decoder)
            self = .absent
        case .leftInPlace:
            self = .leftInPlace(try container.decode(GitBranchMetadataLeftInPlaceReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .removed:
            try container.encode(Kind.removed, forKey: .kind)
        case .absent:
            try container.encode(Kind.absent, forKey: .kind)
        case .leftInPlace(let reason):
            try container.encode(Kind.leftInPlace, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    private static func requireNoReason(
        in container: KeyedDecodingContainer<CodingKeys>,
        decoder: Decoder
    ) throws {
        guard !container.contains(.reason) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "metadata dispositions without a reason must not carry one"
                )
            )
        }
    }
}

public enum GitBranchMetadataLeftInPlaceReason: String, Codable, CaseIterable, Hashable, Sendable {
    case recreatedMeanwhile
    case reservationUnavailable
    case removalFailed
}

public enum GitBranchRetentionReason: Equatable, Hashable, Sendable {
    case notFound
    case moved(currentCommit: String)
    case checkedOut(worktreePaths: [URL])
}

extension GitBranchRetentionReason: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case currentCommit
        case worktreePaths
    }

    private enum Kind: String, Codable {
        case notFound
        case moved
        case checkedOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .notFound:
            guard !container.contains(.currentCommit), !container.contains(.worktreePaths) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "notFound retention reasons carry no payload"
                    )
                )
            }
            self = .notFound
        case .moved:
            guard container.contains(.currentCommit), !container.contains(.worktreePaths) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "moved retention reasons require only the current commit"
                    )
                )
            }
            let currentCommit = try container.decode(String.self, forKey: .currentCommit)
            guard !currentCommit.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "moved retention reasons require a current commit"
                    )
                )
            }
            self = .moved(currentCommit: currentCommit)
        case .checkedOut:
            guard container.contains(.worktreePaths), !container.contains(.currentCommit) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "checkedOut retention reasons require only worktree paths"
                    )
                )
            }
            self = .checkedOut(worktreePaths: try container.decode([URL].self, forKey: .worktreePaths))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notFound:
            try container.encode(Kind.notFound, forKey: .kind)
        case .moved(let currentCommit):
            try container.encode(Kind.moved, forKey: .kind)
            try container.encode(currentCommit, forKey: .currentCommit)
        case .checkedOut(let worktreePaths):
            try container.encode(Kind.checkedOut, forKey: .kind)
            try container.encode(worktreePaths, forKey: .worktreePaths)
        }
    }
}

public enum GitDeleteLocalBranchErrorReason: Equatable, Sendable {
    case invalidBranchName
    case refLockContended
    case checkoutUnreadable(worktreePath: URL?)
    case notADirectCommitReference
    case gitFailure(GitDataPlaneError)
}

extension GitDeleteLocalBranchErrorReason: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case worktreePath
        case error
    }

    private enum Kind: String, Codable {
        case invalidBranchName
        case refLockContended
        case checkoutUnreadable
        case notADirectCommitReference
        case gitFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .invalidBranchName:
            try Self.requireNoPayload(in: container, decoder: decoder)
            self = .invalidBranchName
        case .refLockContended:
            try Self.requireNoPayload(in: container, decoder: decoder)
            self = .refLockContended
        case .checkoutUnreadable:
            guard !container.contains(.error) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "checkoutUnreadable must not carry a Git error"
                    )
                )
            }
            self = .checkoutUnreadable(worktreePath: try container.decodeIfPresent(URL.self, forKey: .worktreePath))
        case .notADirectCommitReference:
            try Self.requireNoPayload(in: container, decoder: decoder)
            self = .notADirectCommitReference
        case .gitFailure:
            guard !container.contains(.worktreePath) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "gitFailure must not carry a worktree path"
                    )
                )
            }
            self = .gitFailure(try container.decode(GitDataPlaneError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invalidBranchName:
            try container.encode(Kind.invalidBranchName, forKey: .kind)
        case .refLockContended:
            try container.encode(Kind.refLockContended, forKey: .kind)
        case .checkoutUnreadable(let worktreePath):
            try container.encode(Kind.checkoutUnreadable, forKey: .kind)
            try container.encodeIfPresent(worktreePath, forKey: .worktreePath)
        case .notADirectCommitReference:
            try container.encode(Kind.notADirectCommitReference, forKey: .kind)
        case .gitFailure(let error):
            try container.encode(Kind.gitFailure, forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }

    private static func requireNoPayload(
        in container: KeyedDecodingContainer<CodingKeys>,
        decoder: Decoder
    ) throws {
        guard !container.contains(.worktreePath), !container.contains(.error) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "branch deletion errors carry an unexpected payload"
                )
            )
        }
    }
}

public enum GitDeleteLocalBranchResult: Equatable, Sendable {
    case deleted(cleanup: GitBranchMetadataCleanup, lockResidue: [URL])
    case retained(reason: GitBranchRetentionReason, lockResidue: [URL])
    case uncertain(error: GitDataPlaneError, lockResidue: [URL])
}

extension GitDeleteLocalBranchResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case cleanup
        case reason
        case error
        case lockResidue
    }

    private enum Kind: String, Codable {
        case deleted
        case retained
        case uncertain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let lockResidue = try container.decode([URL].self, forKey: .lockResidue)
        switch kind {
        case .deleted:
            guard container.contains(.cleanup), !container.contains(.reason), !container.contains(.error) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "deleted results require only cleanup"
                    )
                )
            }
            self = .deleted(
                cleanup: try container.decode(GitBranchMetadataCleanup.self, forKey: .cleanup),
                lockResidue: lockResidue
            )
        case .retained:
            guard container.contains(.reason), !container.contains(.cleanup), !container.contains(.error) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "retained results require only a retention reason"
                    )
                )
            }
            self = .retained(
                reason: try container.decode(GitBranchRetentionReason.self, forKey: .reason),
                lockResidue: lockResidue
            )
        case .uncertain:
            guard container.contains(.error), !container.contains(.cleanup), !container.contains(.reason) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "uncertain results require only a Git error"
                    )
                )
            }
            self = .uncertain(
                error: try container.decode(GitDataPlaneError.self, forKey: .error),
                lockResidue: lockResidue
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deleted(let cleanup, let lockResidue):
            try container.encode(Kind.deleted, forKey: .kind)
            try container.encode(cleanup, forKey: .cleanup)
            try container.encode(lockResidue, forKey: .lockResidue)
        case .retained(let reason, let lockResidue):
            try container.encode(Kind.retained, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(lockResidue, forKey: .lockResidue)
        case .uncertain(let error, let lockResidue):
            try container.encode(Kind.uncertain, forKey: .kind)
            try container.encode(error, forKey: .error)
            try container.encode(lockResidue, forKey: .lockResidue)
        }
    }
}
