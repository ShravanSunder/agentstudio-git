import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2StatusObservationIdentityReader: Sendable {
    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func plan(for worktreePath: URL) throws -> GitStatusObservationPlan {
        try withRepository(at: worktreePath) { repository in
            try plan(repository: repository)
        }
    }

    func plan(repository: OpaquePointer) throws -> GitStatusObservationPlan {
        let worktreePath = try requiredGitURL(git_repository_workdir(repository), label: "work directory")
        let gitDirectory = try requiredGitURL(git_repository_path(repository), label: "Git directory")
        let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common Git directory")
        let indexPath = try GitIndexPathResolver().indexPath(repository: repository)
        var scopes = Set<GitStatusObservationScope>()

        scopes.insert(scope(.subtree, worktreePath))
        scopes.insert(scope(.item, indexPath))
        scopes.insert(scope(.item, gitDirectory.appending(path: "HEAD")))
        scopes.insert(scope(.item, gitDirectory.appending(path: "config.worktree")))
        scopes.insert(scope(.subtree, commonDirectory.appending(path: "refs", directoryHint: .isDirectory)))
        scopes.insert(scope(.item, commonDirectory.appending(path: "packed-refs")))
        scopes.insert(scope(.item, commonDirectory.appending(path: "config")))
        scopes.insert(scope(.item, commonDirectory.appending(path: "info/exclude")))

        let configDependencies = try configurationDependencies(repository: repository)
        scopes.formUnion(configDependencies.scopes)

        let gitModulesPath = worktreePath.appending(path: ".gitmodules")
        let hasSubmodules = FileManager.default.fileExists(atPath: gitModulesPath.path)
        if hasSubmodules {
            scopes.insert(scope(.item, gitModulesPath))
            scopes.insert(scope(.subtree, commonDirectory.appending(path: "modules", directoryHint: .isDirectory)))
        }

        let sortedScopes = scopes.sorted {
            ($0.path.path, $0.kind.rawValue) < ($1.path.path, $1.kind.rawValue)
        }
        let descriptor = sortedScopes.map { "\($0.kind.rawValue):\($0.path.path)" }.joined(separator: "\u{0}")
        let identity = GitStatusObservationIdentity(
            rawValue: Data(descriptor.utf8).base64EncodedString()
        )
        return GitStatusObservationPlan(
            identity: identity,
            scopes: sortedScopes,
            support: configDependencies.complete ? .supported : .unsupported
        )
    }

    private func configurationDependencies(
        repository: OpaquePointer
    ) throws -> (scopes: Set<GitStatusObservationScope>, complete: Bool) {
        var configuration: OpaquePointer?
        let configurationResult = git_repository_config(&configuration, repository)
        guard configurationResult >= 0, let configuration else {
            throw LibGit2ErrorCapture.failure(code: configurationResult)
        }
        defer { git_config_free(configuration) }

        var iterator: OpaquePointer?
        let iteratorResult = git_config_iterator_new(&iterator, configuration)
        guard iteratorResult >= 0, let iterator else {
            throw LibGit2ErrorCapture.failure(code: iteratorResult)
        }
        defer { git_config_iterator_free(iterator) }

        var scopes = Set<GitStatusObservationScope>()
        var complete = true
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let nextResult = git_config_next(&entry, iterator)
            if nextResult == GIT_ITEROVER.rawValue {
                break
            }
            guard nextResult >= 0, let entry else {
                throw LibGit2ErrorCapture.failure(code: nextResult)
            }
            guard let originPointer = entry.pointee.origin_path else {
                complete = false
                continue
            }
            let originPath = String(cString: originPointer)
            guard originPath.hasPrefix("/") else {
                complete = false
                continue
            }
            scopes.insert(scope(.item, URL(fileURLWithPath: originPath)))

        }

        var excludesPathBuffer = git_buf(ptr: nil, reserved: 0, size: 0)
        defer { git_buf_dispose(&excludesPathBuffer) }
        let excludesResult = "core.excludesfile".withCString {
            git_config_get_path(&excludesPathBuffer, configuration, $0)
        }
        if excludesResult == 0, let pathPointer = excludesPathBuffer.ptr {
            let excludesPath = String(cString: pathPointer)
            guard excludesPath.hasPrefix("/") else {
                return (scopes, false)
            }
            scopes.insert(scope(.item, URL(fileURLWithPath: excludesPath)))
        } else if excludesResult != GIT_ENOTFOUND.rawValue {
            complete = false
        }
        return (scopes, complete)
    }

    private func scope(_ kind: GitStatusObservationScopeKind, _ path: URL) -> GitStatusObservationScope {
        GitStatusObservationScope(kind: kind, path: canonicalURL(path))
    }

    private func canonicalURL(_ path: URL) -> URL {
        path.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func requiredGitURL(_ pointer: UnsafePointer<CChar>?, label: String) throws -> URL {
        guard let pointer else {
            throw LibGit2ErrorCapture.fallbackFailure(code: -1, message: "libgit2 returned no \(label)")
        }
        return canonicalURL(URL(fileURLWithPath: String(cString: pointer)))
    }

    private func withRepository<ReturnValue>(
        at path: URL,
        _ body: (OpaquePointer) throws -> ReturnValue
    ) throws -> ReturnValue {
        try runtime.ensureInitialized()
        var repository: OpaquePointer?
        let openResult = path.path.withCString { git_repository_open_ext(&repository, $0, 0, nil) }
        guard openResult >= 0, let repository else {
            throw repositoryOpenFailure(code: openResult, path: path)
        }
        defer { git_repository_free(repository) }
        return try body(repository)
    }
}
