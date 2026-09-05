import Foundation

public struct GitCommitRangeCountRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let base: GitRevisionTarget
    public let candidate: GitRevisionTarget
    public let maximumCount: Int
    public let maximumTraversalCount: Int

    public init(
        repositoryPath: URL,
        base: GitRevisionTarget,
        candidate: GitRevisionTarget,
        maximumCount: Int,
        maximumTraversalCount: Int
    ) {
        self.repositoryPath = repositoryPath
        self.base = base
        self.candidate = candidate
        self.maximumCount = maximumCount
        self.maximumTraversalCount = maximumTraversalCount
    }
}

public enum GitCommitRangeCount: Equatable, Hashable, Sendable {
    case exact(Int)
    case atLeastLimit(Int)
    /// The requested range stayed below `maximumCount`, but ancestry could
    /// not be established within the request's traversal-work budget.
    case traversalLimitReached(Int)
    case unrelated
}

extension GitCommitRangeCount: Codable {
    private enum CodingKeys: String, CodingKey {
        case count
        case kind
    }

    private enum Kind: String, Codable {
        case atLeastLimit
        case exact
        case traversalLimitReached
        case unrelated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .exact:
            self = .exact(try Self.decodeNonnegativeCount(from: container, codingPath: decoder.codingPath))
        case .atLeastLimit:
            let count = try Self.decodeNonnegativeCount(from: container, codingPath: decoder.codingPath)
            guard count > 0 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "atLeastLimit requires a positive count"
                    ))
            }
            self = .atLeastLimit(count)
        case .traversalLimitReached:
            let count = try Self.decodeNonnegativeCount(from: container, codingPath: decoder.codingPath)
            guard count > 0 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "traversalLimitReached requires a positive count"
                    ))
            }
            self = .traversalLimitReached(count)
        case .unrelated:
            guard !container.contains(.count) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "unrelated commit ranges must not carry a count"
                    ))
            }
            self = .unrelated
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact(let count):
            try Self.encodeNonnegative(count, kind: .exact, to: &container, codingPath: encoder.codingPath)
        case .atLeastLimit(let count):
            guard count > 0 else {
                throw EncodingError.invalidValue(
                    count,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "atLeastLimit requires a positive count"
                    ))
            }
            try Self.encodeNonnegative(count, kind: .atLeastLimit, to: &container, codingPath: encoder.codingPath)
        case .traversalLimitReached(let count):
            guard count > 0 else {
                throw EncodingError.invalidValue(
                    count,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "traversalLimitReached requires a positive count"
                    ))
            }
            try Self.encodeNonnegative(
                count,
                kind: .traversalLimitReached,
                to: &container,
                codingPath: encoder.codingPath
            )
        case .unrelated:
            try container.encode(Kind.unrelated, forKey: .kind)
        }
    }

    private static func decodeNonnegativeCount(
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [CodingKey]
    ) throws -> Int {
        let count = try container.decode(Int.self, forKey: .count)
        guard count >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "commit count must be nonnegative"))
        }
        return count
    }

    private static func encodeNonnegative(
        _ count: Int,
        kind: Kind,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        codingPath: [CodingKey]
    ) throws {
        guard count >= 0 else {
            throw EncodingError.invalidValue(
                count,
                EncodingError.Context(codingPath: codingPath, debugDescription: "commit count must be nonnegative"))
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(count, forKey: .count)
    }
}
