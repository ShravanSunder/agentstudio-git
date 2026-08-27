import Foundation

public struct GitStatusObservationIdentity: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum GitStatusObservationScopeKind: String, Codable, CaseIterable, Sendable {
    case item
    case subtree
}

public struct GitStatusObservationScope: Codable, Equatable, Hashable, Sendable {
    public let kind: GitStatusObservationScopeKind
    public let path: URL

    public init(kind: GitStatusObservationScopeKind, path: URL) {
        self.kind = kind
        self.path = path
    }
}

public enum GitStatusObservationSupport: String, Codable, Sendable {
    case supported
    case unsupported
}

public struct GitStatusObservationPlan: Codable, Equatable, Hashable, Sendable {
    public let identity: GitStatusObservationIdentity
    public let scopes: [GitStatusObservationScope]
    public let support: GitStatusObservationSupport

    public init(
        identity: GitStatusObservationIdentity,
        scopes: [GitStatusObservationScope],
        support: GitStatusObservationSupport
    ) {
        self.identity = identity
        self.scopes = scopes
        self.support = support
    }
}

public struct GitExactCleanBaseline: Codable, Equatable, Hashable, Sendable {
    public let observationIdentity: GitStatusObservationIdentity

    public init(observationIdentity: GitStatusObservationIdentity) {
        self.observationIdentity = observationIdentity
    }
}

public struct GitStatusFactsRead: Codable, Equatable, Hashable, Sendable {
    public let facts: GitStatusFactsSnapshot
    public let exactCleanBaseline: GitExactCleanBaseline?

    public init(facts: GitStatusFactsSnapshot, exactCleanBaseline: GitExactCleanBaseline?) {
        self.facts = facts
        self.exactCleanBaseline = exactCleanBaseline
    }
}
