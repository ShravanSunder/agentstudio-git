import AgentStudioGitContracts
import CLibGit2Local
import Darwin
import Foundation

/// Copy policy needs every index path, including conflicts and intent-to-add. Clean-adoption's
/// narrower snapshot cannot authorize exclusion. No index or configuration state is refreshed here.
struct WorktreeForkCopyTrackedPaths: Sendable {
    let paths: Set<String>
    let ignoreCase: Bool

    static func capture(sourceRoot: URL, gitDirectory: URL, capturedHead: WorktreeForkCapturedHead)
        throws(GitWorktreeForkError) -> Self
    {
        let repository = try WorktreeForkGitHandles.openWorktree(sourceRoot)
        defer { git_repository_free(repository) }
        var configuration: OpaquePointer?
        let configResult = git_repository_config_snapshot(&configuration, repository)
        guard configResult >= 0, let configuration else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: configResult))
        }
        defer { git_config_free(configuration) }
        var ignoreCaseValue: Int32 = 0
        let caseResult = git_config_get_bool(&ignoreCaseValue, configuration, "core.ignorecase")
        guard caseResult >= 0 || caseResult == GIT_ENOTFOUND.rawValue else {
            throw .gitFailure(LibGit2ErrorCapture.failure(code: caseResult))
        }
        let ignoreCase = caseResult >= 0 && ignoreCaseValue != 0
        let headPaths = try WorktreeForkGitHandles.treeEntries(capturedHead.treeOID, repository: repository).keys
        let indexPaths = try readIndexPaths(gitDirectory.appending(path: "index"))
        return Self(
            paths: Set((Array(headPaths) + indexPaths).map { ignoreCase ? $0.lowercased() : $0 }),
            ignoreCase: ignoreCase)
    }

    private static func readIndexPaths(_ indexPath: URL) throws(GitWorktreeForkError) -> [String] {
        switch WorktreeForkDescriptors.lstatPath(indexPath) {
        case .failure(let failure) where failure.code == ENOENT: return []
        case .failure: throw .rejected(reason: .sourceIndexUnreadable)
        case .success: break
        }
        var index: OpaquePointer?
        let result = indexPath.path.withCString { git_index_open(&index, $0) }
        guard result >= 0, let index else {
            let message = git_error_last().flatMap { $0.pointee.message }.map { String(cString: $0) } ?? ""
            if message == "unsupported mandatory extension: 'sdir'"
                || message == "unsupported mandatory extension: 'link'"
            {
                throw .rejected(reason: .sourceIndexUnsupported)
            }
            throw .rejected(reason: .sourceIndexUnreadable)
        }
        defer { git_index_free(index) }
        var paths: [String] = []
        for position in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, position), let path = entry.pointee.path else {
                throw .rejected(reason: .sourceIndexUnreadable)
            }
            paths.append(String(cString: path))
        }
        return paths
    }
}
