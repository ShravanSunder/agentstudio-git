import AgentStudioGitContracts
import CLibGit2Local
import Foundation

/// A caller-pinned commit: a full object identifier that must name a commit already in the repository.
/// It is never re-resolved as a revision, so a ref that moves after the caller read it cannot change it.
enum LibGit2PinnedCommit {
    static func objectID(_ text: String, label: String) throws(GitDataPlaneError) -> git_oid {
        var oid = git_oid()
        guard GitObjectIdentifierText.isFullObjectIdentifier(text),
            text.withCString({ git_oid_fromstr(&oid, $0) }) >= 0
        else {
            throw .unsupported(message: "\(label) must be a full object identifier")
        }
        return oid
    }

    /// Looks the commit up without peeling: a tag or tree identifier is refused, not followed.
    static func requireCommit(
        _ text: String,
        label: String,
        repository: OpaquePointer
    ) throws(GitDataPlaneError) -> git_oid {
        var oid = try objectID(text, label: label)
        var object: OpaquePointer?
        let lookupResult = git_object_lookup(&object, repository, &oid, GIT_OBJECT_ANY)
        guard lookupResult >= 0, let object else {
            if lookupResult == GIT_ENOTFOUND.rawValue {
                throw .requiredObjectNotFound(oid: text)
            }
            throw LibGit2ErrorCapture.failure(code: lookupResult)
        }
        defer { git_object_free(object) }
        guard git_object_type(object) == GIT_OBJECT_COMMIT else {
            throw .unsupported(message: "\(label) does not name a commit")
        }
        return oid
    }
}
