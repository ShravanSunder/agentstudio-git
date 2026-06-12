import AgentStudioGitContracts
import CLibGit2Local
import Foundation

public struct LibGit2RepositoryPaths: Equatable, Sendable {
    public let gitDirectory: URL
    public let workDirectory: URL?
    public let commonDirectory: URL

    public init(gitDirectory: URL, workDirectory: URL?, commonDirectory: URL) {
        self.gitDirectory = gitDirectory
        self.workDirectory = workDirectory
        self.commonDirectory = commonDirectory
    }
}

public struct LibGit2RepositorySession: Sendable {
    private let runtime: LibGit2Runtime
    private let onRepositoryFreed: @Sendable () -> Void
    private let pathAccessors: LibGit2RepositoryPathAccessors

    public init() {
        self.init(runtime: .shared, onRepositoryFreed: {}, pathAccessors: .live)
    }

    init(
        runtime: LibGit2Runtime,
        onRepositoryFreed: @escaping @Sendable () -> Void = {},
        pathAccessors: LibGit2RepositoryPathAccessors = .live
    ) {
        self.runtime = runtime
        self.onRepositoryFreed = onRepositoryFreed
        self.pathAccessors = pathAccessors
    }

    public func repositoryPaths(at path: URL) throws -> LibGit2RepositoryPaths {
        try withRepository(at: path) { repository in
            try repository.paths()
        }
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (FilePrivateLibGit2RepositoryHandle) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repositoryPointer: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repositoryPointer, pathPointer, 0, nil)
        }

        guard openResult >= 0, let repositoryPointer else {
            throw LibGit2ErrorCapture.failure(
                code: openResult,
                fallbackMessage: "failed to open repository at \(path.path)"
            )
        }

        defer {
            git_repository_free(repositoryPointer)
            onRepositoryFreed()
        }

        return try body(
            FilePrivateLibGit2RepositoryHandle(
                repositoryPointer: repositoryPointer,
                pathAccessors: pathAccessors
            )
        )
    }
}

struct LibGit2RepositoryPathAccessors: @unchecked Sendable {
    static let live = Self(
        gitDirectory: { git_repository_path($0) },
        workDirectory: { git_repository_workdir($0) },
        commonDirectory: { git_repository_commondir($0) }
    )

    let gitDirectory: @Sendable (OpaquePointer) -> UnsafePointer<CChar>?
    let workDirectory: @Sendable (OpaquePointer) -> UnsafePointer<CChar>?
    let commonDirectory: @Sendable (OpaquePointer) -> UnsafePointer<CChar>?
}

private struct FilePrivateLibGit2RepositoryHandle {
    private let repositoryPointer: OpaquePointer
    private let pathAccessors: LibGit2RepositoryPathAccessors

    init(repositoryPointer: OpaquePointer, pathAccessors: LibGit2RepositoryPathAccessors) {
        self.repositoryPointer = repositoryPointer
        self.pathAccessors = pathAccessors
    }

    func paths() throws -> LibGit2RepositoryPaths {
        try LibGit2RepositoryPaths(
            gitDirectory: requiredGitURL(
                pathAccessors.gitDirectory(repositoryPointer),
                label: "git directory"
            ),
            workDirectory: optionalGitURL(pathAccessors.workDirectory(repositoryPointer)),
            commonDirectory: requiredGitURL(
                pathAccessors.commonDirectory(repositoryPointer),
                label: "common directory"
            )
        )
    }

    private func requiredGitURL(_ pointer: UnsafePointer<CChar>?, label: String) throws -> URL {
        guard let pointer else {
            throw LibGit2ErrorCapture.fallbackFailure(
                code: -1,
                message: "libgit2 returned no \(label) for an opened repository"
            )
        }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true).standardizedFileURL
    }

    private func optionalGitURL(_ pointer: UnsafePointer<CChar>?) -> URL? {
        guard let pointer else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true).standardizedFileURL
    }
}
