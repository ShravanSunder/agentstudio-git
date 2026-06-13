import AgentStudioGitContracts
import CLibGit2Local
import Foundation

func lightweightSnapshot(
    for worktree: OpaquePointer,
    parentRepository: OpaquePointer
) throws -> GitWorktreeSnapshot {
    let commonDirectory = try requiredGitURL(git_repository_commondir(parentRepository), label: "common directory")
    let path = try requiredGitURL(git_worktree_path(worktree), label: "worktree path")
    let canonicalPath = canonicalWorktreeURL(for: path)
    let repositoryID = GitRepositoryID(rawValue: "common:\(commonDirectory.path)")
    let displayName = try requiredGitString(git_worktree_name(worktree), label: "worktree name")
    let gitDirectory = commonDirectory.appending(path: "worktrees").appending(path: displayName)
    let lockState = try worktreeLockState(worktree)
    return GitWorktreeSnapshot(
        id: LibGit2WorktreeIDParser.worktreeID(repositoryID: repositoryID, canonicalPath: canonicalPath),
        repositoryID: repositoryID,
        displayName: displayName,
        path: path,
        canonicalPath: canonicalPath,
        gitDirectory: gitDirectory,
        indexPath: gitDirectory.appending(path: "index"),
        isMainWorktree: false,
        isLocked: lockState.isLocked,
        lockReason: lockState.reason,
        head: nil
    )
}

extension GitWorktreeSnapshot {
    func matches(parsedID: LibGit2ParsedWorktreeID?) -> Bool {
        guard let parsedID else {
            return false
        }
        return normalizedGitPath(for: canonicalPath) == normalizedGitPath(for: parsedID.canonicalPath)
    }
}
