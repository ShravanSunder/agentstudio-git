import Foundation

public struct GitLockFact: Codable, Equatable, Hashable, Sendable {
    public let path: URL
    public let resource: GitLockResource

    public init(path: URL, resource: GitLockResource) {
        self.path = path
        self.resource = resource
    }
}

public enum GitLockResource: Codable, Equatable, Hashable, Sendable {
    case index(worktreePath: URL)
    case reference(name: String)
    case packedRefs
    case config

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case index
        case reference
        case packedRefs
        case config
    }

    private enum PayloadKeys: String, CodingKey {
        case worktreePath
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCases = CodingKeys.allCases.filter { container.contains($0) }
        guard decodedCases.count == 1 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "GitLockResource payload must contain exactly one case"
                )
            )
        }

        if container.contains(.index) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .index)
            self = try .index(worktreePath: payload.decode(URL.self, forKey: .worktreePath))
        } else if container.contains(.reference) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .reference)
            self = try .reference(name: payload.decode(String.self, forKey: .name))
        } else if container.contains(.packedRefs) {
            _ = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .packedRefs)
            self = .packedRefs
        } else if container.contains(.config) {
            _ = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .config)
            self = .config
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown GitLockResource case"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .index(let worktreePath):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .index)
            try payload.encode(worktreePath, forKey: .worktreePath)
        case .reference(let name):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .reference)
            try payload.encode(name, forKey: .name)
        case .packedRefs:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .packedRefs)
        case .config:
            _ = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .config)
        }
    }
}

/// A lock-related failure and any observed lock files that remain after the operation.
public struct GitLockedOperationFailure<Reason: Sendable>: Error, Sendable {
    public let reason: Reason
    /// `nil` means the operation did not observe candidate lock paths; an empty array means it observed none left.
    public let lockResidue: [URL]?

    public init(reason: Reason, lockResidue: [URL]?) {
        self.reason = reason
        self.lockResidue = lockResidue
    }
}

extension GitLockedOperationFailure: Codable where Reason: Codable {}
extension GitLockedOperationFailure: Equatable where Reason: Equatable {}
extension GitLockedOperationFailure: Hashable where Reason: Hashable {}
