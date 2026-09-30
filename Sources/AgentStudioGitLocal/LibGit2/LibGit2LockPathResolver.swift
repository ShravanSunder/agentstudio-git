import AgentStudioGitContracts
import CLibGit2Local
import Foundation

enum LibGit2LockPathResolver {
    static func fact(for resource: GitLockResource, repository: OpaquePointer) throws -> GitLockFact {
        let resourcePath: URL
        switch resource {
        case .index:
            resourcePath = try repositoryItemPath(GIT_REPOSITORY_ITEM_INDEX, repository: repository)
        case .reference(let name):
            let repositoryDirectory = try referenceDirectory(for: name, repository: repository)
            resourcePath = repositoryDirectory.appending(path: name).standardizedFileURL
            guard resourcePath.path.hasPrefix(repositoryDirectory.path + "/") else {
                throw GitDataPlaneError.unsupported(message: "reference name escapes its Git directory")
            }
        case .packedRefs:
            resourcePath = try repositoryItemPath(GIT_REPOSITORY_ITEM_PACKED_REFS, repository: repository)
        case .config:
            resourcePath = try repositoryItemPath(GIT_REPOSITORY_ITEM_CONFIG, repository: repository)
        }

        return GitLockFact(
            path: URL(fileURLWithPath: resourcePath.path + ".lock").standardizedFileURL,
            resource: resource
        )
    }

    private static func referenceDirectory(for name: String, repository: OpaquePointer) throws -> URL {
        let isPerWorktreeReference =
            !name.hasPrefix("refs/")
            || name.hasPrefix("refs/bisect/")
            || name.hasPrefix("refs/worktree/")
            || name.hasPrefix("refs/rewritten/")
        let item = isPerWorktreeReference ? GIT_REPOSITORY_ITEM_GITDIR : GIT_REPOSITORY_ITEM_COMMONDIR
        return try repositoryItemPath(item, repository: repository)
    }

    private static func repositoryItemPath(
        _ item: git_repository_item_t,
        repository: OpaquePointer
    ) throws -> URL {
        var pathBuffer = git_buf()
        defer { git_buf_dispose(&pathBuffer) }

        let result = git_repository_item_path(&pathBuffer, repository, item)
        guard result >= 0, let path = pathBuffer.ptr else {
            throw LibGit2ErrorCapture.failure(code: result)
        }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
    }
}
