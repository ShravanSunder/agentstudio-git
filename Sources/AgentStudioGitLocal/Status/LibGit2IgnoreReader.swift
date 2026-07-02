import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2IgnoreReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func isPathIgnored(repositoryAt worktreePath: URL, relativePath: String) throws -> Bool {
        try withIgnoreSession(repositoryAt: worktreePath) { session in
            try session.isPathIgnored(relativePath: relativePath)
        }
    }

    func ignoredPaths(repositoryAt worktreePath: URL, relativePaths: [String]) throws -> [GitIgnoreCheck] {
        try withIgnoreSession(repositoryAt: worktreePath) { session in
            try relativePaths.map { relativePath in
                GitIgnoreCheck(
                    relativePath: relativePath,
                    isIgnored: try session.isPathIgnored(relativePath: relativePath)
                )
            }
        }
    }

    func withIgnoreSession<ReturnValue>(
        repositoryAt worktreePath: URL,
        _ body: (LibGit2IgnoreSession) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = worktreePath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: worktreePath)
        }

        let session = LibGit2IgnoreSession(repository: repository)
        return try body(session)
    }
}

/// Hot-walk ignore query session.
///
/// Create this through `LibGit2AgentStudioGitLocalClient.withIgnoreSession`;
/// that shape opens the repository once and then answers many
/// `git_ignore_path_is_ignored` checks. Directory paths should include a
/// trailing slash. A `true` result for a directory is prune-safe for filesystem
/// walks: git has excluded the directory itself, so parent-exclusion semantics
/// prevent descendants from being published by later negations.
public final class LibGit2IgnoreSession: @unchecked Sendable {
    private let repository: OpaquePointer
    private let lock = NSLock()

    init(repository: OpaquePointer) {
        self.repository = repository
    }

    deinit {
        git_repository_free(repository)
    }

    public func isPathIgnored(relativePath: String) throws -> Bool {
        let normalizedPath = try normalizedIgnorePath(relativePath)
        lock.lock()
        defer { lock.unlock() }

        var isIgnored: Int32 = 0
        let ignoreResult = normalizedPath.withCString { pathPointer in
            git_ignore_path_is_ignored(&isIgnored, repository, pathPointer)
        }
        guard ignoreResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: ignoreResult)
        }
        return isIgnored != 0
    }
}

private func normalizedIgnorePath(_ relativePath: String) throws -> String {
    guard !relativePath.isEmpty else {
        return relativePath
    }
    guard !relativePath.hasPrefix("/") else {
        throw GitDataPlaneError.pathEscapesRepository(path: relativePath)
    }
    let pathWithoutTrailingSlash =
        relativePath.last == "/"
        ? String(relativePath.dropLast())
        : relativePath
    let components = pathWithoutTrailingSlash.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
        throw GitDataPlaneError.pathEscapesRepository(path: relativePath)
    }
    return relativePath
}
