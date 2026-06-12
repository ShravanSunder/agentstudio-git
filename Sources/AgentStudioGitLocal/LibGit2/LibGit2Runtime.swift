import AgentStudioGitContracts
import CLibGit2Local
import Foundation

public final class LibGit2Runtime: @unchecked Sendable {
    public static let shared = LibGit2Runtime(initializeLibGit2: { git_libgit2_init() })

    private let lock = NSLock()
    private let initializeLibGit2: @Sendable () -> Int32
    private var initializedReferenceCount: Int32?

    init(initializeLibGit2: @escaping @Sendable () -> Int32) {
        self.initializeLibGit2 = initializeLibGit2
    }

    @discardableResult
    public func ensureInitialized() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        if let initializedReferenceCount {
            return initializedReferenceCount
        }

        let referenceCount = initializeLibGit2()
        guard referenceCount >= 0 else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: referenceCount,
                message: "libgit2 initialization failed with code \(referenceCount)"
            )
        }

        initializedReferenceCount = referenceCount
        return referenceCount
    }
}
