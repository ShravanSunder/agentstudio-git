import AgentStudioGitContracts
import Foundation

public actor GitRepositoryWriterRegistry {
    private var writerByRepositoryID: [GitRepositoryID: GitRepositoryWriterLane] = [:]

    public init() {}

    public func writer(for identity: GitRepositoryIdentity) -> GitRepositoryWriterLane {
        if let writer = writerByRepositoryID[identity.id] {
            return writer
        }

        let writer = GitRepositoryWriterLane(
            repositoryID: identity.id,
            canonicalCommonDirectory: identity.canonicalCommonDirectory
        )
        writerByRepositoryID[identity.id] = writer
        return writer
    }
}

public actor GitRepositoryWriterLane {
    public nonisolated let laneID: UUID
    public nonisolated let repositoryID: GitRepositoryID
    public nonisolated let canonicalCommonDirectory: URL

    public init(repositoryID: GitRepositoryID, canonicalCommonDirectory: URL) {
        self.laneID = UUID()
        self.repositoryID = repositoryID
        self.canonicalCommonDirectory = canonicalCommonDirectory
    }
}
