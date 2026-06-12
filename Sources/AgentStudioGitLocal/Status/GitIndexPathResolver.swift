import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct GitIndexPathResolver: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func indexPath(for worktreePath: URL) throws -> URL {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = worktreePath.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: worktreePath)
        }
        defer { git_repository_free(repository) }

        return try indexPath(repository: repository)
    }

    func indexPath(repository: OpaquePointer) throws -> URL {
        var index: OpaquePointer?
        let indexResult = git_repository_index(&index, repository)
        guard indexResult >= 0, let index else {
            throw LibGit2ErrorCapture.failure(code: indexResult)
        }
        defer { git_index_free(index) }

        guard let pathPointer = git_index_path(index) else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned no index path for an opened repository"
            )
        }

        return URL(fileURLWithPath: String(cString: pathPointer), isDirectory: false).standardizedFileURL
    }
}
