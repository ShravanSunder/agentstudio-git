import Dispatch

/// Moves synchronous reads off Swift actor executors without owning product admission policy.
/// Callers retain queue limits and keep timed-out native work in physical slot custody until this await returns.
struct LibGit2BlockingReadExecutor: Sendable {
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void

    static let shared = Self { operation in
        executionQueue.async(execute: operation)
    }

    private static let executionQueue = DispatchQueue(
        label: "com.agentstudio.git.libgit2.blocking-read",
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    private let enqueueOperation: Enqueue

    init(enqueue: @escaping Enqueue) {
        enqueueOperation = enqueue
    }

    func execute<ReturnValue: Sendable>(
        _ operation: @escaping @Sendable () -> ReturnValue
    ) async -> ReturnValue {
        await withCheckedContinuation { continuation in
            enqueueOperation {
                continuation.resume(returning: operation())
            }
        }
    }

    func execute<ReturnValue: Sendable, Failure: Error & Sendable>(
        _ operation: @escaping @Sendable () throws(Failure) -> ReturnValue
    ) async throws(Failure) -> ReturnValue {
        let result: Result<ReturnValue, Failure> = await execute {
            do throws(Failure) {
                return .success(try operation())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}
