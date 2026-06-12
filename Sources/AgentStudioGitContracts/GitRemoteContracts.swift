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
