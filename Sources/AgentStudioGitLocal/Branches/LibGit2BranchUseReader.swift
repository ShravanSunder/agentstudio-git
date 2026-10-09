import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// Finds the worktree that holds a local branch by the rule `git worktree add` applies: a worktree's `HEAD`
/// names the branch, or, with `HEAD` detached, it is rebasing that branch (`rebase-merge/head-name`,
/// `rebase-apply/head-name` outside `git am`) or bisecting from it (`BISECT_START` while `BISECT_LOG` exists).
/// Each administration directory is read directly, so a worktree whose directory is missing and an unborn
/// branch still count. Any administration that cannot be read fails the read rather than reporting `free`: only a
/// file that does not exist (`ENOENT`) is absent; no search permission or an I/O error is a failure.
struct LibGit2BranchUseReader: Sendable {
    private static let unreadableAdministration = GitDataPlaneError.unsupported(
        message: "worktree administration is unreadable")

    private let runtime: LibGit2Runtime

    init(runtime: LibGit2Runtime = .shared) {
        self.runtime = runtime
    }

    func branchUse(_ request: GitBranchUseRequest) throws -> GitBranchUse {
        try runtime.ensureInitialized()
        var isValid: Int32 = 0
        guard !request.branchName.utf8.contains(0),
            request.branchName.withCString({ git_branch_name_is_valid(&isValid, $0) }) >= 0, isValid == 1
        else {
            throw GitDataPlaneError.unsupported(message: "branch name is invalid")
        }
        return try LibGit2ReviewSupport.withRepository(at: request.repositoryPath, runtime: runtime) { repository in
            for administration in try worktreeAdministrations(repository)
            where try holds(administration.gitDirectory, branchName: request.branchName) {
                return .inUse(worktreePath: administration.worktreePath)
            }
            return .free
        }
    }

    /// The main worktree (unless the common directory is bare) and every registered linked worktree.
    private func worktreeAdministrations(_ repository: OpaquePointer) throws -> [WorktreeAdministration] {
        let commonDirectory = try requiredGitURL(git_repository_commondir(repository), label: "common directory")
        var common: OpaquePointer?
        let openResult = commonDirectory.path.withCString {
            git_repository_open_ext(&common, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
        }
        guard openResult >= 0, let common else {
            throw repositoryOpenFailure(code: openResult, path: commonDirectory)
        }
        defer { git_repository_free(common) }

        var administrations: [WorktreeAdministration] = []
        if git_repository_is_bare(common) == 0, let workdir = git_repository_workdir(common) {
            administrations.append(
                WorktreeAdministration(
                    gitDirectory: commonDirectory,
                    worktreePath: canonicalWorktreeURL(for: URL(fileURLWithPath: String(cString: workdir)))
                ))
        }
        var names = git_strarray()
        let listResult = git_worktree_list(&names, common)
        guard listResult >= 0 else {
            throw LibGit2ErrorCapture.failure(code: listResult)
        }
        defer { git_strarray_free(&names) }
        var linked: [WorktreeAdministration] = []
        for position in 0..<names.count {
            guard let namePointer = names.strings[position] else {
                continue
            }
            var worktree: OpaquePointer?
            let lookupResult = git_worktree_lookup(&worktree, common, namePointer)
            guard lookupResult >= 0, let worktree else {
                throw LibGit2ErrorCapture.failure(code: lookupResult)
            }
            defer { git_worktree_free(worktree) }
            let worktreePath = try requiredGitURL(git_worktree_path(worktree), label: "worktree path")
            linked.append(
                WorktreeAdministration(
                    gitDirectory: commonDirectory.appending(path: "worktrees").appending(
                        path: String(cString: namePointer)),
                    worktreePath: canonicalWorktreeURL(for: worktreePath)
                ))
        }
        return administrations + linked.sorted { $0.worktreePath.path < $1.worktreePath.path }
    }

    private func holds(_ gitDirectory: URL, branchName: String) throws -> Bool {
        let head = try requiredText(gitDirectory.appending(path: "HEAD"))
        if head.hasPrefix("ref: ") {
            return Self.shortBranchName(String(head.dropFirst("ref: ".count))) == branchName
        }
        if try isDirectory(gitDirectory.appending(path: "rebase-apply")) {
            if try !exists(gitDirectory.appending(path: "rebase-apply/applying")),
                try optionalBranch(gitDirectory.appending(path: "rebase-apply/head-name")) == branchName
            {
                return true
            }
        } else if try isDirectory(gitDirectory.appending(path: "rebase-merge")),
            try optionalBranch(gitDirectory.appending(path: "rebase-merge/head-name")) == branchName
        {
            return true
        }
        guard try exists(gitDirectory.appending(path: "BISECT_LOG")) else {
            return false
        }
        return try optionalBranch(gitDirectory.appending(path: "BISECT_START")) == branchName
    }

    /// Git's own reading of these files: trailing newlines dropped, `refs/heads/` stripped.
    private static func shortBranchName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let prefix = "refs/heads/"
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    private func optionalBranch(_ file: URL) throws -> String? {
        guard try exists(file) else {
            return nil
        }
        return Self.shortBranchName(try requiredText(file))
    }

    private func requiredText(_ file: URL) throws -> String {
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw Self.unreadableAdministration
        }
    }

    private func exists(_ url: URL) throws -> Bool {
        guard case .success(let present) = WorktreeForkDescriptors.existence(url) else {
            throw Self.unreadableAdministration
        }
        return present
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        switch WorktreeForkDescriptors.lstatPath(url) {
        case .success(let info):
            return WorktreeForkEntryKind(mode: info.st_mode) == .directory
        case .failure(let failure) where failure.code == ENOENT:
            return false
        case .failure:
            throw Self.unreadableAdministration
        }
    }
}

private struct WorktreeAdministration {
    let gitDirectory: URL
    let worktreePath: URL
}
