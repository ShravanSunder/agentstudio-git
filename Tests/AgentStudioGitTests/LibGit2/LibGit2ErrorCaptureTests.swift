import Foundation
import Testing

@testable import AgentStudioGitLocal

@Suite("libgit2 error capture", .serialized)
struct LibGit2ErrorCaptureTests {
    @Test("error capture copies current error details before later failures")
    func errorCaptureCopiesCurrentErrorDetailsBeforeLaterFailures() {
        let currentError = LockedErrorDetails(
            LibGit2ErrorDetails(klass: 7, message: "first libgit2 failure")
        )
        let errorSource = LibGit2ErrorSource {
            currentError.value
        }

        let firstFailure = LibGit2ErrorCapture.capture(code: -3, errorSource: errorSource)
        currentError.value = LibGit2ErrorDetails(klass: 9, message: "second libgit2 failure")
        let secondFailure = LibGit2ErrorCapture.capture(code: -4, errorSource: errorSource)

        #expect(firstFailure.code == -3)
        #expect(firstFailure.klass == 7)
        #expect(firstFailure.message == "first libgit2 failure")
        #expect(secondFailure.code == -4)
        #expect(secondFailure.klass == 9)
        #expect(secondFailure.message == "second libgit2 failure")
    }

    @Test("error capture uses fallback when libgit2 has no error details")
    func errorCaptureUsesFallbackWhenLibGit2HasNoErrorDetails() {
        let capturedError = LibGit2ErrorCapture.capture(
            code: -12,
            fallbackMessage: "fallback libgit2 failure",
            errorSource: LibGit2ErrorSource { nil }
        )

        #expect(capturedError.code == -12)
        #expect(capturedError.klass == 0)
        #expect(capturedError.message == "fallback libgit2 failure")
    }
}

private final class LockedErrorDetails: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: LibGit2ErrorDetails?

    init(_ value: LibGit2ErrorDetails?) {
        self.storedValue = value
    }

    var value: LibGit2ErrorDetails? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}
