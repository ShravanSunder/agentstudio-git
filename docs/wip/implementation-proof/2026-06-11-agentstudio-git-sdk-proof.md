# AgentStudio Git SDK Implementation Proof

Date: 2026-06-11

Goal:

- `docs/wip/goals/2026-06-11-agentstudio-git-sdk-goal.md`

Plan:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`

## Current Scope

Tasks 0-9: spec/tooling, public contracts, repository identity/runtime lanes, libgit2 artifact packaging, libgit2 runtime/session wrappers, safe worktree operations, app enrichment status/branch/origin facts, Bridge review data operations, system Git remote/auth operations, and CI/release consumer readiness.

## Coverage

- Plan line count: 952; read in chunks 1-240, 241-480, 481-720, 721-952.
- Spec line count: 262; read 1-262.
- Goal contract line count: 156; read 1-156.
- Plan review line count: 125; read 1-125.
- AgentStudio consumption guide line count: 92; read 1-92.
- Existing package scaffold read before edits.

## Red Evidence

### Filtered SwiftPM Tests Can False-Green

Command:

```bash
swift test --filter DefinitelyNoSuchTest
```

Exit code: 0

Observed output:

```text
warning: No matching test cases were run
Executed 0 tests, with 0 failures
Test run with 0 tests in 0 suites passed
```

Expected correction:

- `scripts/run-swift-test-filter.sh DefinitelyNoSuchTest` must exit non-zero.

### Source Spec Still Has Old API Shape

Command:

```bash
rg -n "AgentStudioGitClient|clone, fetch, push.*out of scope|SSH auth.*out of scope|HTTPS auth.*out of scope" docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md
```

Exit code: 0

Observed output:

```text
108:public protocol AgentStudioGitClient: Sendable {
```

Expected correction:

- the same stale-spec grep must return no matches.

## Task Evidence

### Helper False Positive Adjustment

First helper implementation used `Executed 0 tests` as a zero-test signal from the plan snippet. Fresh positive proof showed that Swift Testing can emit an XCTest compatibility wrapper with `Executed 0 tests` while the real Swift Testing suite runs 2 tests.

Adjustment:

- fail on `No matching test cases were run`
- fail on `Test run with 0 tests in 0 suites`
- do not fail on the XCTest wrapper's `Executed 0 tests` line alone

## Task 0: Reconcile Spec, Tooling, And Proof Helpers

Status: implemented and verified.

Files changed:

- `CLAUDE.md`
- `.mise.toml`
- `.github/workflows/check.yml`
- `scripts/run-swift-test-filter.sh`
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Proof:

```bash
scripts/run-swift-test-filter.sh DefinitelyNoSuchTest
```

Exit code: 1

Result:

- failed on zero-test filter
- output included `filtered Swift test gate executed zero tests: DefinitelyNoSuchTest`

```bash
scripts/run-swift-test-filter.sh AgentStudioGitTests
```

Exit code: 0

Result:

- passed with `Test run with 2 tests in 1 suite`

```bash
rg -n "AgentStudioGitClient|clone, fetch, push.*out of scope|SSH auth.*out of scope|HTTPS auth.*out of scope" docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md
```

Exit code: 1

Result:

- no stale old-API/auth-scope claims found

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`

```bash
mise run check
```

Exit code: 0

Result:

- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations
- `swift test` passed with 2 tests in 1 suite

```bash
git diff --check
```

Exit code: 0

Result:

- no whitespace errors

## Task 5: Fast Worktree Operations

Status: implemented and verified.

Files changed:

- `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- `Sources/AgentStudioGitLocal/Runtime/GitRepositoryWriterRegistry.swift`
- `Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeReader.swift`
- `Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift`
- `Tests/AgentStudioGitTests/Contracts/GitWireEnumSnapshotTests.swift`
- `Tests/AgentStudioGitTests/Fixtures/GitFixtureRepository.swift`
- `Tests/AgentStudioGitTests/Fixtures/GitProcess.swift`
- `Tests/AgentStudioGitTests/Integration/GitWorktreeIntegrationTests.swift`
- `Tests/AgentStudioGitTests/Runtime/GitRepositoryWriterRegistryTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Research basis:

- DeepWiki was asked for libgit2 worktree API semantics before implementation.
- Vendored `vendor/libgit2/include/git2/worktree.h` verified exact `git_worktree_list`, `lookup`, `open_from_repository`, `validate`, `add`, `lock`, `unlock`, `is_locked`, `is_prunable`, and `prune` contracts.
- Vendored `vendor/libgit2/include/git2/status.h` verified staged, worktree, and untracked status flags for removal safety checks.

Red evidence:

```bash
scripts/run-swift-test-filter.sh GitWorktreeIntegrationTests
```

Exit code: 1

Result before implementation:

- compile failed because `LibGit2AgentStudioGitLocalClient` did not exist

Review red evidence:

```bash
scripts/run-swift-test-filter.sh GitWorktreeIntegrationTests
```

Exit code: 1

Result before review fixes:

- compile failed because `GitWorktreePruneRefusalReason` and `GitDataPlaneError.worktreeNotPrunable` did not exist
- compile failed because `GitRepositoryWriterRegistry.shared` did not exist

Implementation notes:

- `GitProcess` and `GitFixtureRepository` are test-only fixture helpers with scrubbed Git config, disabled signing, locale pinning, captured stdout/stderr, and real temp repositories.
- `LibGit2AgentStudioGitLocalClient` is the public SDK surface; low-level worktree reader/writer mutators are internal implementation details.
- `GitRepositoryWriterRegistry.shared` is the default process-wide writer registry, keyed by canonical repository identity.
- `LibGit2WorktreeReader` resolves linked-path inputs back to the real main worktree before listing; linked worktree names are display names, not stable IDs.
- `LibGit2WorktreeWriter` creates worktrees from existing branches, new branches from revisions, and detached revisions through libgit2.
- New-branch create uses best-effort rollback for created branch/worktree metadata if later add/detach/validation fails.
- Stale prune uses `git_worktree_is_prunable` and metadata-only `git_worktree_prune`, returning typed `worktreeNotPrunable` for live worktrees and `locked` for locked stale metadata.
- Remove validates ID/path, refuses main/locked/dirty/staged/untracked worktrees without force, and returns partial failure when working-directory deletion is denied after metadata removal.
- macOS `/private/var` and `/var` path spellings are normalized for stale worktree metadata matching.
- Malformed `.git` files and non-not-found libgit2 open failures are preserved as typed failures instead of being collapsed into `repositoryNotFound`.

Review corrections:

- accepted P1 writer-lane bypass: default clients now use the shared writer registry and low-level mutators are no longer public.
- accepted P1 create non-transactionality: failed new-branch create rolls back branch metadata and any created worktree metadata best-effort.
- accepted P1 linked-path identity bug: listing from a linked worktree path returns exactly one real main snapshot and no duplicated linked snapshot.
- accepted P2 locked stale metadata bug: prune reports `.locked(message:)` with normalized lock reason.
- accepted P2 error taxonomy bug: malformed `.git` files are not reported as missing repositories.

Green proof:

```bash
scripts/run-swift-test-filter.sh GitWorktreeIntegrationTests
```

Exit code: 0

Result:

- `Test run with 12 tests in 1 suite passed`
- covered main listing, linked listing, linked worktree named `main`, linked-path listing canonicalization, existing branch create, new branch create, failed create rollback, detached create, checked-out branch refusal, validation, lock/unlock, stale prune, locked stale prune, malformed `.git` error mapping, main removal refusal, clean removal, dirty/staged/untracked refusal, force dirty removal, locked removal refusal, path mismatch refusal, and permission-denied partial failure

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 37 tests in 11 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 37 tests in 11 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 37 tests in 11 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 34 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 34 files
- `swift test` passed with 37 tests in 11 suites

## Task 6: App Enrichment Status, Branch, And Origin Facts

Status: implemented and verified.

Files changed:

- `Package.swift`
- `Sources/AgentStudioGitContracts/GitStatusContracts.swift`
- `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- `Sources/AgentStudioGitLocal/Status/GitIndexPathResolver.swift`
- `Sources/AgentStudioGitLocal/Status/LibGit2BranchReader.swift`
- `Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift`
- `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- `Tests/AgentStudioGitTests/Integration/GitStatusIntegrationTests.swift`
- `Tests/AgentStudioGitTests/ConsumerCompatibility/GitWorkingTreeStatusCompatibilityTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Research basis:

- DeepWiki was asked for libgit2 status, branch, upstream, ahead/behind, origin, shortstat, and linked-worktree index semantics before implementation.
- Vendored `Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers/git2/status.h` verified `git_status_list_new`, status flag families, rename options, `GIT_STATUS_OPT_NO_REFRESH`, and `GIT_STATUS_OPT_UPDATE_INDEX`.
- Vendored `Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers/git2/diff.h` verified `git_diff_tree_to_workdir_with_index`, `git_diff_get_stats`, and `git_diff_stats_free` for `git diff --shortstat HEAD --` semantics.
- Vendored `Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers/git2/branch.h`, `graph.h`, `remote.h`, and `index.h` verified branch iteration, upstream resolution, ahead/behind counts, origin lookup, and per-worktree index path APIs.
- Live AgentStudio seam read from `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingTreeStatusProvider.swift` and `.../Contracts/PaneRuntimeEvent.swift`.

Red evidence:

```bash
scripts/run-swift-test-filter.sh GitStatusIntegrationTests
```

Exit code: 1

Result before implementation:

- `Test run with 7 tests in 1 suite failed`
- each test failed with `unsupported(message: "status is implemented in Task 6")` or `unsupported(message: "branches are implemented in Task 6")`

```bash
scripts/run-swift-test-filter.sh GitWorkingTreeStatusCompatibilityTests
```

Exit code: 1

Result before implementation:

- `Test run with 3 tests in 1 suite failed`
- static SDK-to-AgentStudio mapping passed
- live local-client compatibility provider returned nil because `status` was still unsupported

Implementation notes:

- `LibGit2StatusReader` uses `git_status_list_new` with `GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX`, `GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR`, and `GIT_STATUS_OPT_NO_REFRESH`; it never sets `GIT_STATUS_OPT_UPDATE_INDEX`.
- Status entries map libgit2 index flags to `indexState`, worktree flags to `worktreeState`, and preserve untracked/ignored flags separately.
- Staged deletes use the `head_to_index` old-path fallback, covering the libgit2 case where `new_file.path` is nil for a delete.
- Shortstat uses `git_diff_tree_to_workdir_with_index` plus `git_diff_get_stats` so staged-plus-unstaged line counts match `git diff --shortstat HEAD --`.
- `GitIndexPathResolver` resolves the actual libgit2 index path through `git_repository_index`/`git_index_path`; tests prove main and linked worktree status reads preserve index bytes and leave `index.lock` sentinels untouched.
- `LibGit2BranchReader` lists local branches, resolves current branch, upstream name, ahead/behind counts, detached/unborn HEAD, origin present/absent, and unresolved origin states.
- `GitRemoteSnapshot.rawURL` preserves the exact configured remote string so the app adapter keeps local path remotes as paths instead of changing them to `file://` URLs.
- The compatibility test maps SDK snapshots into the live AgentStudio `GitWorkingTreeStatus` shape: app `changed` maps to SDK `unstagedFileCount`, app `staged` to SDK `stagedFileCount`, app `untracked` to SDK `untrackedFileCount`, app origin to `rawURL`, and missing upstream maps ahead/behind to nil rather than zero.
- The checked-out AgentStudio adapter harness extracts the live app seam declarations and runs `swiftc -typecheck` against the already-built SDK modules and binary-artifact import paths. The harness intentionally avoids nested SwiftPM because the test runner already holds the package build lock.
- A first wiring attempt stored status/branch readers on `LibGit2AgentStudioGitLocalClient` and caused a Swift runtime SIGBUS during client construction. The final client keeps the Task 5 stored shape and instantiates read-only status/branch readers at call sites; `GitWorktreeIntegrationTests` was rerun as the regression guard.

Green proof:

```bash
scripts/run-swift-test-filter.sh GitWorktreeIntegrationTests
```

Exit code: 0

Result:

- `Test run with 12 tests in 1 suite passed`
- regression guard for client construction and existing worktree behavior after Task 6 wiring

```bash
scripts/run-swift-test-filter.sh GitStatusIntegrationTests
```

Exit code: 0

Result:

- `Test run with 7 tests in 1 suite passed`
- covered clean, modified, staged, staged-and-modified, untracked, ignored, deleted, renamed, binary, ahead, behind, diverged, no upstream, origin present, origin absent, unresolved origin with summary, detached HEAD, unborn HEAD, main index path, linked worktree index path, no index byte mutation, and lock sentinel preservation

```bash
scripts/run-swift-test-filter.sh GitWorkingTreeStatusCompatibilityTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- covered SDK-to-AgentStudio mapping, local path origin fidelity, nil-vs-zero upstream semantics, detached branchless sync-unknown semantics, live local-client adapter path against a real repository, and a checked-out AgentStudio adapter typecheck when the sibling checkout is present

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 49 tests in 13 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 49 tests in 13 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 49 tests in 13 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 39 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 39 files
- `swift test` passed with 49 tests in 13 suites

## Task 7: Bridge Review Data Operations

Status: implemented and verified.

Files changed:

- `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- `Sources/AgentStudioGitContracts/GitDiffContentContracts.swift`
- `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- `Sources/AgentStudioGitLocal/Review/LibGit2RevisionResolver.swift`
- `Sources/AgentStudioGitLocal/Review/LibGit2TreeReader.swift`
- `Sources/AgentStudioGitLocal/Review/LibGit2DiffReader.swift`
- `Sources/AgentStudioGitLocal/Review/LibGit2ContentReader.swift`
- `Sources/AgentStudioGitLocal/Review/LibGit2ReviewSupport.swift`
- `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- `Tests/AgentStudioGitTests/Integration/GitReviewDataIntegrationTests.swift`
- `Tests/AgentStudioGitTests/ConsumerCompatibility/BridgeReviewSourceCompatibilityTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Research basis:

- DeepWiki was asked for libgit2 revision, tree, blob, content, and diff API semantics before implementation.
- Vendored `Artifacts/CLibGit2Local.xcframework/macos-arm64_x86_64/Headers/git2/blob.h`, `commit.h`, `object.h`, `tree.h`, `diff.h`, `patch.h`, `index.h`, and `oid.h` verified exact acquisition/free, lookup, diff, patch line-stat, index, and OID APIs.
- Live AgentStudio Bridge seam read from `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewSourceProvider.swift`, `BridgeGitReviewSourceProvider.swift`, the matching ReviewFoundation model files, `BridgeContentStore.swift`, and `BridgeReviewPackageBuilder.swift`.

Red evidence:

```bash
scripts/run-swift-test-filter.sh GitReviewDataIntegrationTests
```

Exit code: 1

Result before implementation:

- `Test run with 3 tests in 1 suite failed`
- revision/tree failed with `unsupported(message: "revision resolution is implemented in Task 7")`
- diff failed with `unsupported(message: "diff is implemented in Task 7")`
- content failed with `unsupported(message: "content is implemented in Task 7")`

Coverage tightening evidence:

```bash
scripts/run-swift-test-filter.sh GitReviewDataIntegrationTests
```

Exit code: 1

Result after adding CRLF/filter and large-file metadata assertions:

- compile failed because `try` was placed directly inside a `#expect` comparison
- fixed by binding the filtered Git hash before the assertion; no implementation change was needed

Review-fix red evidence:

```bash
scripts/run-swift-test-filter.sh GitPublicContractTests && scripts/run-swift-test-filter.sh GitReviewDataIntegrationTests && scripts/run-swift-test-filter.sh BridgeReviewSourceCompatibilityTests
```

Exit code: 1

Result before review fixes:

- compile failed because `GitDiffFile` did not carry `oldMode`/`newMode`
- compile failed because `GitDataPlaneError` did not carry `pathEscapesRepository(path:)`
- compile failed because the public content/diff initializers did not match the new path-escape and mode assertions
- Bridge runtime harness syntax/shape errors surfaced while turning the typecheck-only proof into an executable handle-only content-load proof

Implementation notes:

- `LibGit2RevisionResolver` uses revparse plus peel-to-commit to resolve `HEAD`, named refs, and commit OIDs into `GitResolvedRevision`.
- `LibGit2TreeReader` resolves commit trees and subtree paths, returning Git-shaped paths, OIDs, modes, tree/file flags, and blob sizes without importing Bridge types.
- `LibGit2DiffReader` covers commit/head to commit/head, commit/head to index, index to working tree, and commit/head to working tree-with-index.
- Diff options include untracked recursion, type changes, and binary data; rename detection runs through `git_diff_find_similar` with `GIT_DIFF_FIND_RENAMES`.
- Line counts come from `git_patch_from_diff` and `git_patch_line_stats`; negative patch creation results are typed libgit2 failures instead of silent zero counts.
- Diff file hashes are honest Git blob SHA-1 object IDs with `contentHashAlgorithm == "git-blob-sha1"`.
- When libgit2 returns an invalid workdir-side diff ID, the reader computes the filtered working-tree blob hash with `git_repository_hashfile`, matching `git hash-object --path` without adding a blob object to the repository object database.
- Diff file metadata now carries `oldMode` and `newMode` so executable-bit and type-change review surfaces do not have to infer modes from content.
- `LibGit2ContentReader` supports commit/head, index, and working-tree targets and enforces `maxSizeBytes` with typed `contentTooLarge` errors.
- Working-tree content reads reject absolute paths, `..` components, and symlink escapes with typed `pathEscapesRepository(path:)` errors before opening bytes.
- `GitContentPayload` uses `sha256:<hex>` and `contentHashAlgorithm == "sha256"` because AgentStudio `BridgeContentStore` validates loaded bytes by SHA-256, while diff file old/new hashes remain Git blob IDs.
- The shared review support helper opens repositories and pairs libgit2 object acquisitions with same-frame frees through `defer`.
- `resolveCheckpointEndpoint` remains AgentStudio-owned composition. The package exposes git-backed payload values only; checkpoint metadata-to-git-endpoint resolution is intentionally outside this SDK.
- The checked Bridge compatibility harness extracts the live app seam declarations and typechecks an `AgentStudioGitBridgeReviewAdapter` against built SDK modules. The harness covers `compareEndpoints`, `readTree`, `readReviewItemDescriptor`, `loadContent`, and a checkpoint resolver that throws because checkpoint composition remains app-owned.
- The Bridge compatibility harness also compiles and runs a scratch executable using the live `BridgeContentStore`; `loadContent` parses only `BridgeContentLoadRequest.handle.resourceUrl`, proving content loading can be driven from the handle request rather than local path variables and preserving `.gitRef` provider identity.
- The Bridge harness redirects child process output to temp files before `waitUntilExit()` and passes `-sanitize=address`/`-sanitize=thread` to scratch executable links when the built SDK object files are sanitizer-instrumented. This fixed the sanitizer proof deadlock/link failure without weakening the runtime content-load proof.
- `mise run check` still shows the vendored libgit2 artifact has HTTPS and SSH transports disabled. Remote/auth correctness remains Task 8's system-git responsibility and must be proven with system git HTTPS/SSH behavior, not libgit2 transport assumptions.

Accepted review corrections:

- blocked repository path and symlink escapes for working-tree content reads
- removed read-side object-database writes from filtered working-tree hash calculation
- upgraded Bridge compatibility from typecheck-only to runtime `BridgeContentStore` handle-load proof
- added public mode metadata and wire-shape coverage
- preserved libgit2 patch creation failures instead of converting them to zero line counts

Green proof:

```bash
scripts/run-swift-test-filter.sh GitPublicContractTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- covered public review-content request targets, optional `maxSizeBytes` wire shape, `GitDiffFile` mode fields, and `contentTooLarge` error facts

```bash
scripts/run-swift-test-filter.sh GitReviewDataIntegrationTests
```

Exit code: 0

Result:

- `Test run with 4 tests in 1 suite passed`
- covered revision resolution, tree reads, commit/index/worktree diffs, rename descriptors, delete descriptors, binary descriptors, old/new Git blob hashes, CRLF filtered workdir hashes compared against `git hash-object --path`, object-database loose-object non-mutation during workdir hash reads, executable mode changes, large-file size metadata, text content, binary content, index content, worktree content, size-limit errors, `..` path escapes, and symlink escapes

```bash
scripts/run-swift-test-filter.sh BridgeReviewSourceCompatibilityTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`
- typechecked the SDK-backed adapter against the checked-out AgentStudio Bridge ReviewFoundation seam
- compiled and ran a scratch executable that uses the live `BridgeContentStore`, builds a `.gitRef` content handle, discards local path variables, loads from `BridgeContentLoadRequest.handle.resourceUrl`, and verifies recorded SDK content requests preserve `commit("abc123")`

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 57 tests in 15 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 57 tests in 15 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 57 tests in 15 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 46 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 46 files
- `swift test` passed with 57 tests in 15 suites

## Task 8: Remote/Auth Seam Using System Git

Status: implemented and verified.

Files changed:

- `Sources/AgentStudioGitContracts/GitRemoteContracts.swift`
- `Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift`
- `Sources/AgentStudioGitRemote/GitExecutableLocator.swift`
- `Sources/AgentStudioGitRemote/GitProcessRunner.swift`
- `Sources/AgentStudioGitRemote/GitRemoteOutputParser.swift`
- `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- `Tests/AgentStudioGitTests/Remote/SystemGitRemoteClientTests.swift`
- `Tests/AgentStudioGitTests/Remote/GitProcessRunnerTests.swift`
- `Tests/AgentStudioGitTests/Remote/GitRemoteOutputParserTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Research basis:

- Official Git docs checked for `git clone`, `git fetch`, `git push`, `git ls-remote --symref`, credential-helper behavior, and protocol allow config.
- Local system Git help checked on this machine: `git version 2.50.1 (Apple Git-155)`.

Red evidence:

```bash
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests && scripts/run-swift-test-filter.sh GitProcessRunnerTests && scripts/run-swift-test-filter.sh GitRemoteOutputParserTests
```

Exit code: 1

Result before implementation:

- compile failed because `SystemGitRemoteClient`, `GitProcessRunner`, `GitRemoteOutputParser`, and `GitRemoteProtocol` did not exist
- compile failed because `GitCloneRequest.remoteURL` and `GitRemoteReferencesRequest.remoteURL` were `URL`, which cannot represent normal scp-style SSH remotes such as `git@github.com:org/repo.git`
- compile failed because `GitRemoteReference` did not carry `symrefTarget`

Additional red evidence after review:

```bash
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

Exit code: 1

Result before the validation fix:

- `option-shaped remote strings are rejected before process launch` failed because `-oProxyCommand=bad:repo.git` was classified as scp-style SSH and launched fake git
- fake-git invocation log was not empty, proving the process boundary was crossed before rejection

Implementation notes:

- Remote request locations are Git remote strings, not `URL`, so HTTPS URLs, `ssh://` URLs, and normal scp-style SSH remotes are representable.
- `SystemGitRemoteClient.Configuration` owns executable selection, inherited environment behavior, prompt policy, protocol allowlist, and trusted additional environment. Public request values cannot choose executables or environment policy.
- Default configuration inherits the user's environment, strips `GIT_TRACE*` and `GIT_CURL_VERBOSE`, sets `LC_ALL=C`, sets `GIT_TERMINAL_PROMPT=0`, and allows HTTPS plus SSH protocols.
- Trusted interactive mode is explicit and sets `GIT_TERMINAL_PROMPT=1`.
- `GitExecutableLocator` invokes either a trusted configured executable URL or `/usr/bin/env git`, preserving the normal user `PATH` for production.
- `GitProcessRunner` uses `Process` argument arrays only, captures stdout/stderr through temp files to avoid pipe deadlocks, and constructs public failures through `GitRemoteProcessFailure.redacting`.
- Every system Git invocation prefixes protocol config with `-c protocol.allow=never` plus configured `protocol.<name>.allow=always` entries.
- Clone, fetch, push, and ls-remote commands delimit untrusted remote/ref/path operands with `--` where Git supports separators. Fetch and push use `--porcelain`.
- Remote strings beginning with `-` are rejected before process launch so option-shaped scp-like inputs cannot reach `git ls-remote`.
- `GitRemoteOutputParser` parses `ls-remote --symref` output, preserving normal refs, symrefs, peeled tags, and malformed-output failures.
- The opt-in live smoke ran against the repository's HTTPS `origin` remote. SSH live smoke was not exercised because no SSH smoke URL was configured in this checkout; SSH syntax and protocol allow behavior are covered by fake-git tests.

Green proof:

```bash
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- covered clone, fetch, push, ls-remote argument construction; protocol config; scp-style SSH remote strings; fake remote reference parsing; protocol allowlist refusal before process launch; option-shaped remote refusal before process launch; and default skipped live smoke path

```bash
scripts/run-swift-test-filter.sh GitProcessRunnerTests
```

Exit code: 0

Result:

- `Test run with 3 tests in 1 suite passed`
- covered scrubbed test environment, prompt suppression, trusted interactive prompt opt-in, stdout capture, and process-failure redaction

```bash
scripts/run-swift-test-filter.sh GitRemoteOutputParserTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`
- covered normal refs, symrefs, peeled tags, and malformed lines

```bash
AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE=1 AGENTSTUDIO_GIT_LIVE_REMOTE_URL="$(git remote get-url origin)" scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- live HTTPS `ls-remote --symref` succeeded against `https://github.com/ShravanSunder/agentstudio-git.git` through `SystemGitRemoteClient`

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 67 tests in 18 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 67 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 67 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 53 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 53 files
- `swift test` passed with 67 tests in 18 suites

## Task 9: CI, Release Artifact, And Consumer Readiness

Status: implemented and verified.

Files changed:

- `Package.swift`
- `.github/workflows/check.yml`
- `.mise.toml`
- `scripts/verify-package-consumer.sh`
- `Tests/AgentStudioGitTests/Packaging/LibGit2PackagingScriptTests.swift`
- `docs/guides/agentstudio-consumption.md`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Research and observed platform basis:

- Apple WWDC binary Swift package guidance says distributable binary targets use a URL plus checksum; path-based XCFramework references are for development and large XCFrameworks should not be committed to Git history.
- SwiftPM rejected a local `file://` binary-target URL with `invalid URL scheme for binary target 'CLibGit2Local'; valid schemes are: 'https'`.
- Therefore local downloader simulation cannot use `file://`; the package keeps local path mode for development and adds explicit HTTPS/checksum release-manifest mode.

Red evidence:

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 1

Result before implementation:

- `package supports local and distributable libgit2 binary targets` failed because `Package.swift` only exposed the local path binary target and had no release URL/checksum mode.
- `consumer verification imports AgentStudioGitLocal without running repo mise tasks` failed because the consumer verifier did not evaluate release-manifest shape.
- `check workflow runs sanitizer and consumer gates` failed because CI only ran `mise run check`.

Implementation notes:

- `Package.swift` now keeps local development mode through `Artifacts/CLibGit2Local.xcframework`.
- Setting `AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL` and `AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM` switches the manifest to `.binaryTarget(name: "CLibGit2Local", url: binaryURL, checksum: binaryChecksum)`.
- `.github/workflows/check.yml` now runs `mise run check`, `mise run test-asan`, `mise run test-tsan`, and `bash scripts/verify-package-consumer.sh`.
- `.mise.toml` exposes `mise run verify-package-consumer`.
- `scripts/verify-package-consumer.sh` still builds and runs a scratch downstream SwiftPM consumer importing `AgentStudioGitLocal`, and now also evaluates the release manifest with an HTTPS artifact URL plus the generated checksum.
- `docs/guides/agentstudio-consumption.md` documents product selection, artifact modes, remote/auth policy, AgentStudio-owned boundaries, and required consumption proof gates.

Artifact facts:

- Task 9 implementation base commit: `65a694cf87a6b52119703590070d2a314464f853`
- Pinned libgit2 commit: `f7164261c9bc0a7e0ebf767c584e5192810a8b24`
- Generated artifact checksum: `33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d`

Green proof so far:

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- covered local and distributable libgit2 binary target manifest shape, downstream consumer verifier shape, CI sanitizer/consumer gates, build-script settings, and third-party notice facts

```bash
bash scripts/verify-package-consumer.sh
```

Exit code: 0

Result:

- scratch downstream SwiftPM consumer built and ran
- runtime output was `1.9.4`
- release manifest evaluation included `https://artifact.invalid/CLibGit2Local.xcframework.zip`
- release manifest evaluation included checksum `33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d`

```bash
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://artifact.invalid/CLibGit2Local.xcframework.zip" AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="$(cat Artifacts/CLibGit2Local.xcframework.zip.checksum)" swift package dump-package | rg 'artifact.invalid|checksum|CLibGit2Local'
```

Exit code: 0

Result:

- output contained `url` `https://artifact.invalid/CLibGit2Local.xcframework.zip`
- output contained checksum `33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d`

Final validation:

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 68 tests in 18 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 68 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 68 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 53 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 53 files
- `swift test` passed with 68 tests in 18 suites

```bash
bash scripts/verify-package-consumer.sh
```

Exit code: 0

Result:

- scratch downstream SwiftPM consumer built and ran
- runtime output was `1.9.4`
- release manifest mode was evaluated with HTTPS URL plus checksum

## Task 4: libgit2 Runtime, Errors, And Sessions

Status: implemented and verified.

Files changed:

- `Sources/AgentStudioGitLocal/LibGit2/LibGit2Runtime.swift`
- `Sources/AgentStudioGitLocal/LibGit2/LibGit2ErrorCapture.swift`
- `Sources/AgentStudioGitLocal/LibGit2/LibGit2RepositorySession.swift`
- `Tests/AgentStudioGitTests/LibGit2/LibGit2RuntimeTests.swift`
- `Tests/AgentStudioGitTests/LibGit2/LibGit2ErrorCaptureTests.swift`
- `Tests/AgentStudioGitTests/LibGit2/LibGit2RepositorySessionTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Red evidence:

```bash
scripts/run-swift-test-filter.sh LibGit2RuntimeTests
```

Exit code: 1

Result before implementation:

- compile failed because `LibGit2Runtime`, `LibGit2ErrorCapture`, and `LibGit2RepositorySession` did not exist

Review corrections:

- removed public test-hook initializers so the process-scoped runtime cannot be replaced by package consumers
- serialized libgit2 lifecycle suites to avoid Swift Testing parallelism changing global libgit2 state
- made init failure mapping deterministic instead of reading stale `git_error_last()` details
- made missing required repository paths throw a typed failure instead of falling back to `/`
- added bare repository path coverage
- removed brittle assertions about libgit2 error class/message text
- kept raw repository handles private to the same synchronous frame and covered `git_repository_free` on a throw path

Green proof:

```bash
scripts/run-swift-test-filter.sh LibGit2RuntimeTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`
- covered injected runtime init-once behavior and deterministic typed init-failure mapping

```bash
scripts/run-swift-test-filter.sh LibGit2ErrorCaptureTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`
- covered injected same-frame error copying and nil-error fallback behavior

```bash
scripts/run-swift-test-filter.sh LibGit2RepositorySessionTests
```

Exit code: 0

Result:

- `Test run with 4 tests in 1 suite passed`
- covered working-tree path extraction, bare repository paths, typed open-failure mapping, and `git_repository_free` on required-path failure

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 24 tests in 10 suites passed`

```bash
swift test --sanitize address
```

Exit code: 0

Result:

- `Test run with 24 tests in 10 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
swift test --sanitize thread
```

Exit code: 0

Result:

- `Test run with 24 tests in 10 suites passed`
- sanitizer applies to Swift wrapper/test code; Task 3 did not build a sanitizer-specific libgit2 artifact

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 28 files
- `swift test` passed with 24 tests in 10 suites

```bash
git diff --check
```

Exit code: 0

Result:

- no whitespace errors

## Task 3: libgit2 Artifact Pipeline And Downstream Packaging

Status: implemented and verified.

Files changed:

- `Package.swift`
- `.mise.toml`
- `.gitignore`
- `.gitmodules`
- `.github/workflows/check.yml`
- `.github/workflows/libgit2-artifact.yml`
- `vendor/libgit2`
- `Sources/AgentStudioGitLocal/LibGit2ImportCanary.swift`
- `Tests/AgentStudioGitTests/Packaging/LibGit2PackagingScriptTests.swift`
- `Tests/AgentStudioGitTests/Runtime/GitRepositoryIdentityTests.swift`
- `ThirdPartyNotices/libgit2.md`
- `scripts/build-libgit2-xcframework.sh`
- `scripts/verify-libgit2-artifact.sh`
- `scripts/verify-package-consumer.sh`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Pinned source:

- libgit2 tag: `v1.9.4`
- libgit2 commit: `f7164261c9bc0a7e0ebf767c584e5192810a8b24`
- license recorded: `GPL-2.0-only WITH GCC-exception-2.0`

Red evidence:

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 1

Result before implementation:

- failed because `scripts/build-libgit2-xcframework.sh`, `Sources/AgentStudioGitLocal/LibGit2ImportCanary.swift`, `scripts/verify-package-consumer.sh`, and `ThirdPartyNotices/libgit2.md` were missing

```bash
bash scripts/build-libgit2-xcframework.sh
```

Exit code: 1

Result during implementation:

- ambient `CMAKE_TOOLCHAIN_FILE` from vcpkg polluted CMake configuration; fixed by scrubbing ambient CMake/vcpkg launcher environment in the script
- building target `libgit2` compiled objects but did not create `libgit2.a`; fixed by building upstream target `libgit2package`
- `xcodebuild -create-xcframework` rejected an archive containing fat object members; fixed by building thin `arm64` and `x86_64` archives, then `lipo -create` into the universal archive

```bash
swift test
```

Exit code: 1

Result during implementation:

- temp Git identity fixtures inherited global commit signing and failed through the 1Password signing agent
- full-suite parallel execution also exposed a Git subprocess deadlock when `git init` wrote default-branch advice to an undrained stdout pipe
- fixed by isolating fixture Git config, disabling signing for fixture commits, setting `init.defaultBranch=main`, and routing fixture stdout/stdin to `/dev/null`

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 1

Result during implementation:

- failed after adding a test expectation that `verify-package-consumer.sh` must run the consumer executable, not only build it
- fixed by adding `swift run --package-path "$SCRATCH_DIR" consumer`

Green proof:

```bash
bash scripts/build-libgit2-xcframework.sh
```

Exit code: 0

Result:

- built `Artifacts/CLibGit2Local.xcframework`
- CMake feature summary showed `HTTPS`, `SSH`, and `GSSAPI` disabled

```bash
bash scripts/verify-libgit2-artifact.sh
```

Exit code: 0

Result:

- verified `Artifacts/CLibGit2Local.xcframework`
- `lipo -info` reported `x86_64 arm64`

```bash
scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 0

Result:

- `Test run with 4 tests in 1 suite passed`
- covered build flags, thin-arch/lipo packaging, binary target/import canary, consumer script, and third-party notice

```bash
scripts/run-swift-test-filter.sh GitRepositoryIdentityTests
```

Exit code: 0

Result:

- `Test run with 3 tests in 1 suite passed`
- proved the fixture isolation fix did not break real temp repo/worktree identity coverage

```bash
swift build
```

Exit code: 0

Result:

- package built against the generated `CLibGit2Local` binary target

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 16 tests in 7 suites passed`

```bash
bash scripts/verify-package-consumer.sh
```

Exit code: 0

Result:

- scratch SwiftPM package outside this repo imported `AgentStudioGitLocal`
- executable ran `LibGit2ImportCanary.version()`
- output included `1.9.4`

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 22 files
- `swift test` passed with 16 tests in 7 suites

```bash
git diff --check
```

Exit code: 0

Result:

- no whitespace errors

Notes:

- `build-libgit2` owns scoped cleanup of `.build/libgit2/{arm64,x86_64,macos-universal}`, `.build/libgit2/CLibGit2LocalHeaders`, and `Artifacts/CLibGit2Local.xcframework`.
- The local binary target path is intentionally a Task 3 development shape. Task 9 must still decide the distributable URL/checksum strategy before AgentStudio consumes the package as a dependency.

## Task 2: Repository Identity And Writer Registry

Status: implemented and verified.

Files changed:

- `Sources/AgentStudioGitLocal/Runtime/GitPathCanonicalizer.swift`
- `Sources/AgentStudioGitLocal/Runtime/GitRepositoryIdentityResolver.swift`
- `Sources/AgentStudioGitLocal/Runtime/GitRepositoryWriterRegistry.swift`
- `Tests/AgentStudioGitTests/Runtime/GitRepositoryIdentityTests.swift`
- `Tests/AgentStudioGitTests/Runtime/GitRepositoryWriterRegistryTests.swift`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Red evidence:

```bash
scripts/run-swift-test-filter.sh GitRepositoryIdentityTests
```

Exit code: 1

Result before implementation:

- compile failed because `GitRepositoryIdentityResolver` and `GitRepositoryWriterRegistry` did not exist

Green proof:

```bash
scripts/run-swift-test-filter.sh GitRepositoryIdentityTests
```

Exit code: 0

Result:

- `Test run with 3 tests in 1 suite passed`
- covered absolute/symlink identity equivalence
- covered main and linked worktrees sharing the common git directory
- covered a linked worktree whose display name collides with the synthetic main display name

```bash
scripts/run-swift-test-filter.sh GitRepositoryWriterRegistryTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`
- covered lane reuse for the same repository identity
- covered separate lanes for different repository identities

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 12 tests in 6 suites passed`

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run check
```

Exit code: 0

Result:

- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations
- `swift test` passed with 12 tests in 6 suites

## Task 1: Public Contract Cutover

Status: implemented and verified.

Files changed:

- `Package.swift`
- `Sources/AgentStudioGit/AgentStudioGit.swift`
- `Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift`
- `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- `Sources/AgentStudioGitContracts/GitRepositoryIdentity.swift`
- `Sources/AgentStudioGitContracts/GitWorktreeContracts.swift`
- `Sources/AgentStudioGitContracts/GitStatusContracts.swift`
- `Sources/AgentStudioGitContracts/GitDiffContentContracts.swift`
- `Sources/AgentStudioGitContracts/GitRemoteContracts.swift`
- `Sources/AgentStudioGitContracts/GitRedaction.swift`
- `Sources/AgentStudioGitLocal/AgentStudioGitLocal.swift`
- `Sources/AgentStudioGitRemote/AgentStudioGitRemote.swift`
- `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- `Tests/AgentStudioGitTests/Contracts/GitWireEnumSnapshotTests.swift`
- `Tests/AgentStudioGitTests/Contracts/GitInvalidDecodeTests.swift`
- `Tests/AgentStudioGitTests/Contracts/GitRedactionTests.swift`

Red evidence:

```bash
scripts/run-swift-test-filter.sh GitPublicContractTests
```

Exit code: 1

Result before implementation:

- compile failed because `GitRemoteProcessFailure`, `GitStatusState`, `GitDiffFile`, `GitHeadSnapshot`, `GitRemoteSnapshot`, `GitStatusSummary`, `GitStatusEntry`, and `GitCloneRequest` did not exist
- existing `GitStatusSnapshot` initializer still used the old local-only shape

Green proof:

```bash
scripts/run-swift-test-filter.sh GitPublicContractTests
```

Exit code: 0

Result:

- `Test run with 3 tests in 1 suite passed`

```bash
scripts/run-swift-test-filter.sh GitWireEnumSnapshotTests
```

Exit code: 0

Result:

- `Test run with 1 test in 1 suite passed`

```bash
scripts/run-swift-test-filter.sh GitInvalidDecodeTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`

```bash
scripts/run-swift-test-filter.sh GitRedactionTests
```

Exit code: 0

Result:

- `Test run with 1 test in 1 suite passed`

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 7 tests in 4 suites passed`

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run check
```

Exit code: 0

Result:

- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations
- `swift test` passed with 7 tests in 4 suites

```bash
git diff --check
```

Exit code: 0

Result:

- no whitespace errors

## Post-Review Hardening: Redaction, Timeout, And Consumer Proof

Date: 2026-06-12

Status: implemented and verified.

Review findings addressed:

- public origin/status snapshots leaked credential-bearing `origin` URLs
- process failure redaction did not cover SSH private-key paths
- remote subprocesses had no configured timeout
- noninteractive system-Git mode still allowed Git/SSH askpass helpers
- compatibility harnesses were pinned to one sibling checkout name and one build triple
- downstream consumer proof imported only `AgentStudioGitLocal`

Files changed:

- `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- `Sources/AgentStudioGitContracts/GitRedaction.swift`
- `Sources/AgentStudioGitLocal/Status/LibGit2BranchReader.swift`
- `Sources/AgentStudioGitRemote/GitProcessRunner.swift`
- `Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift`
- `Tests/AgentStudioGitTests/ConsumerCompatibility/AgentStudioCompatibilityHarnessSupport.swift`
- `Tests/AgentStudioGitTests/ConsumerCompatibility/BridgeReviewSourceCompatibilityTests.swift`
- `Tests/AgentStudioGitTests/ConsumerCompatibility/GitWorkingTreeStatusCompatibilityTests.swift`
- `Tests/AgentStudioGitTests/Contracts/GitRedactionTests.swift`
- `Tests/AgentStudioGitTests/Integration/GitStatusIntegrationTests.swift`
- `Tests/AgentStudioGitTests/Packaging/LibGit2PackagingScriptTests.swift`
- `Tests/AgentStudioGitTests/Remote/GitProcessRunnerTests.swift`
- `scripts/verify-package-consumer.sh`
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/guides/agentstudio-consumption.md`
- `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

Red evidence:

```bash
bash scripts/run-swift-test-filter.sh GitRedactionTests
```

Exit code: 1

Result before implementation:

- `redaction removes SSH private key paths from process output` failed with 5 issues
- output still contained `/Users/alice/.ssh`, `company_deploy_key`, `id_work`, and `id_rsa`

```bash
bash scripts/run-swift-test-filter.sh GitStatusIntegrationTests
```

Exit code: 1

Result before implementation:

- `origin snapshots redact credential-bearing remote URLs` failed with 4 issues
- `remote.rawURL`, `remote.url`, and encoded JSON still contained `https://user:secret-token@example.com/org/repo.git`

```bash
bash scripts/run-swift-test-filter.sh GitProcessRunnerTests
```

Exit code: 1

Result before implementation:

- compile failed because `GitDataPlaneError.processTimedOut` and `SystemGitRemoteClient.Configuration.operationTimeoutSeconds` did not exist

```bash
bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 1

Result before script expansion:

- `consumer verification imports public SDK products without running repo mise tasks` failed with 5 issues
- verifier did not import `AgentStudioGitContracts` or `AgentStudioGitRemote`
- verifier did not declare product dependencies on `AgentStudioGit`, `AgentStudioGitContracts`, or `AgentStudioGitRemote`

Implementation notes:

- `GitRedaction` now redacts credential-bearing URL userinfo, token-like query values, and `~/.ssh` or absolute `.ssh` private-key paths.
- `LibGit2BranchReader.originResolution` returns a credential-stripped Foundation `URL` and a redacted `rawURL`; encoded public status snapshots no longer carry credential-bearing origin strings.
- `GitDataPlaneError` now has `processTimedOut(GitRemoteProcessFailure)` so remote subprocess timeout is a typed public error.
- `SystemGitRemoteClient.Configuration` now owns `operationTimeoutSeconds` as trusted configuration.
- Noninteractive system-Git mode now strips `GIT_ASKPASS`, `SSH_ASKPASS`, and `SSH_ASKPASS_REQUIRE`, adds `core.askPass=`, sets `GIT_TERMINAL_PROMPT=0`, and ensures `GIT_SSH_COMMAND` includes `-oBatchMode=yes`.
- `GitProcessRunner` installs the process termination handler before launch, enforces the configured timeout, terminates then kills hung processes, and reports timeout failures through the same redacted process-failure value.
- The AgentStudio compatibility harness now discovers the checked-out app through `AGENTSTUDIO_GIT_AGENTSTUDIO_PATH` or known sibling names, uses `swift build --show-bin-path` instead of a hardcoded arm64 build path, and only fails missing app seams when `AGENTSTUDIO_GIT_REQUIRE_AGENTSTUDIO_COMPATIBILITY=1` or an explicit app path is configured.
- `scripts/verify-package-consumer.sh` now imports all public products: `AgentStudioGit`, `AgentStudioGitContracts`, `AgentStudioGitLocal`, and `AgentStudioGitRemote`.

Green proof:

```bash
bash scripts/run-swift-test-filter.sh GitRedactionTests
```

Exit code: 0

Result:

- `Test run with 2 tests in 1 suite passed`

```bash
bash scripts/run-swift-test-filter.sh GitStatusIntegrationTests
```

Exit code: 0

Result:

- `Test run with 8 tests in 1 suite passed`
- credentialed-origin status snapshot redaction case passed

```bash
bash scripts/run-swift-test-filter.sh GitProcessRunnerTests
```

Exit code: 0

Result:

- `Test run with 4 tests in 1 suite passed`
- hung fake-git process timed out in 0.224 seconds

```bash
bash scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`

```bash
bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`

```bash
bash scripts/run-swift-test-filter.sh CompatibilityTests
```

Exit code: 0

Result:

- `Test run with 7 tests in 2 suites passed`
- normal mode found the sibling AgentStudio checkout and proved both compatibility harnesses

```bash
AGENTSTUDIO_GIT_REQUIRE_AGENTSTUDIO_COMPATIBILITY=1 bash scripts/run-swift-test-filter.sh CompatibilityTests
```

Exit code: 0

Result:

- `Test run with 7 tests in 2 suites passed`
- required AgentStudio compatibility mode proved the checked-out AgentStudio status and Bridge seams were present and compatible

```bash
bash scripts/verify-package-consumer.sh
```

Exit code: 0

Result:

- scratch downstream SwiftPM consumer built and ran
- runtime output was `1.9.4 SystemGitRemoteClient true noninteractive https unsupported(message: "consumer smoke")`

Final validation:

```bash
swift test
```

Exit code: 0

Result:

- `Test run with 71 tests in 18 suites passed`

```bash
mise run format
```

Exit code: 0

Result:

- formatted Swift sources

```bash
mise run lint
```

Exit code: 0

Result:

- `swift-format lint` passed
- `swiftlint` found 0 violations in 54 files

```bash
mise run check
```

Exit code: 0

Result:

- `verify-libgit2` rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` passed
- `swift-format lint` passed
- `swiftlint` found 0 violations in 54 files
- `swift test` passed with 71 tests in 18 suites

```bash
AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE=1 AGENTSTUDIO_GIT_LIVE_REMOTE_URL="$(git remote get-url origin)" bash scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

Exit code: 0

Result:

- `Test run with 5 tests in 1 suite passed`
- live HTTPS `ls-remote --symref` succeeded against the configured origin through `SystemGitRemoteClient`

```bash
mise run test-asan
```

Exit code: 0

Result:

- `Test run with 71 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; native libgit2 was not rebuilt with sanitizer flags

```bash
mise run test-tsan
```

Exit code: 0

Result:

- `Test run with 71 tests in 18 suites passed`
- sanitizer applies to Swift wrapper/test code; native libgit2 was not rebuilt with sanitizer flags

Known external proof limits after this checkpoint:

- Authenticated HTTPS credential-helper and SSH-agent live smokes have not been exercised in this checkout because no private/authenticated smoke remotes were configured.
- The release manifest HTTPS/checksum mode is evaluated, but an actual remote artifact download still requires a real hosted `CLibGit2Local.xcframework.zip` URL.
