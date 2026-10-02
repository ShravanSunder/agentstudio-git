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
    public let indexUpdate: GitLargeFileIndexUpdate

    public init(
        materializedCount: Int,
        missing: [GitLargeFileFillMiss],
        indexUpdate: GitLargeFileIndexUpdate
    ) {
        self.materializedCount = materializedCount
        self.missing = missing
        self.indexUpdate = indexUpdate
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case materializedCount
        case missing
        case indexUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw Self.invalidPayload(decoder)
        }
        let materializedCount = try container.decode(Int.self, forKey: .materializedCount)
        let missing = try container.decode([GitLargeFileFillMiss].self, forKey: .missing)
        guard materializedCount >= 0,
            missing.allSatisfy({ !$0.path.isEmpty }),
            Set(missing.map(\.path)).count == missing.count
        else {
            throw Self.invalidPayload(decoder)
        }
        self.materializedCount = materializedCount
        self.missing = missing
        self.indexUpdate = try container.decode(GitLargeFileIndexUpdate.self, forKey: .indexUpdate)
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
        try container.encode(indexUpdate, forKey: .indexUpdate)
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

public enum GitLargeFileIndexUpdate: Equatable, Hashable, Sendable {
    case updated
    case skipped(GitLargeFileIndexSkip)
}

public enum GitLargeFileIndexFailureKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case repositoryIndexUnavailable
    case indexReadFailed
    case indexPathUnavailable
    case entryStatFailed
    case indexEntryUnavailable
    case indexEntryUpdateFailed
    case indexWriteFailed
}

extension GitLargeFileIndexUpdate: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case cause
    }

    private enum Kind: String, Codable {
        case updated
        case skipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .updated:
            guard Set(container.allKeys) == [.kind] else {
                throw Self.invalidPayload(decoder)
            }
            self = .updated
        case .skipped:
            guard Set(container.allKeys) == [.kind, .cause] else {
                throw Self.invalidPayload(decoder)
            }
            self = .skipped(try container.decode(GitLargeFileIndexSkip.self, forKey: .cause))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .updated:
            try container.encode(Kind.updated, forKey: .kind)
        case .skipped(let cause):
            try container.encode(Kind.skipped, forKey: .kind)
            try container.encode(cause, forKey: .cause)
        }
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file index update payload is invalid"
            )
        )
    }
}

public enum GitLargeFileIndexSkip: Equatable, Hashable, Sendable {
    case lockHeld(GitLockFact)
    case lockUnidentified(GitLockResource)
    case permissionDenied(path: URL?)
    case gitFailure(GitLargeFileIndexFailureKind)
}

extension GitLargeFileIndexSkip: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case lockHeld
        case lockUnidentified
        case permissionDenied
        case gitFailure
    }

    private enum PayloadKeys: String, CodingKey {
        case fact
        case resource
        case path
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCases = CodingKeys.allCases.filter { container.contains($0) }
        guard decodedCases.count == 1 else {
            throw Self.invalidPayload(decoder)
        }
        if container.contains(.lockHeld) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .lockHeld)
            guard Set(payload.allKeys) == [.fact] else {
                throw Self.invalidPayload(decoder)
            }
            self = try .lockHeld(payload.decode(GitLockFact.self, forKey: .fact))
        } else if container.contains(.lockUnidentified) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .lockUnidentified)
            guard Set(payload.allKeys) == [.resource] else {
                throw Self.invalidPayload(decoder)
            }
            self = try .lockUnidentified(payload.decode(GitLockResource.self, forKey: .resource))
        } else if container.contains(.permissionDenied) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .permissionDenied)
            guard Set(payload.allKeys).isSubset(of: [.path]) else {
                throw Self.invalidPayload(decoder)
            }
            self = try .permissionDenied(path: payload.decodeIfPresent(URL.self, forKey: .path))
        } else if container.contains(.gitFailure) {
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .gitFailure)
            guard Set(payload.allKeys) == [.kind] else {
                throw Self.invalidPayload(decoder)
            }
            self = try .gitFailure(payload.decode(GitLargeFileIndexFailureKind.self, forKey: .kind))
        } else {
            throw Self.invalidPayload(decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lockHeld(let fact):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .lockHeld)
            try payload.encode(fact, forKey: .fact)
        case .lockUnidentified(let resource):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .lockUnidentified)
            try payload.encode(resource, forKey: .resource)
        case .permissionDenied(let path):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .permissionDenied)
            try payload.encodeIfPresent(path, forKey: .path)
        case .gitFailure(let error):
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .gitFailure)
            try payload.encode(error, forKey: .kind)
        }
    }

    private static func invalidPayload(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "large-file index skip payload must contain exactly one valid cause"
            )
        )
    }
}
