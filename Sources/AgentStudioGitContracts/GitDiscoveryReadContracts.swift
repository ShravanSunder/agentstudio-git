import Foundation

extension KeyedDecodingContainer {
    fileprivate func rejectNonSelectedPayloadKeys(
        _ nonSelectedPayloadKeys: [Key],
        unionName: String,
        selectedCase: String
    ) throws {
        let presentNonSelectedKeys = nonSelectedPayloadKeys.filter(contains)
        guard presentNonSelectedKeys.isEmpty else {
            let keyNames = presentNonSelectedKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription:
                        "\(unionName).\(selectedCase) payload contains non-selected keys: \(keyNames)"
                )
            )
        }
    }
}

public protocol AgentStudioGitDiscoveryReadClient: Sendable {
    func readDiscoveryCandidate(_ request: GitDiscoveryReadRequest) async -> GitDiscoveryReadOutcome
}

public struct GitDiscoveryReadRequest: Codable, Equatable, Hashable, Sendable {
    public let candidatePath: URL

    public init(candidatePath: URL) {
        self.candidatePath = candidatePath
    }
}

public enum GitDiscoveryReadOutcome: Equatable, Sendable {
    case validated(GitDiscoveryReadEvidence)
    case notRepository(GitDiscoveryNotRepositoryReason)
    case failed(GitDiscoveryReadFailure)
}

extension GitDiscoveryReadOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case evidence
        case reason
        case failure
    }

    private enum State: String, Codable {
        case validated
        case notRepository
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .validated:
            try container.rejectNonSelectedPayloadKeys(
                [.reason, .failure],
                unionName: "GitDiscoveryReadOutcome",
                selectedCase: State.validated.rawValue
            )
            self = try .validated(container.decode(GitDiscoveryReadEvidence.self, forKey: .evidence))
        case .notRepository:
            try container.rejectNonSelectedPayloadKeys(
                [.evidence, .failure],
                unionName: "GitDiscoveryReadOutcome",
                selectedCase: State.notRepository.rawValue
            )
            self = try .notRepository(container.decode(GitDiscoveryNotRepositoryReason.self, forKey: .reason))
        case .failed:
            try container.rejectNonSelectedPayloadKeys(
                [.evidence, .reason],
                unionName: "GitDiscoveryReadOutcome",
                selectedCase: State.failed.rawValue
            )
            self = try .failed(container.decode(GitDiscoveryReadFailure.self, forKey: .failure))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .validated(let evidence):
            try container.encode(State.validated, forKey: .state)
            try container.encode(evidence, forKey: .evidence)
        case .notRepository(let reason):
            try container.encode(State.notRepository, forKey: .state)
            try container.encode(reason, forKey: .reason)
        case .failed(let failure):
            try container.encode(State.failed, forKey: .state)
            try container.encode(failure, forKey: .failure)
        }
    }
}

public enum GitDiscoveryNotRepositoryReason: String, Codable, CaseIterable, Sendable {
    case exactCandidateIsNotRepository
    case invalidRepository
    case invalidWorktreeRegistration
    case bareRepository
}

public struct GitDiscoveryReadFailure: Codable, Equatable, Hashable, Sendable {
    public let code: Int32
    public let errorClass: Int32
    public let message: String

    public init(code: Int32, errorClass: Int32, message: String) {
        self.code = code
        self.errorClass = errorClass
        self.message = message
    }
}

public struct GitDiscoveryReadEvidence: Codable, Equatable, Hashable, Sendable {
    public let canonicalCandidatePath: URL
    public let canonicalWorktreePath: URL
    public let canonicalGitDirectory: URL
    public let canonicalCommonDirectory: URL
    public let repositoryIdentity: GitRepositoryIdentity
    public let registration: GitDiscoveryWorktreeRegistration

    public init(
        canonicalCandidatePath: URL,
        canonicalWorktreePath: URL,
        canonicalGitDirectory: URL,
        canonicalCommonDirectory: URL,
        repositoryIdentity: GitRepositoryIdentity,
        registration: GitDiscoveryWorktreeRegistration
    ) {
        self.canonicalCandidatePath = canonicalCandidatePath
        self.canonicalWorktreePath = canonicalWorktreePath
        self.canonicalGitDirectory = canonicalGitDirectory
        self.canonicalCommonDirectory = canonicalCommonDirectory
        self.repositoryIdentity = repositoryIdentity
        self.registration = registration
    }
}

public enum GitDiscoveryWorktreeRegistration: Equatable, Hashable, Sendable {
    case main
    case linked(name: String, lockState: GitDiscoveryLinkedWorktreeLockState)
}

extension GitDiscoveryWorktreeRegistration: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case lockState
    }

    private enum Kind: String, Codable {
        case main
        case linked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .main:
            try container.rejectNonSelectedPayloadKeys(
                [.name, .lockState],
                unionName: "GitDiscoveryWorktreeRegistration",
                selectedCase: Kind.main.rawValue
            )
            self = .main
        case .linked:
            self = try .linked(
                name: container.decode(String.self, forKey: .name),
                lockState: container.decode(GitDiscoveryLinkedWorktreeLockState.self, forKey: .lockState)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .main:
            try container.encode(Kind.main, forKey: .kind)
        case .linked(let name, let lockState):
            try container.encode(Kind.linked, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(lockState, forKey: .lockState)
        }
    }
}

public enum GitDiscoveryLinkedWorktreeLockState: Equatable, Hashable, Sendable {
    case unlocked
    case lockedWithoutReason
    case locked(reason: String)
}

extension GitDiscoveryLinkedWorktreeLockState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case unlocked
        case lockedWithoutReason
        case locked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .unlocked:
            try container.rejectNonSelectedPayloadKeys(
                [.reason],
                unionName: "GitDiscoveryLinkedWorktreeLockState",
                selectedCase: State.unlocked.rawValue
            )
            self = .unlocked
        case .lockedWithoutReason:
            try container.rejectNonSelectedPayloadKeys(
                [.reason],
                unionName: "GitDiscoveryLinkedWorktreeLockState",
                selectedCase: State.lockedWithoutReason.rawValue
            )
            self = .lockedWithoutReason
        case .locked:
            self = try .locked(reason: container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unlocked:
            try container.encode(State.unlocked, forKey: .state)
        case .lockedWithoutReason:
            try container.encode(State.lockedWithoutReason, forKey: .state)
        case .locked(let reason):
            try container.encode(State.locked, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}
