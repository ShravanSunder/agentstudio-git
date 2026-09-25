import AgentStudioGitContracts
import Foundation

public actor GitRepositoryWriterRegistry {
    public static let shared = GitRepositoryWriterRegistry()

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

/// Owns FIFO execution of complete mutations for one canonical common Git directory.
///
/// Mutations run on the lane's dedicated serial dispatch queue rather than on the actor or the Swift
/// cooperative pool: a multi-second fork must not starve cooperative threads, and awaiting background
/// work from an actor would reopen reentrancy and let a second mutation interleave. The serial queue,
/// not actor suspension state, is the transaction boundary.
public actor GitRepositoryWriterLane {
    public nonisolated let laneID: UUID
    public nonisolated let repositoryID: GitRepositoryID
    public nonisolated let canonicalCommonDirectory: URL

    private nonisolated let mutationQueue: DispatchQueue
    private static let mutationQueueKey = DispatchSpecificKey<UUID>()

    init(repositoryID: GitRepositoryID, canonicalCommonDirectory: URL) {
        let laneID = UUID()
        self.laneID = laneID
        self.repositoryID = repositoryID
        self.canonicalCommonDirectory = canonicalCommonDirectory
        let mutationQueue = DispatchQueue(
            label: "com.agentstudio.git.repository-writer",
            autoreleaseFrequency: .workItem
        )
        mutationQueue.setSpecific(key: Self.mutationQueueKey, value: laneID)
        self.mutationQueue = mutationQueue
    }

    /// True only while executing a mutation submitted to this lane.
    nonisolated var isExecutingOnLaneQueue: Bool {
        DispatchQueue.getSpecific(key: Self.mutationQueueKey) == laneID
    }

    /// Enqueues `operation` behind every previously submitted mutation and resumes the caller with exactly
    /// its result once it has finished. `onEnqueued` fires after the mutation holds its FIFO position.
    nonisolated func run<ReturnValue: Sendable, Failure: Error>(
        _ operation: @escaping @Sendable () throws(Failure) -> ReturnValue,
        onEnqueued: (@Sendable () -> Void)? = nil
    ) async throws(Failure) -> ReturnValue {
        let result: Result<ReturnValue, Failure> = await withCheckedContinuation { continuation in
            mutationQueue.async {
                do throws(Failure) {
                    continuation.resume(returning: .success(try operation()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            onEnqueued?()
        }
        return try result.get()
    }
}
