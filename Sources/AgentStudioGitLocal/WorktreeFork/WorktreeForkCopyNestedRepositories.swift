import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Identifies same-repository linked worktrees before topology capture, from each gitfile alone: a nested
/// repository is never opened to classify it, because a broken one (a stale registration, alternates naming a
/// removed store) must still be classified rather than fail the fork.
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
            if try gitfileNamesSourceRegistration(gitEntryPath) { skipped.append(rootPath) }
        }
        return skipped.sorted()
    }

    /// True when the entry is a gitfile whose `gitdir:` resolves to a registration of the source repository,
    /// `worktrees/<name>` directly beneath its common directory. A `.git` directory, a gitfile naming any other
    /// repository, and a submodule of a linked worktree (`worktrees/<name>/modules/...`) are not.
    private func gitfileNamesSourceRegistration(_ relativePath: String) throws(GitWorktreeForkError) -> Bool {
        let file = sourceRoot.appending(path: relativePath)
        guard let recorded = try WorktreeForkGitfile.recordedGitDirectory(file, reportPath: relativePath) else {
            return false
        }
        let target =
            recorded.hasPrefix("/")
            ? URL(fileURLWithPath: recorded) : file.deletingLastPathComponent().appending(path: recorded)
        let canonical = WorktreeForkSourcePathRelocation.canonicalized(absolutePath: target.path)
        return canonical.deletingLastPathComponent().path == commonDirectory.appending(path: "worktrees").path
    }
}
