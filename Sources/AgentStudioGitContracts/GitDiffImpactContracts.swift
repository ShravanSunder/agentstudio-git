import Foundation

public struct GitDiffImpactSummaryRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let base: GitDiffTarget
    public let compare: GitDiffTarget
    public let maximumChangedFileCount: Int
    public let maximumChangedLineCount: Int
    public let maximumDiffableBlobByteCount: Int64

    public init(
        repositoryPath: URL,
        base: GitDiffTarget,
        compare: GitDiffTarget,
        maximumChangedFileCount: Int,
        maximumChangedLineCount: Int,
        maximumDiffableBlobByteCount: Int64
    ) {
        self.repositoryPath = repositoryPath
        self.base = base
        self.compare = compare
        self.maximumChangedFileCount = maximumChangedFileCount
        self.maximumChangedLineCount = maximumChangedLineCount
        self.maximumDiffableBlobByteCount = maximumDiffableBlobByteCount
    }
}

public struct GitDiffImpactPath: Codable, Equatable, Hashable, Sendable {
    /// Path on the candidate side, absent for a deletion.
    public let currentPath: String?
    /// Path on the displayed side for a rename or deletion.
    public let previousPath: String?

    public init(currentPath: String?, previousPath: String?) {
        self.currentPath = currentPath
        self.previousPath = previousPath
    }
}

public enum GitDiffImpactCount: Equatable, Hashable, Sendable {
    case exact(Int)
    case atLeastLimit(Int)
    /// A traversal or blob-work limit prevented an exact Git-shaped result.
    case indeterminate
}

extension GitDiffImpactCount: Codable {
    private enum CodingKeys: String, CodingKey {
        case count
        case kind
    }

    private enum Kind: String, Codable {
        case atLeastLimit
        case exact
        case indeterminate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
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
        case .indeterminate:
            guard !container.contains(.count) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "indeterminate diff impact counts must not carry a count"
                    ))
            }
            self = .indeterminate
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
        case .indeterminate:
            try container.encode(Kind.indeterminate, forKey: .kind)
        }
    }

    private static func decodeNonnegativeCount(
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [CodingKey]
    ) throws -> Int {
        let count = try container.decode(Int.self, forKey: .count)
        guard count >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "diff impact count must be nonnegative")
            )
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
                EncodingError.Context(codingPath: codingPath, debugDescription: "diff impact count must be nonnegative")
            )
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(count, forKey: .count)
    }
}

public struct GitDiffImpactSummary: Equatable, Hashable, Sendable {
    /// Complete only when `pathsAreComplete` is true. Callers must not use a
    /// partial path set as an affected-file authority.
    public let changedPaths: [GitDiffImpactPath]
    public let pathsAreComplete: Bool
    public let changedFileCount: GitDiffImpactCount
    public let changedLineCount: GitDiffImpactCount
    public let addedLineCount: Int?
    public let deletedLineCount: Int?

    public init(
        changedPaths: [GitDiffImpactPath],
        pathsAreComplete: Bool,
        changedFileCount: GitDiffImpactCount,
        changedLineCount: GitDiffImpactCount,
        addedLineCount: Int?,
        deletedLineCount: Int?
    ) {
        self.changedPaths = changedPaths
        self.pathsAreComplete = pathsAreComplete
        self.changedFileCount = changedFileCount
        self.changedLineCount = changedLineCount
        self.addedLineCount = addedLineCount
        self.deletedLineCount = deletedLineCount
    }
}

extension GitDiffImpactSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case addedLineCount
        case changedFileCount
        case changedLineCount
        case changedPaths
        case deletedLineCount
        case pathsAreComplete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let summary = Self(
            changedPaths: try container.decode([GitDiffImpactPath].self, forKey: .changedPaths),
            pathsAreComplete: try container.decode(Bool.self, forKey: .pathsAreComplete),
            changedFileCount: try container.decode(GitDiffImpactCount.self, forKey: .changedFileCount),
            changedLineCount: try container.decode(GitDiffImpactCount.self, forKey: .changedLineCount),
            addedLineCount: try container.decodeIfPresent(Int.self, forKey: .addedLineCount),
            deletedLineCount: try container.decodeIfPresent(Int.self, forKey: .deletedLineCount)
        )
        guard summary.hasValidLineCounts else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "diff impact line counts do not match their bounded outcome"
                ))
        }
        self = summary
    }

    public func encode(to encoder: Encoder) throws {
        guard hasValidLineCounts else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "diff impact line counts do not match their bounded outcome"
                ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changedPaths, forKey: .changedPaths)
        try container.encode(pathsAreComplete, forKey: .pathsAreComplete)
        try container.encode(changedFileCount, forKey: .changedFileCount)
        try container.encode(changedLineCount, forKey: .changedLineCount)
        try container.encode(addedLineCount, forKey: .addedLineCount)
        try container.encode(deletedLineCount, forKey: .deletedLineCount)
    }

    private var hasValidLineCounts: Bool {
        switch changedLineCount {
        case .exact(let expectedCount):
            return Self.combinedLineCount(addedLineCount, deletedLineCount) == expectedCount
        case .atLeastLimit(let minimumCount):
            guard let combinedCount = Self.combinedLineCount(addedLineCount, deletedLineCount) else {
                return false
            }
            return combinedCount >= minimumCount
        case .indeterminate:
            return addedLineCount == nil && deletedLineCount == nil
        }
    }

    private static func combinedLineCount(_ addedLineCount: Int?, _ deletedLineCount: Int?) -> Int? {
        guard let addedLineCount, let deletedLineCount,
            addedLineCount >= 0, deletedLineCount >= 0
        else {
            return nil
        }
        let result = addedLineCount.addingReportingOverflow(deletedLineCount)
        return result.overflow ? nil : result.partialValue
    }
}
