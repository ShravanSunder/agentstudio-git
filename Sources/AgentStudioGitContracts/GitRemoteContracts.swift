import Foundation

public enum GitRemotePromptPolicy: String, Codable, CaseIterable, Sendable {
    case noninteractive
    case trustedInteractive
}

public enum GitRemoteProtocol: String, Codable, CaseIterable, Sendable {
    case file
    case git
    case http
    case https
    case ssh
}

public struct GitCloneRequest: Codable, Equatable, Hashable, Sendable {
    public let remoteURL: String
    public let destinationPath: URL
    public let checkoutBranch: String?

    public init(remoteURL: String, destinationPath: URL, checkoutBranch: String?) {
        self.remoteURL = remoteURL
        self.destinationPath = destinationPath
        self.checkoutBranch = checkoutBranch
    }
}

public struct GitCloneResult: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL

    public init(repositoryPath: URL) {
        self.repositoryPath = repositoryPath
    }
}

public struct GitFetchRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let remoteName: String

    public init(repositoryPath: URL, remoteName: String) {
        self.repositoryPath = repositoryPath
        self.remoteName = remoteName
    }
}

public struct GitFetchResult: Codable, Equatable, Hashable, Sendable {
    public let fetchedRemoteName: String

    public init(fetchedRemoteName: String) {
        self.fetchedRemoteName = fetchedRemoteName
    }
}

public struct GitRemoteTrackingSnapshotRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let remoteName: String

    public init(repositoryPath: URL, remoteName: String) {
        self.repositoryPath = repositoryPath
        self.remoteName = remoteName
    }
}

public struct GitRemoteTrackingReference: Codable, Equatable, Hashable, Sendable {
    public let canonicalRefName: String
    public let oid: String

    public init(canonicalRefName: String, oid: String) {
        self.canonicalRefName = canonicalRefName
        self.oid = oid
    }
}

public struct GitRemoteTrackingSnapshot: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let repositoryCommonDirectory: URL
    public let remoteName: String
    public let configuredRemoteURL: String
    public let effectiveFetchURL: String
    public let references: [GitRemoteTrackingReference]

    public init(
        repositoryPath: URL,
        repositoryCommonDirectory: URL,
        remoteName: String,
        configuredRemoteURL: String,
        effectiveFetchURL: String,
        references: [GitRemoteTrackingReference]
    ) {
        self.repositoryPath = repositoryPath
        self.repositoryCommonDirectory = repositoryCommonDirectory
        self.remoteName = remoteName
        self.configuredRemoteURL = configuredRemoteURL
        self.effectiveFetchURL = effectiveFetchURL
        self.references = references
    }
}

public struct GitStagedFetchRequest: Codable, Equatable, Hashable, Sendable {
    public let snapshot: GitRemoteTrackingSnapshot
    public let stagingID: UUID

    public init(snapshot: GitRemoteTrackingSnapshot, stagingID: UUID) {
        self.snapshot = snapshot
        self.stagingID = stagingID
    }
}

public struct GitStagedFetchUpdate: Codable, Equatable, Hashable, Sendable {
    public let stagingRefName: String
    public let canonicalRefName: String
    public let newOID: String
    public let expectedOldOID: String?

    public init(
        stagingRefName: String,
        canonicalRefName: String,
        newOID: String,
        expectedOldOID: String?
    ) {
        self.stagingRefName = stagingRefName
        self.canonicalRefName = canonicalRefName
        self.newOID = newOID
        self.expectedOldOID = expectedOldOID
    }
}

public struct GitStagedFetchDeletion: Codable, Equatable, Hashable, Sendable {
    public let canonicalRefName: String
    public let expectedOldOID: String

    public init(canonicalRefName: String, expectedOldOID: String) {
        self.canonicalRefName = canonicalRefName
        self.expectedOldOID = expectedOldOID
    }
}

public struct GitStagedFetchResult: Codable, Equatable, Hashable, Sendable {
    public let snapshot: GitRemoteTrackingSnapshot
    public let handle: GitStagedFetchHandle
    public let updates: [GitStagedFetchUpdate]
    public let verifications: [GitStagedFetchVerification]
    public let deletions: [GitStagedFetchDeletion]

    public var stagingNamespace: String {
        handle.stagingNamespace
    }

    public init(
        snapshot: GitRemoteTrackingSnapshot,
        handle: GitStagedFetchHandle,
        updates: [GitStagedFetchUpdate],
        verifications: [GitStagedFetchVerification],
        deletions: [GitStagedFetchDeletion]
    ) {
        self.snapshot = snapshot
        self.handle = handle
        self.updates = updates
        self.verifications = verifications
        self.deletions = deletions
    }
}

public struct GitStagedFetchHandle: Codable, Equatable, Hashable, Sendable {
    public let repositoryCommonDirectory: URL
    public let stagingID: UUID

    public var stagingNamespace: String {
        "refs/agentstudio/staged/\(stagingID.uuidString.lowercased())/"
    }

    public init(repositoryCommonDirectory: URL, stagingID: UUID) {
        self.repositoryCommonDirectory = repositoryCommonDirectory
        self.stagingID = stagingID
    }
}

public struct GitStagedFetchVerification: Codable, Equatable, Hashable, Sendable {
    public let stagingRefName: String
    public let canonicalRefName: String
    public let expectedOID: String

    public init(stagingRefName: String, canonicalRefName: String, expectedOID: String) {
        self.stagingRefName = stagingRefName
        self.canonicalRefName = canonicalRefName
        self.expectedOID = expectedOID
    }
}

public struct GitPromoteStagedFetchRequest: Codable, Equatable, Hashable, Sendable {
    public let stagedFetch: GitStagedFetchResult

    public init(stagedFetch: GitStagedFetchResult) {
        self.stagedFetch = stagedFetch
    }
}

public struct GitPromoteStagedFetchResult: Codable, Equatable, Hashable, Sendable {
    public let updatedRefNames: [String]
    public let deletedRefNames: [String]

    public init(updatedRefNames: [String], deletedRefNames: [String]) {
        self.updatedRefNames = updatedRefNames
        self.deletedRefNames = deletedRefNames
    }
}

public struct GitCleanupStagedFetchRequest: Codable, Equatable, Hashable, Sendable {
    public let handle: GitStagedFetchHandle

    public init(handle: GitStagedFetchHandle) {
        self.handle = handle
    }
}

public struct GitCleanupStagedFetchResult: Codable, Equatable, Hashable, Sendable {
    public let deletedRefNames: [String]
    public let retainedRefNames: [String]

    public init(deletedRefNames: [String], retainedRefNames: [String]) {
        self.deletedRefNames = deletedRefNames
        self.retainedRefNames = retainedRefNames
    }
}

public struct GitCleanupAbandonedStagedFetchesRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryCommonDirectory: URL
    public let retainedStagingIDs: Set<UUID>

    public init(repositoryCommonDirectory: URL, retainedStagingIDs: Set<UUID>) {
        self.repositoryCommonDirectory = repositoryCommonDirectory
        self.retainedStagingIDs = retainedStagingIDs
    }
}

public struct GitPushRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let remoteName: String
    public let refspec: String

    public init(repositoryPath: URL, remoteName: String, refspec: String) {
        self.repositoryPath = repositoryPath
        self.remoteName = remoteName
        self.refspec = refspec
    }
}

public struct GitPushResult: Codable, Equatable, Hashable, Sendable {
    public let pushedRefspec: String

    public init(pushedRefspec: String) {
        self.pushedRefspec = pushedRefspec
    }
}

public struct GitRemoteReferencesRequest: Codable, Equatable, Hashable, Sendable {
    public let remoteURL: String

    public init(remoteURL: String) {
        self.remoteURL = remoteURL
    }
}

public struct GitRemoteReference: Codable, Equatable, Hashable, Sendable {
    public let oid: String
    public let name: String
    public let peeledOID: String?
    public let symrefTarget: String?

    public init(oid: String, name: String, peeledOID: String?, symrefTarget: String? = nil) {
        self.oid = oid
        self.name = name
        self.peeledOID = peeledOID
        self.symrefTarget = symrefTarget
    }
}
