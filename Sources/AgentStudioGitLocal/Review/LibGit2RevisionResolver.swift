import AgentStudioGitContracts
import CLibGit2Local
import Foundation

struct LibGit2RevisionResolver: Sendable {
    func resolve(_ request: GitRevisionResolutionRequest) throws -> GitResolvedRevision {
        try LibGit2ReviewSupport.withRepository(at: request.repositoryPath) { repository in
            let commit = try LibGit2ReviewSupport.resolveCommit(request.target, repository: repository)
            defer { git_commit_free(commit) }

            let oid = LibGit2ReviewSupport.oidString(git_commit_id(commit))
            return GitResolvedRevision(
                oid: oid,
                shortName: shortName(for: request.target, repository: repository)
            )
        }
    }

    private func shortName(for target: GitRevisionTarget, repository: OpaquePointer) -> String? {
        guard target.name == "HEAD" else {
            return target.name.count == 40 ? nil : target.name
        }

        var reference: OpaquePointer?
        let headResult = git_repository_head(&reference, repository)
        guard headResult >= 0, let reference else {
            return nil
        }
        defer { git_reference_free(reference) }

        guard let shorthandPointer = git_reference_shorthand(reference) else {
            return nil
        }
        return String(cString: shorthandPointer)
    }
}
