import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2TrackedPathReader: Sendable {
    private let runtime: LibGit2Runtime
    private let indexPathResolver: GitIndexPathResolver

    init(
        runtime: LibGit2Runtime = .shared,
        indexPathResolver: GitIndexPathResolver = GitIndexPathResolver()
    ) {
        self.runtime = runtime
        self.indexPathResolver = indexPathResolver
    }

    func trackedPaths(for worktreePath: URL, options: GitTrackedPathsOptions) throws -> GitTrackedPathsSnapshot {
        let normalizedScopePath = try normalizedScopePath(options.scopePath)
        return try withRepository(at: worktreePath) { repository in
            _ = try indexPathResolver.indexPath(repository: repository)
            var index: OpaquePointer?
            let indexResult = git_repository_index(&index, repository)
            guard indexResult >= 0, let index else {
                throw LibGit2ErrorCapture.failure(code: indexResult)
            }
            defer { git_index_free(index) }

            let entryCount = git_index_entrycount(index)
            let entries = try (0..<entryCount).compactMap { entryIndex -> GitTrackedPathEntry? in
                guard let entryPointer = git_index_get_byindex(index, entryIndex) else {
                    throw LibGit2ErrorCapture.fallbackFailure(
                        code: -1,
                        message: "libgit2 returned no index entry at index \(entryIndex)"
                    )
                }
                guard git_index_entry_stage(entryPointer) == 0 else {
                    return nil
                }
                let entry = entryPointer.pointee
                let path = try trackedPath(entry)
                guard includes(path: path, normalizedScopePath: normalizedScopePath) else {
                    return nil
                }
                return GitTrackedPathEntry(path: path, kind: trackedPathKind(mode: entry.mode))
            }
            .sorted { $0.path < $1.path }

            return GitTrackedPathsSnapshot(entries: entries, rawIndexEntryCount: Int(entryCount))
        }
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()

        var repository: OpaquePointer?
        let openResult = path.path.withCString { pathPointer in
            git_repository_open_ext(&repository, pathPointer, 0, nil)
        }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }

        return try body(repository)
    }
}

private func trackedPath(_ entry: git_index_entry) throws -> String {
    guard let pathPointer = entry.path else {
        throw LibGit2ErrorCapture.fallbackFailure(
            code: -1,
            message: "libgit2 returned an index entry without a path"
        )
    }
    return String(cString: pathPointer)
}

private func normalizedScopePath(_ scopePath: String?) throws -> String? {
    guard let scopePath, !scopePath.isEmpty else {
        return nil
    }
    if scopePath.allSatisfy({ $0 == "/" }) {
        return nil
    }
    if scopePath.hasPrefix("/") {
        throw GitDataPlaneError.pathEscapesRepository(path: scopePath)
    }
    let normalizedScopePath = scopePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalizedScopePath.isEmpty else {
        return nil
    }
    let components = normalizedScopePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
        throw GitDataPlaneError.pathEscapesRepository(path: scopePath)
    }
    return normalizedScopePath
}

private func includes(path: String, normalizedScopePath: String?) -> Bool {
    guard let normalizedScopePath else {
        return true
    }
    return path == normalizedScopePath || path.hasPrefix("\(normalizedScopePath)/")
}

private func trackedPathKind(mode: UInt32) -> GitTrackedPathKind {
    if mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) {
        return .submodule
    }
    if mode == UInt32(GIT_FILEMODE_LINK.rawValue) {
        return .symlink
    }
    return .file
}
