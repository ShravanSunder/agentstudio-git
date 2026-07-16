import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("libgit2 runtime", .serialized)
struct LibGit2RuntimeTests {
    @Test("test runtime initializer runs libgit2 init once")
    func testRuntimeInitializerRunsLibGit2InitOnce() throws {
        let initializer = CountingLibGit2Initializer()
        let runtime = LibGit2Runtime(initializeLibGit2: initializer.initialize)

        let firstReferenceCount = try runtime.ensureInitialized()
        let secondReferenceCount = try runtime.ensureInitialized()

        #expect(firstReferenceCount == 1)
        #expect(secondReferenceCount == 1)
        #expect(initializer.calls == 1)
    }

    @Test("runtime init failure maps to typed libgit2 failure")
    func runtimeInitFailureMapsToTypedLibGit2Failure() {
        let runtime = LibGit2Runtime(initializeLibGit2: { -123 })

        do {
            _ = try runtime.ensureInitialized()
            Issue.record("runtime initialization unexpectedly succeeded")
        } catch let error as GitDataPlaneError {
            guard case .libgit2Failure(let code, let klass, let message) = error else {
                Issue.record("expected libgit2 failure, got \(error)")
                return
            }
            #expect(code == -123)
            #expect(klass == 0)
            #expect(message == "libgit2 initialization failed with code -123")
        } catch {
            Issue.record("expected GitDataPlaneError, got \(error)")
        }
    }

    @Test("discovery client returns typed failure when libgit2 cannot initialize")
    func discoveryClientReturnsTypedFailureWhenLibGit2CannotInitialize() async {
        let runtime = LibGit2Runtime(initializeLibGit2: { -123 })
        let client = LibGit2AgentStudioGitDiscoveryReadClient(runtime: runtime)

        let outcome = await client.readDiscoveryCandidate(
            GitDiscoveryReadRequest(candidatePath: URL(fileURLWithPath: "/tmp/repo"))
        )

        #expect(
            outcome
                == .failed(
                    GitDiscoveryReadFailure(
                        code: -123,
                        errorClass: 0,
                        message: "libgit2 initialization failed with code -123"
                    )
                )
        )
    }
}

private final class CountingLibGit2Initializer: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func initialize() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return Int32(callCount)
    }
}
