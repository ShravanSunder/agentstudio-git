# AgentStudioGit Libgit2 Data Plane Spec

## Goal

`agentstudio-git` is a standalone SwiftPM package that AgentStudio imports to perform fast, correct local Git operations through libgit2.

The package exists because AgentStudio needs dependable worktree, status, branch, diff, and content facts for repo enrichment and Bridge review surfaces. It is not a CLI wrapper, not a Bridge model package, and not a GitHub/network client.

## Non-Goals

- No `git` CLI implementation path in production.
- No `gh` authentication integration.
- No clone, fetch, push, remote negotiation, SSH auth, or HTTPS auth in the first implementation.
- No Bridge DTOs, review packages, atoms, stores, pane controllers, persistence, or UI.
- No patch application or source mutation from Bridge review surfaces.
- No command/response envelope inside this package. AgentStudio already has transport/correlation layers where needed.

## Vocabulary

Use “Git compatibility tests” for tests that compare package output against the behavior of a real Git repository. Avoid jargon that makes Git commands sound like a product architecture.

Git commands may appear in tests as a reference for expected Git behavior over controlled fixtures. They are not the product implementation.

## Source Research

- libgit2 threading docs: most objects cannot be safely accessed by multiple threads at the same time; use an object from a single thread at a time; `git_error_last()` must be read on the same thread as the failure.
  https://github.com/libgit2/libgit2/blob/main/docs/threading.md
- libgit2 worktree API: list, lookup, open, add, lock, unlock, locked-state, name, path, prune.
  https://github.com/libgit2/libgit2/blob/main/include/git2/worktree.h
- libgit2 index write docs: `git_index_write` writes the index with an atomic file lock.
  https://libgit2.org/docs/reference/main/index/git_index_write.html
- Git worktree docs: linked worktrees have metadata, can be locked, and list output includes locked/prunable state.
  https://git-scm.com/docs/git-worktree
- libgit2 build docs and README: CMake build, static/shared options, `USE_SSH`, `USE_HTTPS`, local dependency choices.
  https://libgit2.org/docs/guides/build-and-link/
  https://github.com/libgit2/libgit2/blob/main/README.md

## Packaging Decision

Use an AgentStudio-owned Swift API package that links a pinned, local-only static libgit2 build.

Implementation stages:

1. Build and validate libgit2 through a repo-owned script that produces a local static XCFramework.
2. Consume that XCFramework from SwiftPM through an internal binary target.
3. Keep the build recipe in the repo so the binary is reproducible and maintainable.
4. Before AgentStudio release consumption, publish the XCFramework as a versioned release artifact with a SwiftPM checksum.

Initial libgit2 build profile:

```bash
cmake -S vendor/libgit2 -B .build/libgit2 \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_CLAR=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DUSE_SSH=OFF \
  -DUSE_HTTPS=OFF \
  -DUSE_GSSAPI=OFF
```

This avoids Homebrew/system-library runtime dependency and avoids network/auth surface in the first implementation. Local Git operations still include repository open, object reads, refs, branches, index reads, status, worktree metadata, worktree add/prune, and diffs.

## Authentication

Local operations do not use `git` auth or `gh` auth. libgit2 reads local `.git` data directly.

Authentication is only relevant for network operations such as clone/fetch/push. Those operations are out of scope for the first implementation, so SSH and HTTPS support stay off.

## Locking And Concurrency

A Swift `RepositoryActor` does not create Git lock files. It serializes our process’s mutation work so libgit2 objects and shared repository state are not touched unsafely.

Git lock files are created by Git/libgit2 write operations. Examples:

- `git_index_write` creates an atomic index lock.
- ref writes/deletes/renames create loose ref locks and may rewrite `packed-refs`.
- config writes lock the config file.
- `git_worktree_lock` writes a worktree administrative `locked` file with an optional reason.

Other processes can still hold locks. AgentStudioGit must surface lock failures as typed errors and must not auto-delete lock files.

Concurrency model:

- `GitRepositoryWriterActor`, keyed by canonical common git directory, serializes mutating operations:
  - create worktree
  - prune/remove worktree
  - worktree lock/unlock
  - branch/ref creation, deletion, rename
  - config writes
  - any status/diff option that updates the index
- Read operations use isolated per-operation sessions and return immutable values:
  - list worktrees
  - validate worktree
  - status without index updates
  - diff without index updates
  - branch/ref reads
  - blob/tree/content reads

No libgit2 pointer type crosses an actor or task boundary. All `git_*_free` calls happen with `defer` in the same synchronous frame that acquired the pointer.

`git_error_last()` is copied synchronously in the same failing call frame before any `await`.

## Public API Shape

The package exposes method-oriented Swift APIs, not transport envelopes.

```swift
public protocol AgentStudioGitClient: Sendable {
    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot]
    func validateWorktree(repositoryPath: URL, name: String) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError) -> GitStatusSnapshot
    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot]
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeRemovalResult
    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot
    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload
}
```

Status uses a two-axis model. Git status is not one kind plus `isStaged`.

```swift
public enum GitStatusState: String, Codable, CaseIterable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
    case unmerged
}

public struct GitStatusEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let previousPath: String?
    public let indexState: GitStatusState?
    public let worktreeState: GitStatusState?
    public let ignored: Bool
    public let untracked: Bool
}
```

Line counts, binary flags, hunks, mode changes, and content hashes belong to diff/content payloads, not status entries.

## Identity And Path Rules

- Public input paths are `URL`, not raw `String`.
- The package canonicalizes filesystem paths before building IDs.
- Worktree IDs are stable value IDs derived from canonical common git directory plus canonical worktree path.
- The main worktree gets an explicit synthetic name, `main`, only in package output; callers must not assume libgit2 has a main-worktree name.
- The package must preserve both display path and canonical identity path when they differ.

## AgentStudio Boundaries

AgentStudio integration has two consumers:

1. App-wide Git enrichment:
   - adapter replaces shell parsing behind `GitWorkingTreeStatusProvider`
   - package returns branch/head/status facts
2. Bridge review foundation:
   - adapter maps Git-shaped package values into Bridge-owned review contracts
   - Bridge keeps `BridgeReviewSourceProvider`, `BridgeReviewPackage`, `BridgeContentHandle`, filters, annotations, and URL scheme details

Worktrunk remains the user-facing worktree UX layer until a separate AgentStudio product decision moves create/remove/switch behavior to AgentStudioGit-backed commands.

## Testing Pyramid

Unit tests:

- public payload round trips
- enum raw-value snapshots
- invalid/unknown discriminator decoding
- typed error mapping
- path canonicalization
- two-axis status states such as staged+modified

Integration tests:

- create temporary real Git repositories
- create controlled fixture states
- verify package output matches expected Git behavior for those fixture states
- include clean, modified, staged, staged+modified, renamed, deleted, untracked, ignored, binary, linked worktree, locked worktree, and stale metadata cases

C interop tests:

- every pointer acquisition uses `defer` to free in the same frame
- lock errors are surfaced as `GitDataPlaneError.locked`
- ASan and TSan CI lanes run once libgit2 call sites exist

Do not add wall-clock sleeps. Wait for exact filesystem/process state when necessary.

## Acceptance Criteria

- `mise run check` passes.
- GitHub Actions run build, lint, test, ASan, and TSan where supported.
- No Homebrew/system libgit2 dependency is required for package consumers.
- libgit2 is pinned and reproducibly built.
- Public payloads are `Codable`, `Sendable`, and tested.
- Mutating operations are actor-serialized by canonical repository identity.
- Read operations do not write the index or create hidden lock contention.
- AgentStudio adapters can consume the package without importing Bridge contracts into `agentstudio-git`.
