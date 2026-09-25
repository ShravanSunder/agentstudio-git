import Foundation

/// Captured Git structure beneath the source root: every initialized nested Git node, the registered
/// submodules that stay uninitialized, sparse intent, and the object stores that need CoW mirrors.
struct WorktreeForkGitTopology: Sendable {
    let rootSparse: WorktreeForkSparsePlan?
    /// Nil when libgit2 cannot read the root source index (for example a sparse index).
    let rootSourceIndex: WorktreeForkSourceIndexSnapshot?
    /// Parent-before-child.
    let nodes: [WorktreeForkGitNode]
    let uninitializedSubmodulePaths: [String]
    /// Canonical source object directories reachable through nested alternates, deduplicated.
    let mirroredObjectStores: [URL]
    /// Mirror link text for store-internal symlinks, keyed by store then store-relative path.
    let mirroredStoreSymlinks: [URL: [String: String]]
}

enum WorktreeForkGitNodeKind: Equatable, Sendable {
    /// Registered in its parent's captured tree; administration lives under the parent's `modules/`.
    case submodule(name: String)
    /// Independent repository with an embedded `.git` directory.
    case embeddedRepository
    /// Independent repository reached through a gitfile (linked worktree or absorbed layout); its private
    /// and common administration are flattened into an embedded destination `.git` directory.
    case flattenedRepository
}

struct WorktreeForkGitNode: Sendable {
    /// Worktree-relative directory of the nested working tree.
    let relativePath: String
    /// Nearest enclosing node, or nil when the parent is the fork root.
    let parentRelativePath: String?
    let kind: WorktreeForkGitNodeKind
    /// Worktree-private administration (`$GIT_DIR`).
    let sourceGitDirectory: URL
    let sourceCommonDirectory: URL
    /// Nil for an unborn repository.
    let capturedHead: WorktreeForkCapturedHead?
    /// `refs/heads/...` when `HEAD` is symbolic; nil when detached.
    let headReferenceName: String?
    let sparse: WorktreeForkSparsePlan?
    let sourceIndex: WorktreeForkSourceIndexSnapshot?
    /// Canonical object directories this node's common object store borrows from.
    let alternateObjectStores: [URL]
    /// Symlinks inside the node's common administration, keyed by administration-relative path.
    let administrativeSymlinks: [String: WorktreeForkAdministrativeSymlink]
}

/// Sparse intent for one Git node, captured from its source administration.
struct WorktreeForkSparsePlan: Equatable, Sendable {
    let patternFile: Data
    /// The node's `config.worktree`, reproduced with sparse-index compression disabled.
    let worktreeConfiguration: Data?
    let skipWorktreePaths: Set<String>
}
