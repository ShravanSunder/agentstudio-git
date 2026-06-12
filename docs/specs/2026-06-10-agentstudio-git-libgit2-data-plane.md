# AgentStudioGit SDK Spec

## Goal

`agentstudio-git` is a standalone SwiftPM package that AgentStudio imports as its Git SDK boundary.

The SDK owns two seams:

1. Local Git engine: libgit2-backed worktree, status, branch/ref, diff, tree, blob, and content operations.
2. Remote/auth engine: system-Git-backed network operations that intentionally reuse the user's Git client configuration and credential path.

The package exists because AgentStudio needs dependable worktree, status, branch, diff, content, and remote/auth facts for repo enrichment, Bridge review surfaces, and fast worktree operations. It is not a Bridge model package, not an app state package, and not a forge API package.

## Non-Goals

- No system-`git` implementation path for production local status, diff, content, tree, branch, or worktree reads.
- No `gh` dependency or forge API ownership.
- No custom credential vault, token store, or replacement for the user's Git credential helpers.
- No Bridge DTOs, review packages, atoms, stores, pane controllers, persistence, or UI.
- No patch application or source mutation from Bridge review surfaces.
- No command/response envelope inside this package. AgentStudio already has transport/correlation layers where needed.

## Vocabulary

Use "Git compatibility tests" for tests that compare package output against the behavior of a real Git repository. Avoid jargon that makes Git commands sound like a product architecture.

Git commands may appear in tests as a reference for expected Git behavior over controlled fixtures. They are not the product implementation for local SDK reads.

## Source Research

- libgit2 threading docs: most objects cannot be safely accessed by multiple threads at the same time; use an object from a single thread at a time; `git_error_last()` must be read on the same thread as the failure.
  https://github.com/libgit2/libgit2/blob/main/docs/threading.md
- libgit2 worktree API: list, lookup, open, add, lock, unlock, locked-state, name, path, prune.
  https://github.com/libgit2/libgit2/blob/main/include/git2/worktree.h
- libgit2 index write docs: `git_index_write` writes the index with an atomic file lock.
  https://libgit2.org/docs/reference/main/index/git_index_write.html
- Git worktree docs: linked worktrees have metadata, can be locked, and list output includes locked/prunable state.
  https://git-scm.com/docs/git-worktree
- Git credential helpers and environment docs: system Git is the compatibility boundary for clone/fetch/push auth.
  https://git-scm.com/docs/gitcredentials
  https://git-scm.com/docs/git
- libgit2 build docs and README: CMake build, static/shared options, `USE_SSH`, `USE_HTTPS`, local dependency choices.
  https://libgit2.org/docs/guides/build-and-link/
  https://github.com/libgit2/libgit2/blob/main/README.md

## Packaging Decision

Use an AgentStudio-owned Swift API package that links a pinned static libgit2 build for local operations and delegates authenticated network operations to system Git.

Implementation stages:

1. Build and validate libgit2 through a repo-owned script that produces an importable local static XCFramework with headers and module map.
2. Consume that XCFramework from SwiftPM through an internal binary target during local development.
3. Keep the build recipe and pinned libgit2 source reference in the repo so the binary is reproducible and maintainable.
4. Before AgentStudio release consumption, prove the downstream SwiftPM strategy: URL binary target with checksum, or another explicitly accepted consumable artifact strategy.

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

This avoids a Homebrew/system libgit2 runtime dependency for local SDK operations. Network transport and authentication compatibility are handled by system Git in the remote/auth seam.

## Authentication

Local operations do not use Git or GitHub authentication. libgit2 reads local `.git` data directly.

Remote operations such as clone, fetch, push, and remote reference discovery use the user's existing system `git` binary through a trusted process policy. That preserves credential helpers, SSH agent behavior, certificates, Git config, and enterprise setup that libgit2 credential callbacks would not automatically inherit.

System Git executable selection, inherited environment policy, prompt policy, protocol allowlist, and timeout are trusted client configuration. They are not public per-request fields.

Default remote operations are noninteractive and set prompt policy explicitly. Noninteractive mode disables Git/SSH askpass helpers and normalizes SSH batch mode by removing inherited `BatchMode` options and appending `-oBatchMode=yes`. Interactive prompting is trusted opt-in for a caller that owns UI or TTY behavior.

Public values and errors must not expose credential-bearing URLs, raw argv, raw stderr, tokens, private key paths, or sensitive environment values. Public remote snapshots redact HTTP(S) credential userinfo and token-like query values before values are encoded or returned to AgentStudio, while preserving legitimate SSH usernames and local path remotes such as `ssh://git@example.com/org/repo.git` and paths under `.ssh/`. System Git processes fail with a typed timeout error when they exceed the configured operation timeout, and timeout cleanup targets the spawned process group so SSH/helper descendants are not left running.

## Locking And Concurrency

A Swift repository actor does not create Git lock files. It serializes our process's mutation work so libgit2 objects and shared repository state are not touched unsafely.

Git lock files are created by Git/libgit2 write operations. Examples:

- `git_index_write` creates an atomic index lock.
- ref writes/deletes/renames create loose ref locks and may rewrite `packed-refs`.
- config writes lock the config file.
- `git_worktree_lock` writes a worktree administrative `locked` file with an optional reason.

Other processes can still hold locks. AgentStudioGit must surface lock failures as typed errors and must not auto-delete lock files.

Concurrency model:

- `GitRepositoryWriterActor`, keyed by canonical common git directory, serializes mutating operations:
  - create worktree
  - prune stale worktree metadata
  - remove linked worktree
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

The old local-only API shape is superseded by `AgentStudioGitLocalClient` and `AgentStudioGitRemoteClient`.

```swift
public protocol AgentStudioGitLocalClient: Sendable {
    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity
    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot]
    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeValidation
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreePruneResult
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeRemovalResult
    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot
    func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError) -> GitStatusSnapshot
    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot]
    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision
    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot
    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot
    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload
}

public protocol AgentStudioGitRemoteClient: Sendable {
    func clone(_ request: GitCloneRequest) async throws(GitDataPlaneError) -> GitCloneResult
    func fetch(_ request: GitFetchRequest) async throws(GitDataPlaneError) -> GitFetchResult
    func push(_ request: GitPushRequest) async throws(GitDataPlaneError) -> GitPushResult
    func remoteReferences(_ request: GitRemoteReferencesRequest) async throws(GitDataPlaneError) -> [GitRemoteReference]
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

Status snapshots include a tri-state origin value:

```swift
public enum GitOriginResolution: Codable, Equatable, Hashable, Sendable {
    case awaitingResolution
    case confirmedAbsent
    case resolved(GitRemoteSnapshot)
}
```

Line counts, binary flags, hunks, mode changes, and content hashes belong to diff/content payloads, not status entries.

## Identity And Path Rules

- Public input paths are `URL`, not raw `String`.
- The package canonicalizes filesystem paths before building IDs.
- Worktree IDs are stable value IDs derived from canonical common git directory plus canonical worktree path.
- The main worktree gets an explicit synthetic display name only in package output; callers must not use display names as identity.
- The package must preserve both display path and canonical identity path when they differ.
- Linked worktree `.git` files must resolve to the actual private git directory and index path before read-only proof is evaluated.

## Worktree Safety

Stale worktree metadata prune is separate from user-visible linked worktree removal.

Removal must:

- target a validated `GitWorktreeID` or canonical path
- refuse the main worktree
- refuse dirty tracked changes, staged changes, untracked files, locked worktrees, and ambiguous paths by default
- require explicit `forceDiscardChanges` before destructive removal
- return typed partial-failure outcomes when metadata and working-directory deletion diverge
- never auto-delete lock files created by other processes

## AgentStudio Boundaries

AgentStudio integration has two consumers:

1. App-wide Git enrichment:
   - adapter replaces shell parsing behind `GitWorkingTreeStatusProvider`
   - package returns branch/head/status/origin facts
2. Bridge review foundation:
   - adapter maps Git-shaped package values into Bridge-owned review contracts
   - Bridge keeps `BridgeReviewSourceProvider`, `BridgeReviewPackage`, `BridgeContentHandle`, filters, annotations, checkpoint composition, and URL scheme details

Worktrunk remains the user-facing worktree UX layer until a separate AgentStudio product decision moves create/remove/switch behavior to AgentStudioGit-backed commands.

## Testing Pyramid

Unit tests:

- public payload round trips
- enum raw-value snapshots
- invalid/unknown discriminator decoding
- typed error mapping
- redaction of credential-bearing URLs, argv, stderr, private key paths, public origin snapshots, and sensitive environment values
- path canonicalization
- two-axis status states such as staged+modified

Integration tests:

- create temporary real Git repositories
- create controlled fixture states with scrubbed test config
- verify package output matches expected Git behavior for those fixture states
- include clean, modified, staged, staged+modified, renamed, deleted, untracked, ignored, binary, linked worktree, locked worktree, stale metadata, dirty removal refusal, forced removal, detached HEAD, unborn HEAD, origin present, origin absent, and origin lookup failure cases

C interop tests:

- every pointer acquisition uses `defer` to free in the same frame
- lock errors are surfaced as typed errors
- ASan and TSan lanes run with honest sanitizer scope; do not claim native libgit2 instrumentation unless the artifact is built with matching sanitizer flags

Remote/auth tests:

- fake system-Git tests cover clone, fetch, push, remote reference discovery, command construction, environment policy, prompt policy, timeout behavior, protocol restrictions, parser output, and redaction
- timeout tests cover both the top-level Git process and spawned descendants
- opt-in live smoke records whether HTTPS and SSH auth paths were exercised against the user's configured environment

Do not add wall-clock sleeps. Wait for exact filesystem/process state when necessary.

## Acceptance Criteria

- `mise run check` passes.
- GitHub Actions run build, lint, test, ASan, and TSan where supported.
- No Homebrew/system libgit2 dependency is required for package consumers.
- libgit2 is pinned and reproducibly built.
- Public payloads are `Codable`, `Sendable`, and tested.
- Mutating local operations are actor-serialized by canonical repository identity.
- Read operations do not write the actual main or linked worktree index.
- Worktree removal safety is proven for main, linked, dirty, staged, untracked, locked, stale, forced, and partial-failure cases.
- Remote/auth operations reuse the user's system Git credential path and redact all public failure values.
- A clean downstream SwiftPM package can consume the local development path, and release HTTPS/checksum manifest mode is evaluated. Actual distributable artifact download proof requires a hosted `CLibGit2Local.xcframework.zip`.
- AgentStudio adapters can consume the package without importing Bridge contracts into `agentstudio-git`.
