import Foundation

public struct GitWorktreeCreation: Codable, Equatable, Hashable, Sendable {
    public let worktree: GitWorktreeSnapshot
    public let largeFiles: GitLargeFileFill

    public init(worktree: GitWorktreeSnapshot, largeFiles: GitLargeFileFill) {
        self.worktree = worktree
        self.largeFiles = largeFiles
    }
}

public struct GitLargeFileFill: Codable, Equatable, Hashable, Sendable {
    public let materializedCount: Int
    public let missing: [GitLargeFileFillMiss]
    public let scan: GitLargeFileScan

    public init(
        materializedCount: Int,
        missing: [GitLargeFileFillMiss],
        scan: GitLargeFileScan
    ) {
        self.materializedCount = materializedCount
        self.missing = missing
        self.scan = scan
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case materializedCount
        case missing
        case scan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw Self.invalidPayload(decoder)
        }
        let materializedCount = try container.decode(Int.self, forKey: .materializedCount)
        let missing = try container.decode([GitLargeFileFillMiss].self, forKey: .missing)
        let scan = try container.decode(GitLargeFileScan.self, forKey: .scan)
        guard materializedCount >= 0,
            missing.allSatisfy({ !$0.path.isEmpty }),
            Set(missing.map(\.path)).count == missing.count
        else {
            throw Self.invalidPayload(decoder)
        }
        self.materializedCount = materializedCount
        self.missing = missing
        self.scan = scan
    }

    public func encode(to encoder: Encoder) throws {
        guard materializedCount >= 0,
            missing.allSatisfy({ !$0.path.isEmpty }),
            Set(missing.map(\.path)).count == missing.count
        else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "large-file fill counts must be nonnegative with nonempty unique paths"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(materializedCount, forKey: .materializedCount)
        try container.encode(missing, forKey: .missing)
        try container.encode(scan, forKey: .scan)
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file fill payload is invalid"
            )
        )
    }
}

/// Whether the fill identified every eligible HEAD LFS path.
public enum GitLargeFileScan: Equatable, Hashable, Sendable {
    case complete
    case incomplete(GitLargeFileScanFailure)
}

extension GitLargeFileScan: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case incomplete
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
            let value = try? container.decode(String.self)
        {
            guard value == "complete" else {
                throw Self.invalidPayload(decoder)
            }
            self = .complete
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == [.incomplete] else {
            throw Self.invalidPayload(decoder)
        }
        self = .incomplete(try container.decode(GitLargeFileScanFailure.self, forKey: .incomplete))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .complete:
            var container = encoder.singleValueContainer()
            try container.encode("complete")
        case .incomplete(let failure):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(failure, forKey: .incomplete)
        }
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file scan status is invalid"
            )
        )
    }
}

public enum GitLargeFileScanFailure: Equatable, Hashable, Sendable {
    case readFailed(errno: Int32)
    case gitFailure(kind: GitLargeFileScanFailureKind)
}

extension GitLargeFileScanFailure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case readFailed
        case gitFailure
    }

    private enum PayloadKeys: String, CodingKey {
        case errno
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCases = CodingKeys.allCases.filter { container.contains($0) }
        guard decodedCases.count == 1 else {
            throw Self.invalidPayload(decoder)
        }
        if container.contains(.readFailed) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .readFailed)
            guard Set(payload.allKeys) == [.errno] else {
                throw Self.invalidPayload(decoder)
            }
            let errorNumber = try payload.decode(Int32.self, forKey: .errno)
            guard errorNumber > 0 else {
                throw Self.invalidPayload(decoder)
            }
            self = .readFailed(errno: errorNumber)
        } else {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .gitFailure)
            guard Set(payload.allKeys) == [.kind] else {
                throw Self.invalidPayload(decoder)
            }
            self = .gitFailure(kind: try payload.decode(GitLargeFileScanFailureKind.self, forKey: .kind))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .readFailed(let errorNumber):
            guard errorNumber > 0 else {
                throw Self.invalidValue(self, encoder: encoder)
            }
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .readFailed)
            try payload.encode(errorNumber, forKey: .errno)
        case .gitFailure(let kind):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .gitFailure)
            try payload.encode(kind, forKey: .kind)
        }
    }

    private static func invalidValue(_ value: Self, encoder: Encoder) -> EncodingError {
        .invalidValue(
            value,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "large-file scan errno must be positive"
            )
        )
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file scan failure is invalid"
            )
        )
    }
}

public enum GitLargeFileScanFailureKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case repositoryUnavailable
    case headUnavailable
    case treeReadFailed
    case attributeReadFailed
}

public struct GitLargeFileFillMiss: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let reason: GitLargeFileFillMissReason

    public init(path: String, reason: GitLargeFileFillMissReason) {
        self.path = path
        self.reason = reason
    }
}

public enum GitLargeFileFillMissReason: Equatable, Hashable, Sendable {
    case objectAbsent
    case objectMismatch
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
}

extension GitLargeFileFillMissReason: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case errno
    }

    private enum Kind: String, Codable {
        case objectAbsent
        case objectMismatch
        case readFailed
        case writeFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .objectAbsent:
            guard Set(container.allKeys) == [.kind] else {
                throw Self.invalidPayload(decoder)
            }
            self = .objectAbsent
        case .objectMismatch:
            guard Set(container.allKeys) == [.kind] else {
                throw Self.invalidPayload(decoder)
            }
            self = .objectMismatch
        case .readFailed:
            guard Set(container.allKeys) == [.kind, .errno] else {
                throw Self.invalidPayload(decoder)
            }
            let errorNumber = try container.decode(Int32.self, forKey: .errno)
            guard errorNumber > 0 else {
                throw Self.invalidPayload(decoder)
            }
            self = .readFailed(errno: errorNumber)
        case .writeFailed:
            guard Set(container.allKeys) == [.kind, .errno] else {
                throw Self.invalidPayload(decoder)
            }
            let errorNumber = try container.decode(Int32.self, forKey: .errno)
            guard errorNumber > 0 else {
                throw Self.invalidPayload(decoder)
            }
            self = .writeFailed(errno: errorNumber)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .objectAbsent:
            try container.encode(Kind.objectAbsent, forKey: .kind)
        case .objectMismatch:
            try container.encode(Kind.objectMismatch, forKey: .kind)
        case .readFailed(let errorNumber):
            guard errorNumber > 0 else {
                throw Self.invalidValue(self, encoder: encoder)
            }
            try container.encode(Kind.readFailed, forKey: .kind)
            try container.encode(errorNumber, forKey: .errno)
        case .writeFailed(let errorNumber):
            guard errorNumber > 0 else {
                throw Self.invalidValue(self, encoder: encoder)
            }
            try container.encode(Kind.writeFailed, forKey: .kind)
            try container.encode(errorNumber, forKey: .errno)
        }
    }

    private static func invalidValue(_ value: Self, encoder: Encoder) -> EncodingError {
        .invalidValue(
            value,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "large-file fill errno must be positive"
            )
        )
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file fill miss reason is invalid"
            )
        )
    }
}
