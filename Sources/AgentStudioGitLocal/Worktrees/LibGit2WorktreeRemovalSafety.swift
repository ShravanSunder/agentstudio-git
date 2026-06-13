import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct ResolvedWorktreeRemovalRequest: Sendable {
    let repositoryPath: URL
    let worktreeID: GitWorktreeID
}

struct WorktreeDirtiness: Sendable {
    var hasStagedChanges = false
    var hasDirtyTrackedChanges = false
    var hasUntrackedFiles = false
}

func worktreeDirtiness(at path: URL) throws -> WorktreeDirtiness {
    var dirtiness = WorktreeDirtiness()
    try LibGit2Runtime.shared.ensureInitialized()
    var repository: OpaquePointer?
    let openResult = path.path.withCString { pathPointer in
        git_repository_open_ext(&repository, pathPointer, 0, nil)
    }
    guard openResult >= 0, let repository else {
        throw repositoryOpenFailure(code: openResult, path: path)
    }
    defer { git_repository_free(repository) }

    var options = git_status_options()
    let optionsResult = git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
    guard optionsResult >= 0 else {
        throw LibGit2ErrorCapture.failure(code: optionsResult)
    }
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
    options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

    var statusList: OpaquePointer?
    let statusResult = git_status_list_new(&statusList, repository, &options)
    guard statusResult >= 0, let statusList else {
        throw LibGit2ErrorCapture.failure(code: statusResult)
    }
    defer { git_status_list_free(statusList) }

    for index in 0..<git_status_list_entrycount(statusList) {
        guard let entry = git_status_byindex(statusList, index) else {
            continue
        }
        let flags = entry.pointee.status
        if flags.containsAny(indexStatusFlags) || flags.containsAny([GIT_STATUS_CONFLICTED]) {
            dirtiness.hasStagedChanges = true
        }
        if flags.containsAny(dirtyWorktreeStatusFlags) {
            dirtiness.hasDirtyTrackedChanges = true
        }
        if flags.containsAny([GIT_STATUS_WT_NEW]) {
            dirtiness.hasUntrackedFiles = true
        }
    }

    return dirtiness
}

func metadataStillExists(worktreeID: GitWorktreeID) -> Bool {
    do {
        _ = try LibGit2WorktreeReader().snapshotForWorktreeID(worktreeID)
        return true
    } catch {
        return false
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<ReturnValue>(_ body: (UnsafePointer<CChar>?) -> ReturnValue) -> ReturnValue {
        switch self {
        case .some(let value):
            return value.withCString(body)
        case .none:
            return body(nil)
        }
    }
}

private let indexStatusFlags: [git_status_t] = [
    GIT_STATUS_INDEX_NEW,
    GIT_STATUS_INDEX_MODIFIED,
    GIT_STATUS_INDEX_DELETED,
    GIT_STATUS_INDEX_RENAMED,
    GIT_STATUS_INDEX_TYPECHANGE,
]

private let dirtyWorktreeStatusFlags: [git_status_t] = [
    GIT_STATUS_WT_MODIFIED,
    GIT_STATUS_WT_DELETED,
    GIT_STATUS_WT_TYPECHANGE,
    GIT_STATUS_WT_RENAMED,
    GIT_STATUS_WT_UNREADABLE,
]

extension git_status_t {
    fileprivate func containsAny(_ masks: [git_status_t]) -> Bool {
        masks.contains { mask in
            rawValue & mask.rawValue != 0
        }
    }
}
