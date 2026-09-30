import Foundation

public struct GitBranchIntegrationRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let branchNames: [String]
    public let targetCommit: String
    public let squashSearchCommitLimit: Int

    public init(
        repositoryPath: URL,
        branchNames: [String],
        targetCommit: String,
        squashSearchCommitLimit: Int
    ) {
        self.repositoryPath = repositoryPath
        self.branchNames = branchNames
        self.targetCommit = targetCommit
        self.squashSearchCommitLimit = squashSearchCommitLimit
    }

    private enum CodingKeys: String, CodingKey {
        case repositoryPath
        case branchNames
        case targetCommit
        case squashSearchCommitLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let squashSearchCommitLimit = try container.decode(Int.self, forKey: .squashSearchCommitLimit)
        let targetCommit = try container.decode(String.self, forKey: .targetCommit)
        guard !targetCommit.isEmpty, (0...10_000).contains(squashSearchCommitLimit) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "branch integration requires a target commit and a limit from 0 through 10000"
                )
            )
        }
        repositoryPath = try container.decode(URL.self, forKey: .repositoryPath)
        branchNames = try container.decode([String].self, forKey: .branchNames)
        self.targetCommit = targetCommit
        self.squashSearchCommitLimit = squashSearchCommitLimit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repositoryPath, forKey: .repositoryPath)
        try container.encode(branchNames, forKey: .branchNames)
        try container.encode(targetCommit, forKey: .targetCommit)
        try container.encode(squashSearchCommitLimit, forKey: .squashSearchCommitLimit)
    }
}

public struct GitBranchIntegrationReport: Codable, Equatable, Hashable, Sendable {
    public let targetCommit: String
    public let assessments: [GitBranchIntegrationAssessment]

    public init(targetCommit: String, assessments: [GitBranchIntegrationAssessment]) {
        self.targetCommit = targetCommit
        self.assessments = assessments
    }
}

public struct GitBranchIntegrationAssessment: Codable, Equatable, Hashable, Sendable {
    public let branchName: String
    public let branchCommit: String?
    public let grade: GitBranchIntegrationGrade

    public init(branchName: String, branchCommit: String?, grade: GitBranchIntegrationGrade) {
        self.branchName = branchName
        self.branchCommit = branchCommit
        self.grade = grade
    }
}

public enum GitBranchIntegrationGrade: Equatable, Hashable, Sendable {
    case integrated(GitIntegrationProof)
    case hasRemainingContribution
    case unknown(GitIntegrationUnknownReason)
}

extension GitBranchIntegrationGrade: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case proof
        case reason
    }

    private enum Kind: String, Codable {
        case integrated
        case hasRemainingContribution
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .integrated:
            guard container.contains(.proof), !container.contains(.reason) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "integrated branch grades require only a proof"
                    )
                )
            }
            self = .integrated(try container.decode(GitIntegrationProof.self, forKey: .proof))
        case .hasRemainingContribution:
            guard !container.contains(.proof), !container.contains(.reason) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "remaining contribution grades carry no payload"
                    )
                )
            }
            self = .hasRemainingContribution
        case .unknown:
            guard container.contains(.reason), !container.contains(.proof) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "unknown branch grades require only a reason"
                    )
                )
            }
            self = .unknown(try container.decode(GitIntegrationUnknownReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integrated(let proof):
            try container.encode(Kind.integrated, forKey: .kind)
            try container.encode(proof, forKey: .proof)
        case .hasRemainingContribution:
            try container.encode(Kind.hasRemainingContribution, forKey: .kind)
        case .unknown(let reason):
            try container.encode(Kind.unknown, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public enum GitIntegrationProof: Equatable, Hashable, Sendable {
    case sameCommit
    case ancestor
    case sameContent
    case emptyDelta
    case squash(commit: String)
}

extension GitIntegrationProof: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case commit
    }

    private enum Kind: String, Codable {
        case sameCommit
        case ancestor
        case sameContent
        case emptyDelta
        case squash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .sameCommit:
            try Self.requireNoCommit(in: container, decoder: decoder)
            self = .sameCommit
        case .ancestor:
            try Self.requireNoCommit(in: container, decoder: decoder)
            self = .ancestor
        case .sameContent:
            try Self.requireNoCommit(in: container, decoder: decoder)
            self = .sameContent
        case .emptyDelta:
            try Self.requireNoCommit(in: container, decoder: decoder)
            self = .emptyDelta
        case .squash:
            let commit = try container.decode(String.self, forKey: .commit)
            guard !commit.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "squash proofs require a commit identifier"
                    )
                )
            }
            self = .squash(commit: commit)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sameCommit:
            try container.encode(Kind.sameCommit, forKey: .kind)
        case .ancestor:
            try container.encode(Kind.ancestor, forKey: .kind)
        case .sameContent:
            try container.encode(Kind.sameContent, forKey: .kind)
        case .emptyDelta:
            try container.encode(Kind.emptyDelta, forKey: .kind)
        case .squash(let commit):
            try container.encode(Kind.squash, forKey: .kind)
            try container.encode(commit, forKey: .commit)
        }
    }

    private static func requireNoCommit(
        in container: KeyedDecodingContainer<CodingKeys>,
        decoder: Decoder
    ) throws {
        guard !container.contains(.commit) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "non-squash proofs must not carry a commit identifier"
                )
            )
        }
    }
}

public enum GitIntegrationUnknownReason: String, Codable, CaseIterable, Hashable, Sendable {
    case branchNotFound
    case noMergeBase
    case multipleMergeBases
    case historyLimitReached
    case incompleteHistory
    case missingObjects
    case readFailed
}
