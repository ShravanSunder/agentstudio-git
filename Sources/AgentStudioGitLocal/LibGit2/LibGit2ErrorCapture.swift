import AgentStudioGitContracts
import AgentStudioGitLockSupport
import CLibGit2Local
import Darwin
import Foundation

struct LibGit2CapturedError: Equatable, Sendable {
    let code: Int32
    let klass: Int32
    let message: String
}

struct LibGit2ErrorDetails: Equatable, Sendable {
    let klass: Int32
    let message: String?
}

struct LibGit2ErrorSource: @unchecked Sendable {
    static let live = Self {
        guard let errorPointer = git_error_last() else {
            return nil
        }

        let error = errorPointer.pointee
        return LibGit2ErrorDetails(
            klass: Int32(error.klass),
            message: error.message.map { String(cString: $0) }
        )
    }

    let lastError: @Sendable () -> LibGit2ErrorDetails?
}

enum LibGit2ErrorCapture {
    static func capture(
        code: Int32,
        fallbackMessage: String? = nil,
        errorSource: LibGit2ErrorSource = .live
    ) -> LibGit2CapturedError {
        guard let errorDetails = errorSource.lastError() else {
            return LibGit2CapturedError(
                code: code,
                klass: 0,
                message: fallbackMessage ?? "libgit2 error \(code)"
            )
        }

        let message =
            errorDetails.message
            ?? fallbackMessage
            ?? "libgit2 error \(code)"

        return LibGit2CapturedError(
            code: code,
            klass: errorDetails.klass,
            message: message
        )
    }

    static func failure(
        code: Int32,
        lockFact: GitLockFact? = nil,
        systemErrorCode: Int32 = 0,
        residueObserver: GitLockResidueObserver = .live,
        fallbackMessage: String? = nil,
        errorSource: LibGit2ErrorSource = .live
    ) -> GitDataPlaneError {
        if let lockFact {
            if code == Int32(GIT_ELOCKED.rawValue) {
                if residueObserver.status(of: lockFact.path) == .present {
                    return .lockHeld(lockFact)
                }
                if systemErrorCode == EACCES || deniedLockDirectory(for: lockFact.path) != nil {
                    return .permissionDenied(path: lockFact.path.deletingLastPathComponent())
                }
                return .lockUnidentified(lockFact.resource)
            }
            if systemErrorCode == EACCES || deniedLockDirectory(for: lockFact.path) != nil {
                return .permissionDenied(path: lockFact.path.deletingLastPathComponent())
            }
        }

        let capturedError = capture(
            code: code,
            fallbackMessage: fallbackMessage,
            errorSource: errorSource
        )
        return failure(capturedError)
    }

    static func fallbackFailure(code: Int32, message: String) -> GitDataPlaneError {
        failure(LibGit2CapturedError(code: code, klass: 0, message: message))
    }

    private static func failure(_ capturedError: LibGit2CapturedError) -> GitDataPlaneError {
        .libgit2Failure(
            code: capturedError.code,
            klass: capturedError.klass,
            message: capturedError.message
        )
    }

    private static func deniedLockDirectory(for lockPath: URL) -> URL? {
        let directoryPath = lockPath.deletingLastPathComponent()
        guard directoryPath.path.withCString({ access($0, W_OK | X_OK) }) != 0, errno == EACCES else {
            return nil
        }
        return directoryPath
    }
}
