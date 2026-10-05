import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Identifies same-repository linked worktrees before topology capture. A stale registration can
/// prevent libgit2 opening a worktree; its gitfile still identifies the common registration owner.
struct WorktreeForkCopyNestedRepositories {
    let sourceRoot: URL
    let commonDirectory: URL
    let cancellation: WorktreeForkCancellation

    /// The walker also finds bare caches and other Git directories without a `.git` entry. Confirm
    /// these candidates as topology planning does; an ordinary lookalike must still be classified.
    func confirmedGitDirectoryRoots(_ candidatePaths: [String]) throws(GitWorktreeForkError) -> [String] {
        var roots: [String] = []
        for relativePath in candidatePaths {
            try cancellation.throwIfCancelled()
            var repository: OpaquePointer?
            let flags = GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue | GIT_REPOSITORY_OPEN_BARE.rawValue
            let result = sourceRoot.appending(path: relativePath).path.withCString {
                git_repository_open_ext(&repository, $0, flags, nil)
            }
            guard result >= 0, let repository else { continue }
            // Opening validates directory shape, not HEAD syntax. A symbolic unborn HEAD is valid;
            // ordinary text in a lookalike's HEAD must not make its ignored children opaque.
            var headReference: OpaquePointer?
            let headResult = git_reference_lookup(&headReference, repository, "HEAD")
            let confirmed = headResult >= 0 && headReference != nil
            if let headReference { git_reference_free(headReference) }
            git_repository_free(repository)
            if confirmed { roots.append(relativePath) }
        }
        return roots
    }

    func sameRepositoryWorktreeRoots(_ gitEntryPaths: [String]) throws(GitWorktreeForkError) -> [String] {
        var skipped: [String] = []
        for gitEntryPath in gitEntryPaths {
            try cancellation.throwIfCancelled()
            let rootPath = WorktreeForkDescriptors.splitParent(gitEntryPath).parent
            if skipped.contains(where: { WorktreeForkFilesystemPlan.isPath(rootPath, within: $0) }) { continue }
            let root = sourceRoot.appending(path: rootPath)
            var repository: OpaquePointer?
            let result = root.path.withCString {
                git_repository_open_ext(&repository, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
            }
            let sameRepository: Bool
            if result >= 0, let repository {
                defer { git_repository_free(repository) }
                if let pointer = git_repository_commondir(repository),
                    case .success(let common) = WorktreeForkDescriptors.realpathURL(
                        URL(fileURLWithPath: String(cString: pointer)))
                {
                    sameRepository = common.path == commonDirectory.path
                } else {
                    sameRepository = try gitfileNamesSourceRegistration(gitEntryPath)
                }
            } else {
                sameRepository = try gitfileNamesSourceRegistration(gitEntryPath)
            }
            if sameRepository { skipped.append(rootPath) }
        }
        return skipped.sorted()
    }

    private func gitfileNamesSourceRegistration(_ relativePath: String) throws(GitWorktreeForkError) -> Bool {
        let file = sourceRoot.appending(path: relativePath)
        return try WorktreeForkDatalessGuardedRead.run(file, reportPath: relativePath) {
            () throws(GitWorktreeForkError) in
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("gitdir: ") else {
                return false
            }
            let targetText = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetText.isEmpty, !targetText.contains("\n") else { return false }
            let target =
                targetText.hasPrefix("/")
                ? URL(fileURLWithPath: targetText)
                : file.deletingLastPathComponent().appending(path: targetText)
            let canonical = WorktreeForkSourcePathRelocation.canonicalized(absolutePath: target.path)
            let registrations = commonDirectory.appending(path: "worktrees")
            guard canonical.path != registrations.path,
                WorktreeForkFilesystemPlan.isPath(canonical.path, within: registrations.path)
            else { return false }
            return true
        }
    }
}
