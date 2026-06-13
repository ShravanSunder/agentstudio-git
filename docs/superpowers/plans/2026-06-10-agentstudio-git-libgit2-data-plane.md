# AgentStudio Git SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `agentstudio-git` into the Git SDK boundary AgentStudio needs: fast local worktree/status/diff/content operations through libgit2, plus a deliberate remote/auth seam that reuses the user's Git client, credential helpers, SSH agent, certificates, and Git config where authenticated network work is needed.

**Architecture:** The package exposes method-oriented Swift protocols and immutable Git-shaped values. Local repository operations are libgit2-backed. Remote/auth operations are system-Git-backed because libgit2 credential callbacks do not automatically inherit all user Git credential-helper and SSH behavior. AgentStudio owns app enrichment, Bridge DTOs, checkpoint collation, atoms, stores, UI, and persistence.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftLint, swift-format, mise, libgit2 1.9.x, CMake, GitHub Actions, ASan/TSan wrapper lanes, system `git` for remote/auth and controlled fixture setup.

---

## Review Status

This plan supersedes the earlier local-only data-plane plan. It was rewritten after an adversarial plan review with Codex, Gemini, and Claude lanes. Do not execute the older local-only shape.

Accepted review fixes included here:

- public contracts and value models are now one dependency-safe cutover task
- source spec reconciliation is a first task, not a footnote
- local and distributable libgit2 packaging are separate explicit states
- XCFramework headers/modulemap/linking are required
- zero-test filtered SwiftPM commands are forbidden by a helper script
- actual AgentStudio adapter compile proof replaces mirror-only compatibility
- worktree remove is separated from stale metadata prune and protects dirty worktrees
- remote/auth errors and URLs must be redacted before becoming public values
- remote process policy is trusted client configuration, not untrusted request data
- prompt behavior is explicit: default noninteractive; interactive is trusted opt-in
- linked-worktree index paths are resolved before read-only proof
- sanitizer claims are narrowed unless an instrumented libgit2 artifact is used

## Source Coverage

- Current plan: this file.
- Source spec: `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md` lines 1-201.
- Current package scaffold:
  - `Package.swift`
  - `.mise.toml`
  - `CLAUDE.md`
  - `Sources/AgentStudioGit/AgentStudioGit.swift`
  - `Tests/AgentStudioGitTests/AgentStudioGitTests.swift`
- AgentStudio consumer evidence:
  - `Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingTreeStatusProvider.swift`
  - `Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewSourceProvider.swift`
  - `Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPackageBuilder.swift`
  - `Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeContentStore.swift`
  - `Sources/AgentStudio/Features/Bridge/Models/ReviewFoundation/*`
- Research basis:
  - libgit2 threading: https://github.com/libgit2/libgit2/blob/main/docs/threading.md
  - libgit2 worktree API: https://github.com/libgit2/libgit2/blob/main/include/git2/worktree.h
  - libgit2 index writes: https://libgit2.org/docs/reference/main/index/git_index_write.html
  - Git worktree behavior: https://git-scm.com/docs/git-worktree
  - Git credential helpers: https://git-scm.com/docs/gitcredentials
  - Git environment variables: https://git-scm.com/docs/git
  - libgit2 build/link: https://libgit2.org/docs/guides/build-and-link/

## Non-Goals

- No Bridge DTOs, review package builders, checkpoint stores, pane controllers, atoms, stores, persistence, or UI in this package.
- No patch application or source editing from Bridge review surfaces.
- No custom credential vault or token store.
- No hidden system-`git` implementation path for fast local status/diff/content/worktree reads.
- No `gh` dependency in this SDK. Forge APIs belong in a separate layer if needed.
- No command/response envelope inside the package. AgentStudio owns transport/correlation where needed.
- No public raw credential-bearing URL, argv, stderr, or environment value.

## Capability Matrix

| AgentStudio need | SDK owner | First implementation | Proof |
| --- | --- | --- | --- |
| list and validate worktrees | `AgentStudioGitLocalClient` | libgit2 worktree APIs | main + linked worktree tests |
| create worktree | `AgentStudioGitLocalClient` writer lane | libgit2 branch/ref + worktree add | existing branch, new branch, detached tests |
| stale metadata prune | `AgentStudioGitLocalClient` writer lane | libgit2 prune after prunable check | missing worktree metadata tests |
| linked worktree remove | `AgentStudioGitLocalClient` writer lane | validated ID/path + clean/force policy + prune flags | clean, dirty, untracked, locked, main refusal tests |
| repo identity | `GitRepositoryIdentityResolver` | common git dir + canonical worktree path | symlink, `.git` file, main/linked tests |
| app enrichment status | `AgentStudioGitLocalClient.status` | libgit2 status + diff + refs/config | actual `GitWorkingTreeStatusProvider` adapter compile proof |
| Bridge endpoint comparison | `AgentStudioGitLocalClient.resolveRevision`, `readTree`, `diff`, `content` | libgit2 object/tree/diff/blob reads | actual Bridge adapter compile proof |
| Bridge content loading | adapter-owned handle index + SDK content locators | package values plus AgentStudio handle registry | request by handle round trip test |
| authenticated clone/fetch/push/remote refs | `AgentStudioGitRemoteClient` | system Git with trusted process policy | fake-git tests + opt-in live smoke status |
| future forge APIs | separate layer | out of scope | no GitHub API dependency here |

## Security Context

Assets / privileges:
- User repository contents, `.git` metadata, worktree directories, refs, index, config, credential helper outputs, SSH agent access, remote URLs, release artifacts, and CI scripts.

Entry points:
- Public SDK requests, filesystem paths, remote URLs, branch/ref names, environment values, system Git subprocesses, libgit2 C APIs, artifact scripts, and CI workflows.

Untrusted inputs:
- Repository paths, worktree paths, branch names, remote names, refspecs, remote URLs, Git config values, subprocess output, file names from repositories, commit messages, binary content, and environment variables.

Trust boundaries / auth assumptions:
- Local libgit2 operations read local repo data and do not require credentials.
- Remote/auth operations use system Git so the user's existing credential helpers, SSH agent, Git config, certificates, and enterprise setup remain authoritative.
- System Git executable selection, inherited environment policy, prompt policy, protocol allowlist, and timeout are trusted client configuration. They are not public per-request fields.
- Default remote operations are noninteractive. Noninteractive mode disables Git/SSH askpass helpers and enables SSH batch mode. Interactive prompting is a trusted opt-in policy for a caller that owns UI/TTY behavior.

Security invariants:
- Public values never contain credential-bearing URLs, tokens, raw argv with secrets, raw stderr with secrets, or private key paths.
- Public origin/remote snapshots are redacted before they are encoded or returned to AgentStudio.
- System Git processes fail with a typed timeout error when they exceed the configured operation timeout.
- Do not auto-delete Git lock files.
- Do not remove a worktree working directory unless the request targets a validated worktree ID/path and explicitly allows the relevant destructive behavior.
- Read-only status/diff/content operations must not write the actual index for either main or linked worktrees.
- All libgit2 error details are copied on the failing thread before any `await`.

Required proof:
- Unit tests for URL/argv/stderr/private-key-path redaction and public origin snapshot redaction.
- Unit tests for typed error mapping and public Codable payloads.
- Integration tests for lock failures, dirty-worktree refusal, force removal, stale prune, linked worktree index paths, and read-only index hash stability.
- Fake system-Git tests for command construction, environment policy, prompt policy, timeout behavior, protocol restrictions, `remoteReferences`, parser output, and redaction.
- Clean consumer proof that a downstream package can resolve and build the public SDK products through the local development path and evaluate the distributable artifact manifest path.

## Public Shape

Use split targets/products inside the same repo:

- `AgentStudioGitContracts`: public value types and protocols, no libgit2, no system Git process runner.
- `AgentStudioGitLocal`: libgit2 local implementation.
- `AgentStudioGitRemote`: system Git remote/auth implementation.
- `AgentStudioGit`: convenience product that re-exports contracts plus local and remote implementations.

Local-only AgentStudio adapters must be able to depend on `AgentStudioGitContracts` + `AgentStudioGitLocal` without linking remote/auth process code.

## Requirements / Proof Matrix

| Requirement | Task | Proof layer | Required evidence |
| --- | --- | --- | --- |
| Spec matches two-seam SDK | 0 | docs + grep | no old local-only API/auth contradictions |
| No false filtered test gates | 0 | unit/tooling | helper fails on zero executed tests |
| Public contracts compile in one cutover | 1 | unit | full `swift test`; raw-value and negative decode tests |
| Public values redact sensitive data | 1, 8 | unit/security | credential URL, argv, stderr redaction tests |
| Worktree identity and writer registry are stable | 2 | unit + integration | symlink, `.git` file, main/linked tests |
| libgit2 packaging works locally and downstream | 3 | build + CI | local build, import canary, scratch consumer resolve/build |
| libgit2 runtime/errors are safe | 4 | unit + sanitizer scope | same-frame error capture; wrapper sanitizer proof |
| Worktree create/prune/remove semantics are safe | 5 | integration | dirty/untracked/locked/main/force/stale cases |
| App enrichment seam is backed without shell parsing | 6 | integration + compile proof | actual AgentStudio adapter compile spike |
| Bridge data and content handles are supported | 7 | integration + compile proof | actual Bridge adapter compile spike |
| Remote/auth uses user Git safely | 8 | unit + smoke | fake-git + smoke status recorded |
| CI and release artifact are consumable | 9 | CI + consumer | downstream SwiftPM dependency proof |

---

### Task 0: Reconcile Spec, Tooling, And Proof Helpers

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- Modify: `.mise.toml`
- Create: `scripts/run-swift-test-filter.sh`
- Create: `.github/workflows/check.yml`

- [x] **Step 1: Rewrite stale repo guidance**

Replace stale CLI-test wording in `CLAUDE.md` with:

```markdown
- Use Git compatibility fixtures to compare package behavior against controlled real Git repositories. This is a test strategy, not a product architecture.
```

Replace the integration paragraph with:

```markdown
Integration tests use temporary real Git repositories with scrubbed test Git config. They may call system `git` to create fixture states and expected behavior. Production local status/diff/content/worktree reads must be backed by the SDK local engine, not shell parsing.
```

- [x] **Step 2: Reconcile the source spec**

Update the spec's goal, non-goals, authentication, public API shape, packaging, AgentStudio boundaries, and acceptance criteria so it has one story:

```markdown
The SDK owns two seams:

1. Local Git engine: libgit2-backed worktree, status, branch/ref, diff, tree, blob, and content operations.
2. Remote/auth engine: system-Git-backed network operations that intentionally reuse the user's Git client configuration and credential path.

The old local-only API shape is superseded by `AgentStudioGitLocalClient` and `AgentStudioGitRemoteClient`.
```

Remove or update claims that clone/fetch/push/auth are first-implementation non-goals.

- [x] **Step 3: Add sanitizer tasks with scoped wording**

In `.mise.toml`:

```toml
[tasks.test-asan]
description = "Run Swift wrapper tests with AddressSanitizer"
run = "bash scripts/run-swift-test-suites.sh --sanitize address --disable-xctest"

[tasks.test-tsan]
description = "Run Swift wrapper tests with ThreadSanitizer"
run = "bash scripts/run-swift-test-suites.sh --sanitize thread --disable-xctest"
```

Do not claim these instrument a prebuilt libgit2 artifact unless Task 3 adds sanitizer-specific libgit2 builds.

- [x] **Step 4: Add no-zero-test helper**

Create `scripts/run-swift-test-filter.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/run-swift-test-filter.sh <SwiftPM filter>" >&2
  exit 64
fi

filter="$1"
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

swift test --filter "$filter" 2>&1 | tee "$output_file"

if rg -q "No matching test cases were run|Test run with 0 tests in 0 suites" "$output_file"; then
  echo "filtered Swift test gate executed zero tests: $filter" >&2
  exit 1
fi
```

- [x] **Step 5: Create baseline CI**

Create `.github/workflows/check.yml` now, not later. It must run:

```bash
mise run check
```

The libgit2 artifact jobs are added in Task 3 after the artifact path exists.

- [x] **Step 6: Verify**

Run:

```bash
rg -n "AgentStudioGitClient|clone, fetch, push.*out of scope|SSH auth.*out of scope|HTTPS auth.*out of scope" docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md
scripts/run-swift-test-filter.sh DefinitelyNoSuchTest
```

Expected:
- grep returns no stale old-API/auth scope claims
- helper fails on `DefinitelyNoSuchTest`

- [x] **Step 7: Commit**

```bash
git add CLAUDE.md docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md .mise.toml scripts .github
git commit -m "docs: define AgentStudio Git SDK boundary"
```

### Task 1: Public Contract Cutover

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/AgentStudioGit/AgentStudioGit.swift`
- Delete or replace: `Tests/AgentStudioGitTests/AgentStudioGitTests.swift`
- Create: `Sources/AgentStudioGit/Contracts/AgentStudioGitSDK.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitDataPlaneError.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitRepositoryIdentity.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitWorktreeContracts.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitStatusContracts.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitDiffContentContracts.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitRemoteContracts.swift`
- Create: `Sources/AgentStudioGit/Contracts/GitRedaction.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitWireEnumSnapshotTests.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitInvalidDecodeTests.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitRedactionTests.swift`

- [x] **Step 1: Split products and targets**

`Package.swift` must expose `AgentStudioGitContracts`, `AgentStudioGitLocal`, `AgentStudioGitRemote`, and `AgentStudioGit`. `AgentStudioGitLocal` and `AgentStudioGitRemote` can be stub targets until later tasks, but the package graph must compile.

- [x] **Step 2: Write failing contract tests**

Tests must cover:
- `GitStatusSnapshot` with tri-state `originResolution`
- `GitDiffFile` with stable `fileId` or documented deterministic derivation
- `GitRemoteProcessFailure` redacts credentials from arguments and stderr
- enum raw values
- invalid decode behavior
- URL fields encode as Swift `URL` strings and are not promised as raw POSIX paths across non-Swift boundaries

- [x] **Step 3: Define SDK protocols**

Define:

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

- [x] **Step 4: Define worktree create/remove modes**

`GitCreateWorktreeRequest` must use an explicit mode:

```swift
public enum GitWorktreeCreateMode: Codable, Equatable, Hashable, Sendable {
    case existingBranch(name: String)
    case newBranch(name: String, startPoint: GitRevisionTarget)
    case detached(startPoint: GitRevisionTarget)
}
```

`GitRemoveWorktreeRequest` must target `GitWorktreeID` or canonical path and include:
- `removeWorkingDirectory: Bool`
- `forceDiscardChanges: Bool`

Default behavior refuses dirty tracked changes, staged changes, untracked files, locked worktrees, main worktree, and ambiguous paths.

- [x] **Step 5: Define status origin tri-state**

`GitStatusSnapshot` must include:

```swift
public enum GitOriginResolution: Codable, Equatable, Hashable, Sendable {
    case awaitingResolution
    case confirmedAbsent
    case resolved(GitRemoteSnapshot)
}
```

- [x] **Step 6: Define content locators and hashes honestly**

`GitDiffFile` must include either a stable `fileId` or an explicit deterministic derivation rule. `contentHashAlgorithm` must use an honest label such as `git-blob-sha1`. If a workdir-side object ID is absent, the implementation must explicitly hash the filtered content before exposing `newContentHash`.

- [x] **Step 7: Define redacted error values**

Public process failures expose redacted fields only:

```swift
public struct GitRemoteProcessFailure: Codable, Equatable, Sendable {
    public let executable: String
    public let redactedArguments: [String]
    public let exitCode: Int32
    public let redactedStderr: String
}
```

- [x] **Step 8: Run tests**

Run:

```bash
scripts/run-swift-test-filter.sh GitPublicContractTests
swift test
```

Expected: filtered gate executes non-zero tests, and full suite passes.

- [x] **Step 9: Commit**

```bash
git add Package.swift Sources Tests scripts
git commit -m "feat: define AgentStudio Git SDK contracts"
```

### Task 2: Repository Identity And Writer Registry

**Files:**
- Create: `Sources/AgentStudioGitLocal/Runtime/GitPathCanonicalizer.swift`
- Create: `Sources/AgentStudioGitLocal/Runtime/GitRepositoryIdentityResolver.swift`
- Create: `Sources/AgentStudioGitLocal/Runtime/GitRepositoryWriterRegistry.swift`
- Create: `Tests/AgentStudioGitTests/Runtime/GitRepositoryIdentityTests.swift`
- Create: `Tests/AgentStudioGitTests/Runtime/GitRepositoryWriterRegistryTests.swift`

- [x] **Step 1: Write identity tests**

Cover:
- relative path and absolute path equivalence
- symlink path and real path equivalence
- linked worktree `.git` file parsing
- main worktree and linked worktree share common git directory
- linked worktree private index path resolves correctly
- synthetic `main` display name does not collide with a real linked worktree named `main`

- [x] **Step 2: Implement identity resolver**

Use libgit2 repository APIs where available, especially common git dir and repository path APIs, rather than relying only on `URL.resolvingSymlinksInPath()`.

- [x] **Step 3: Implement writer registry**

The registry is process-wide and actor-backed, keyed by canonical common git directory. It serializes this process only; Git/libgit2 still create real lock files for write operations.

- [x] **Step 4: Run tests**

```bash
scripts/run-swift-test-filter.sh GitRepositoryIdentityTests
scripts/run-swift-test-filter.sh GitRepositoryWriterRegistryTests
swift test
```

- [x] **Step 5: Commit**

```bash
git add Sources/AgentStudioGitLocal Tests/AgentStudioGitTests/Runtime
git commit -m "feat: add repository identity and writer registry"
```

### Task 3: libgit2 Artifact Pipeline And Downstream Packaging

**Files:**
- Modify: `Package.swift`
- Modify: `.mise.toml`
- Modify: `.gitignore`
- Modify: `.github/workflows/check.yml`
- Create: `.github/workflows/libgit2-artifact.yml`
- Create: `scripts/build-libgit2-xcframework.sh`
- Create: `scripts/verify-libgit2-artifact.sh`
- Create: `scripts/verify-package-consumer.sh`
- Create: `ThirdPartyNotices/libgit2.md`

- [x] **Step 1: Choose source ownership**

Use a pinned git submodule at `vendor/libgit2` with an exact commit. CI must checkout submodules. Record the commit, license, build flags, and update process in `ThirdPartyNotices/libgit2.md`.

- [x] **Step 2: Build importable XCFramework**

The build script must:
- build static libgit2 with `BUILD_SHARED_LIBS=OFF`, `BUILD_TESTS=OFF`, `BUILD_EXAMPLES=OFF`, `USE_SSH=OFF`, `USE_HTTPS=OFF`, `USE_GSSAPI=OFF`
- include libgit2 headers
- generate `module.modulemap`
- pass headers to `xcodebuild -create-xcframework`
- create a zip only for release/distribution
- compute checksum only for the release zip, not as proof for a local path binary target

- [x] **Step 3: Add linker settings and import canary**

`Package.swift` must include the binary target and any required system link settings, such as `z` and `iconv` if the chosen libgit2 build requires them. Add a small import canary that imports `CLibGit2Local` and calls `git_libgit2_version`.

- [x] **Step 4: Separate local and distributable manifests**

During local development, the package may use a local binary target path. Before AgentStudio consumption, the plan must cut over to a URL-based binary target with checksum, or another proven SwiftPM-consumable strategy. The local path is not the downstream consumption story.

- [x] **Step 5: Wire mise and CI before runtime work**

Add:

```toml
[tasks.build-libgit2]
run = "bash scripts/build-libgit2-xcframework.sh"

[tasks.verify-libgit2]
run = "bash scripts/verify-libgit2-artifact.sh"
```

`mise run check` must build or fetch the artifact before SwiftPM evaluates targets that import it.

- [x] **Step 6: Prove clean checkout and downstream consumer**

Run:

```bash
mise run build-libgit2
mise run verify-libgit2
swift build
swift test
bash scripts/verify-package-consumer.sh
```

`build-libgit2` owns scoped cleanup of `.build/libgit2/{arm64,x86_64,macos-universal}`, `.build/libgit2/CLibGit2LocalHeaders`, and `Artifacts/CLibGit2Local.xcframework`; do not manually delete repo-wide build directories as a proof shortcut.

`verify-package-consumer.sh` creates a scratch SwiftPM package outside this repo, depends on `agentstudio-git`, resolves it from the intended downstream path, proves an umbrella-only `import AgentStudioGit` consumer, imports all public leaf products (`AgentStudioGitContracts`, `AgentStudioGitLocal`, and `AgentStudioGitRemote`) in a second consumer, and builds without running repo-local mise tasks inside the dependency checkout. The local build/run phase clears ambient `AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL` and `AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM` so local path proof cannot accidentally switch to release URL mode. It also evaluates the HTTPS/checksum release-manifest mode; a real hosted artifact URL is required before claiming a network download proof.

- [x] **Step 7: Commit**

```bash
git add Package.swift .mise.toml .gitignore .github scripts ThirdPartyNotices
git commit -m "build: add libgit2 artifact pipeline"
```

### Task 4: libgit2 Runtime, Errors, And Sessions

**Files:**
- Create: `Sources/AgentStudioGitLocal/LibGit2/LibGit2Runtime.swift`
- Create: `Sources/AgentStudioGitLocal/LibGit2/LibGit2ErrorCapture.swift`
- Create: `Sources/AgentStudioGitLocal/LibGit2/LibGit2RepositorySession.swift`
- Create: `Tests/AgentStudioGitTests/LibGit2/LibGit2RuntimeTests.swift`
- Create: `Tests/AgentStudioGitTests/LibGit2/LibGit2ErrorCaptureTests.swift`
- Create: `Tests/AgentStudioGitTests/LibGit2/LibGit2RepositorySessionTests.swift`

- [x] **Step 1: Write runtime tests**

Tests cover init-once-per-process behavior, same-frame error copying, repository-open failure mapping, and pointer release on early throws. Lifecycle tests are serialized so they do not race other Swift Testing suites.

- [x] **Step 2: Implement runtime manager**

`LibGit2Runtime` is process-scoped. Do not shutdown libgit2 while any operation can still hold libgit2 objects.

- [x] **Step 3: Implement error capture**

Copy `git_error_last()` fields synchronously in the failing call frame before any `await`.

- [x] **Step 4: Implement session owner**

`git_repository*`, `git_index*`, `git_diff*`, `git_worktree*`, and related pointers do not cross actor or task boundaries. Acquisitions pair with `defer` frees in the same synchronous frame.

- [x] **Step 5: Run tests**

```bash
scripts/run-swift-test-filter.sh LibGit2RuntimeTests
scripts/run-swift-test-filter.sh LibGit2ErrorCaptureTests
scripts/run-swift-test-filter.sh LibGit2RepositorySessionTests
swift test
mise run test-asan
mise run test-tsan
```

Expected: Swift wrapper sanitizer lanes pass, or exact toolchain limitation is recorded. Do not claim native libgit2 instrumentation unless Task 3 built a sanitizer-specific artifact.

- [x] **Step 6: Commit**

```bash
git add Sources/AgentStudioGitLocal/LibGit2 Tests/AgentStudioGitTests/LibGit2
git commit -m "feat: add libgit2 runtime wrappers"
```

### Task 5: Fast Worktree Operations

**Files:**
- Modify: `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- Modify: `Sources/AgentStudioGitLocal/Runtime/GitRepositoryWriterRegistry.swift`
- Create: `Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeReader.swift`
- Create: `Sources/AgentStudioGitLocal/Worktrees/LibGit2WorktreeWriter.swift`
- Create: `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- Modify: `Tests/AgentStudioGitTests/Contracts/GitWireEnumSnapshotTests.swift`
- Create: `Tests/AgentStudioGitTests/Fixtures/GitFixtureRepository.swift`
- Create: `Tests/AgentStudioGitTests/Fixtures/GitProcess.swift`
- Create: `Tests/AgentStudioGitTests/Integration/GitWorktreeIntegrationTests.swift`
- Modify: `Tests/AgentStudioGitTests/Runtime/GitRepositoryWriterRegistryTests.swift`

- [x] **Step 1: Add deterministic fixture helpers**

`GitProcess` is test-only. It uses scrubbed config, captures stdout/stderr, pins locale where parsing matters, and includes output in failures.

- [x] **Step 2: Write worktree tests**

Cover:
- main worktree listed with synthetic display name
- linked worktree listed
- real linked worktree named `main`
- create from existing branch
- create new branch from start point
- create detached worktree
- branch already checked out in another worktree
- validate existing worktree
- validate missing/stale worktree
- lock with reason
- unlock
- stale metadata prune without touching a live worktree
- linked-path listing resolves the real main worktree once
- failed new-branch create rolls back branch metadata
- locked stale metadata returns typed locked refusal
- malformed `.git` files are not reported as missing repositories
- default clients use a shared process-wide writer registry
- main worktree removal refused
- clean linked worktree removal
- dirty tracked removal refused without force
- staged removal refused without force
- untracked removal refused without force
- dirty removal with `forceDiscardChanges: true`
- locked removal refused unless force policy explicitly permits it
- symlink escape/path mismatch refused
- permission-denied partial failure returns typed recovery outcome

- [x] **Step 3: Implement reader**

Use libgit2 list/lookup/open/validate/lock APIs. Preserve display name separately from stable ID.

- [x] **Step 4: Implement create**

Compose branch/ref operations and worktree add inside the writer lane:
- existing branch
- new branch from revision
- detached from revision

- [x] **Step 5: Implement stale prune and remove separately**

Stale prune uses libgit2 prunable checks and does not delete a live worktree. Remove validates the target ID/path, checks dirty state unless force is set, refuses main worktree, and only then uses the required libgit2 prune flags for working-tree deletion.

- [x] **Step 6: Run tests**

```bash
scripts/run-swift-test-filter.sh GitWorktreeIntegrationTests
swift test
```

- [x] **Step 7: Commit**

```bash
git add Sources/AgentStudioGitLocal Tests/AgentStudioGitTests
git commit -m "feat: implement safe worktree operations"
```

### Task 6: App Enrichment Status, Branch, And Origin Facts

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/AgentStudioGitContracts/GitStatusContracts.swift`
- Modify: `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- Create: `Sources/AgentStudioGitLocal/Status/LibGit2StatusReader.swift`
- Create: `Sources/AgentStudioGitLocal/Status/LibGit2BranchReader.swift`
- Create: `Sources/AgentStudioGitLocal/Status/GitIndexPathResolver.swift`
- Modify: `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- Create: `Tests/AgentStudioGitTests/Integration/GitStatusIntegrationTests.swift`
- Create: `Tests/AgentStudioGitTests/ConsumerCompatibility/GitWorkingTreeStatusCompatibilityTests.swift`
- Modify: `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

- [x] **Step 1: Write status tests**

Cover:
- clean
- modified
- staged
- staged and modified again
- untracked
- ignored
- deleted
- renamed
- binary
- ahead
- behind
- diverged
- no upstream
- origin present
- origin absent
- origin lookup failure with summary still returned
- detached HEAD
- unborn HEAD / empty repo
- main and linked worktree index paths

- [x] **Step 2: Prove reads do not mutate index**

Resolve the actual index path through libgit2/repository metadata for main and linked worktrees. Compare index bytes or content hash before and after status/diff-backed shortstat. Assert no existing lock file is removed or replaced.

- [x] **Step 3: Pin line-count semantics**

Match current AgentStudio UI semantics: `git diff --shortstat HEAD --` equivalent, which means HEAD tree to workdir-with-index. Add a fixture with staged and unstaged edits to prove exact counts.

- [x] **Step 4: Implement status and branch readers**

Map libgit2 status flags to two-axis status entries. Compute `GitStatusSummary`, `GitOriginResolution`, branch/head, upstream, ahead/behind, and origin facts.

- [x] **Step 5: Add actual adapter compile proof**

Create a small AgentStudio-side compile spike or checked harness that implements the real `GitWorkingTreeStatusProvider` from SDK values. Mirror-only structs are not sufficient proof.

- [x] **Step 6: Run tests**

```bash
scripts/run-swift-test-filter.sh GitStatusIntegrationTests
scripts/run-swift-test-filter.sh GitWorkingTreeStatusCompatibilityTests
swift test
```

- [x] **Step 7: Commit**

```bash
git add Sources/AgentStudioGitLocal Tests/AgentStudioGitTests
git commit -m "feat: implement status and branch enrichment"
```

### Task 7: Bridge Review Data Operations

**Files:**
- Modify: `Sources/AgentStudioGitContracts/GitDataPlaneError.swift`
- Modify: `Sources/AgentStudioGitContracts/GitDiffContentContracts.swift`
- Modify: `Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift`
- Create: `Sources/AgentStudioGitLocal/Review/LibGit2RevisionResolver.swift`
- Create: `Sources/AgentStudioGitLocal/Review/LibGit2TreeReader.swift`
- Create: `Sources/AgentStudioGitLocal/Review/LibGit2DiffReader.swift`
- Create: `Sources/AgentStudioGitLocal/Review/LibGit2ContentReader.swift`
- Create: `Sources/AgentStudioGitLocal/Review/LibGit2ReviewSupport.swift`
- Modify: `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- Create: `Tests/AgentStudioGitTests/Integration/GitReviewDataIntegrationTests.swift`
- Create: `Tests/AgentStudioGitTests/ConsumerCompatibility/BridgeReviewSourceCompatibilityTests.swift`
- Modify: `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

- [x] **Step 1: Write review-data tests**

Cover:
- commit endpoint resolution
- head endpoint resolution
- index endpoint resolution
- working-tree endpoint resolution
- two endpoint diff
- tree listing with folders/files
- text content load
- binary content load
- large file metadata
- old/new content hashes
- workdir-side filtered hash when libgit2 diff ID is not valid, without writing read-side blobs to the object database
- old/new file modes for executable-bit and type-change review surfaces
- CRLF/filter fixture
- rename descriptor with stable ID
- deleted file descriptor
- working-tree path escape and symlink escape refusal
- content load from adapter handle index after local path values are discarded

- [x] **Step 2: Keep checkpoint composition out of this package**

Package proof covers git-backed endpoints only. `resolveCheckpointEndpoint` remains AgentStudio-owned composition: checkpoint metadata -> git endpoint -> package call.

- [x] **Step 3: Implement revision resolver and tree reader**

Return Git-shaped revision/tree/blob identities. Do not import Bridge types.

- [x] **Step 4: Implement diff reader**

Return changed-file descriptors with stable `fileId` or a documented derivation rule, previous path, mode, size, binary flag, line counts, blob hashes, and content locators. Language/mime values may be basic file metadata only; rich classification remains AgentStudio-owned.

- [x] **Step 5: Implement content reader**

Support blob reads and working-tree file reads. Enforce size limits through request options and typed errors.

- [x] **Step 6: Add actual Bridge adapter compile proof**

Create an AgentStudio-side compile spike or checked harness that uses real Bridge types for `compareEndpoints`, `readTree`, `readReviewItemDescriptor`, and `loadContent`. The content test must build handles, discard local path variables, and load content from only `BridgeContentLoadRequest`.

- [x] **Step 7: Run tests**

```bash
scripts/run-swift-test-filter.sh GitReviewDataIntegrationTests
scripts/run-swift-test-filter.sh BridgeReviewSourceCompatibilityTests
scripts/run-swift-test-filter.sh GitPublicContractTests
swift test
```

- [x] **Step 8: Commit**

```bash
git add Sources/AgentStudioGitContracts Sources/AgentStudioGitLocal Tests/AgentStudioGitTests docs/superpowers/plans docs/wip/implementation-proof
git commit -m "feat: implement Git review data operations"
```

### Task 8: Remote/Auth Seam Using System Git

**Files:**
- Modify: `Sources/AgentStudioGitContracts/GitRemoteContracts.swift`
- Create: `Sources/AgentStudioGitRemote/SystemGitRemoteClient.swift`
- Create: `Sources/AgentStudioGitRemote/GitExecutableLocator.swift`
- Create: `Sources/AgentStudioGitRemote/GitProcessRunner.swift`
- Create: `Sources/AgentStudioGitRemote/GitRemoteOutputParser.swift`
- Modify: `Tests/AgentStudioGitTests/Contracts/GitPublicContractTests.swift`
- Create: `Tests/AgentStudioGitTests/Remote/SystemGitRemoteClientTests.swift`
- Create: `Tests/AgentStudioGitTests/Remote/GitProcessRunnerTests.swift`
- Create: `Tests/AgentStudioGitTests/Remote/GitRemoteOutputParserTests.swift`
- Modify: `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`

- [x] **Step 1: Define trusted process policy**

Move executable selection, inherited environment behavior, protocol allowlist, and prompt behavior into trusted client configuration. Public request values do not choose arbitrary executables or environment allowlists.

Default policy:
- inherit user environment by default for production
- strip tracing variables and redact public output
- set `LC_ALL=C` for parsed command output
- default `GIT_TERMINAL_PROMPT=0`
- allow only configured protocols
- interactive prompting requires trusted opt-in

- [x] **Step 2: Write fake-git tests**

Cover:
- clone args
- fetch args
- push args
- `remoteReferences` / `ls-remote` args
- default env inheritance
- scrubbed test env
- prompt suppression
- disabled askpass helpers in noninteractive mode
- SSH batch mode in noninteractive mode
- interactive opt-in
- timeout behavior
- protocol restrictions
- redacted argv/stderr for credential-bearing URLs and SSH private-key paths
- parser tests for normal refs, symrefs, peeled tags, malformed lines, and failures

- [x] **Step 3: Implement executable locator**

Resolve from trusted configuration or normal user path. Do not accept arbitrary untrusted per-request executable paths.

- [x] **Step 4: Implement process runner**

Use `Process` argument arrays, never shell string concatenation. Validate or delimit untrusted ref/remote/path values so option-shaped inputs cannot be interpreted as flags where Git supports separators. Capture stdout/stderr. Enforce the configured operation timeout. Redact before constructing public errors.

- [x] **Step 5: Implement remote client**

Use parseable output where available:
- `ls-remote` for `remoteReferences`
- porcelain/pinned formats for fetch/push where Git version supports them
- typed fallback errors where the user's Git is too old for a required parseable mode

- [x] **Step 6: Add opt-in live smoke**

Add `AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE=1`. The final proof artifact must record whether the smoke was run or skipped. Default CI does not require real credentials.

For full live auth proof, `scripts/verify-live-remote-auth.sh` requires:

- `AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL`
- `AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL`

Each URL must point at a disposable repository where the current system Git configuration can clone, fetch, push, and delete temporary refs under `refs/heads/agentstudio-git-live-smoke/`. This gate proves HTTPS credential-helper and SSH-agent behavior; it is not run by default CI.

- [x] **Step 7: Run tests**

```bash
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
scripts/run-swift-test-filter.sh GitProcessRunnerTests
scripts/run-swift-test-filter.sh GitRemoteOutputParserTests
swift test
```

- [x] **External gate: Run full HTTPS/SSH live auth proof**

Completed with disposable writeable smoke remotes configured through environment variables:

```bash
AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL=<https-writeable-remote> AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL=<ssh-writeable-remote> bash scripts/verify-live-remote-auth.sh
```

Current live-auth execution on 2026-06-12:

- HTTPS credential-helper lane passed: clone, local commit, push temporary ref, fetch, remote reference discovery, and temporary-ref deletion.
- SSH-agent lane passed: clone, local commit, push temporary ref, fetch, remote reference discovery, and temporary-ref deletion.
- Post-run `git ls-remote --heads` checks found no leftover `refs/heads/agentstudio-git-live-smoke/*` refs on either disposable smoke remote.

- [x] **Step 8: Commit**

```bash
git add Sources/AgentStudioGitContracts Sources/AgentStudioGitRemote Tests/AgentStudioGitTests docs/superpowers/plans docs/wip/implementation-proof
git commit -m "feat: add system Git remote auth seam"
```

### Task 9: CI, Release Artifact, And Consumer Readiness

**Files:**
- Modify: `.github/workflows/check.yml`
- Modify: `.github/workflows/libgit2-artifact.yml`
- Modify: `Package.swift`
- Create: `docs/guides/agentstudio-consumption.md`
- Create: `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`
- Create: `scripts/verify-hosted-libgit2-artifact.sh`

- [x] **Step 1: Prove CI gates**

CI must run:

```bash
mise run check
mise run test-asan
mise run test-tsan
bash scripts/verify-package-consumer.sh
```

GitHub push run `27414489143` failed in `mise run check` before package build because `check.yml` used `macos-15`, whose default Xcode/Swift tools were 16.4 / 6.1. The package declares Swift tools 6.2, so CI and the artifact workflow now use `macos-26`, which GitHub marks generally available and whose current image carries Xcode 26.x / Swift 6.2-capable tooling. Follow-up run `27414830257` reached lint and failed because `swift-format` was not installed on the runner. Follow-up run `27415217419` built, linted, and compiled the test bundle, then hung inside monolithic `swift test` with no suite-level output until it was canceled after 21m46s. Follow-up run `27416665585` proved the suite-filter runner worked: the package-check step timed out after 12 minutes and the completed log identified `GitProcessRunnerTests` as the last started suite; the same log exposed that the filter helper depended on `rg`, which was not installed on GitHub's runner. Follow-up run `27417839524` passed the remote package-check step, then hung after raw ASan build output with no Swift Testing output. CI now installs `mise`, `cmake`, `swift-format`, and `swiftlint`; the package-check and sanitizer steps have 12-minute timeouts; `mise run test`, `mise run test-asan`, and `mise run test-tsan` run each named Swift Testing suite through `scripts/run-swift-test-filter.sh`; sanitizer tasks pass `--disable-xctest` to avoid the SwiftPM XCTest helper sanitizer load policy path; the filter helper falls back to `grep` when `rg` is unavailable; and the POSIX process-runner test suite is serialized with shorter fake-process default timeouts plus a regression test for descendants that ignore TERM. Packaging tests pin the workflow runner labels, tooling install, timeout, suite-filter test tasks, sanitizer option forwarding, filter fallback, and process-runner test bounds.

- [x] **Step 2: Publish or simulate the distributable artifact path**

Before AgentStudio consumption, prove the manifest strategy that downstream SwiftPM will use:
- URL binary target with checksum, or
- committed artifact if that tradeoff is explicitly accepted

Local untracked artifacts are not an AgentStudio consumption strategy.

- [x] **Step 3: Add consumer guide**

Document:
- split products/targets
- local engine vs remote/auth engine
- redaction and prompt policy
- why system Git owns remote/auth
- how AgentStudio imports the package
- proof gates required before replacing shell parsing

- [x] **Step 4: Record proof**

Create proof doc with:
- commit SHA
- command outputs
- test counts
- filtered gate counts
- sanitizer scope/result
- libgit2 commit
- artifact checksum
- downstream consumer proof
- remote live smoke status
- known limitations

`verify-agentstudio-compatibility.sh` is an explicit external gate because a plain `agentstudio-git` checkout does not contain AgentStudio. Default CI may report this gate as not configured, but must not claim AgentStudio compatibility unless `AGENTSTUDIO_GIT_AGENTSTUDIO_PATH` points at a real checkout and required compatibility mode passes.

- [x] **Step 5: Run final validation**

```bash
mise run format
mise run lint
mise run check
mise run test-asan
mise run test-tsan
bash scripts/verify-package-consumer.sh
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio bash scripts/verify-agentstudio-compatibility.sh
```

- [x] **External gate: Run hosted libgit2 artifact download proof**

Completed with `CLibGit2Local.xcframework.zip` published under a public HTTPS artifact directory. The verifier used an isolated SwiftPM cache/scratch path, suppressed raw SwiftPM output, rejected local/private artifact hosts in regression coverage, and asserted the pinned libgit2 version:

```bash
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL=<https-hosted-CLibGit2Local.xcframework.zip> AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM=<swiftpm-checksum> bash scripts/verify-hosted-libgit2-artifact.sh
```

- [x] **External gate: Run final HTTPS/SSH live auth validation**

Completed with disposable writeable smoke remotes configured through environment variables:

```bash
AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL=<https-writeable-remote> AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL=<ssh-writeable-remote> bash scripts/verify-live-remote-auth.sh
```

Current live-auth execution on 2026-06-12 proved both HTTPS credential-helper and SSH-agent lanes against disposable remotes. Configured remote values are intentionally omitted from artifacts.

- [x] **Post-review gate: Correct accepted review findings**

Review-swarm findings accepted and fixed:

- arbitrary HTTPS origin query values are redacted before status snapshots cross the SDK boundary
- task cancellation escalates through process-group cleanup so TERM-resistant descendants are not left running until timeout
- dangerous inherited Git env overrides are stripped before system Git runs while legitimate auth/trust env such as inherited `GIT_SSH_COMMAND` and custom TLS CA/client-cert variables remain available
- hosted artifact verification parses literal IP hosts and resolves hostnames before SwiftPM, rejecting loopback/private IPv4, IPv6, and IPv4-mapped IPv6 endpoints
- `GitDataPlaneError` rejects ambiguous multi-case wire payloads
- Bridge compatibility proof asserts old/new changed-file hashes survive the SDK adapter
- consumer guide sanitizer commands use `mise run test-asan` / `mise run test-tsan`
- remote process failures fully redact plain HTTPS remote values
- process output capture is bounded through stdout/stderr pipes instead of temp-file polling
- inherited and explicit `GIT_SSH_COMMAND` values preserve quoted arguments while forcing noninteractive `BatchMode=yes`

Focused proof completed:

```bash
bash scripts/run-swift-test-filter.sh GitProcessRunnerTests
bash scripts/run-swift-test-filter.sh GitStatusIntegrationTests
bash scripts/run-swift-test-filter.sh GitInvalidDecodeTests
bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start bash scripts/run-swift-test-filter.sh BridgeReviewSourceCompatibilityTests
bash scripts/run-swift-test-filter.sh GitPublicContractTests
bash scripts/run-swift-test-filter.sh GitRedactionTests
```

All focused commands exited 0. Counts are recorded in `docs/wip/implementation-proof/2026-06-11-agentstudio-git-sdk-proof.md`.

Post-fix reviewer follow-up accepted and fixed:

- `SystemGitRemoteClient.Configuration.processEnvironment()` no longer drops inherited `GIT_SSH_COMMAND`, `GIT_SSL_CAINFO`, `GIT_SSL_CERT`, `GIT_SSL_KEY`, or harmless `GIT_HTTP*` auth/trust knobs. It still strips inherited `GIT_CONFIG*`, `GIT_SSL_NO_VERIFY`, repository path overrides, `GIT_EXEC_PATH`, and `GIT_PROXY_COMMAND`, and it appends `BatchMode=yes` to SSH commands in noninteractive mode.
- `verify-hosted-libgit2-artifact.sh` now classifies literal IP hosts and resolved host addresses with `Socket.inet_pton` through Perl, so hex IPv4-mapped IPv6 literals such as `::ffff:7f00:1` / `::ffff:c0a8:1` and hostname aliases resolving to private/local IPs are rejected too.
- Focused proof after this follow-up:
  - `bash scripts/run-swift-test-filter.sh GitRedactionTests`: exit 0, `Test run with 5 tests in 1 suite passed`
  - `bash scripts/run-swift-test-filter.sh GitProcessRunnerTests`: exit 0, `Test run with 14 tests in 1 suite passed`
  - `bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests`: exit 0, `Test run with 16 tests in 1 suite passed`

The stdout/stderr output limit is now enforced through bounded pipe readers. Captured bytes are capped in memory and no process output temp files are created.

- [x] **Post-review gate: Re-run full local validation after corrections**

```bash
mise run check
mise run test-asan
mise run test-tsan
bash scripts/verify-package-consumer.sh
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start bash scripts/verify-agentstudio-compatibility.sh
git diff --check
```

Post-review full validation completed on 2026-06-12:

- `mise run check`: exit 0; rebuilt and verified `Artifacts/CLibGit2Local.xcframework`, built the package, linted with 0 SwiftLint violations, and ran the guarded suite list.
- `mise run test-asan`: exit 0; guarded suite list passed under AddressSanitizer wrapper scope.
- `mise run test-tsan`: exit 0; guarded suite list passed under ThreadSanitizer wrapper scope.
- `bash scripts/verify-package-consumer.sh`: exit 0; umbrella and leaf consumers built and ran, both reporting libgit2 `1.9.4` and `SystemGitRemoteClient true`.
- `AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start bash scripts/verify-agentstudio-compatibility.sh`: exit 0; `Test run with 7 tests in 2 suites passed`.
- `git diff --check`: exit 0.
- `AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL=<https-smoke-remote> AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL=<ssh-smoke-remote> bash scripts/verify-live-remote-auth.sh`: exit 0; HTTPS credential-helper and SSH-agent lanes each reported `Test run with 6 tests in 1 suite passed`. Smoke remote values are intentionally omitted from artifacts.
- `git ls-remote --heads <https-smoke-remote> 'refs/heads/agentstudio-git-live-smoke/*'` and `git ls-remote --heads <ssh-smoke-remote> 'refs/heads/agentstudio-git-live-smoke/*'`: exit 0; no leftover smoke refs reported.
- public hosted artifact branch: commit `aa2c8b9`; artifact directory contains `CLibGit2Local.xcframework.zip`, checksum, and README.
- `curl -L --fail --max-time 60 --output /tmp/agentstudio-git-libgit2-raw-probe.zip <public-raw-artifact-url>`: exit 0; downloaded 1.8 MB artifact with SHA-256 `33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d`.
- `AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL=<public-raw-artifact-url> AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM=33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d bash scripts/verify-hosted-libgit2-artifact.sh`: exit 0; `hosted libgit2 artifact linked successfully`; artifact URL intentionally omitted from proof output.

- [x] **Step 6: Commit**

```bash
git add .github Package.swift docs
git commit -m "ci: prove AgentStudio Git SDK readiness"
```

## AgentStudio Follow-Up Plan Boundary

After this SDK plan is implemented and reviewed, create a separate AgentStudio plan to consume it:

1. Add `agentstudio-git` through the proven downstream SwiftPM path.
2. Replace `ShellGitWorkingTreeStatusProvider` behind the existing `GitWorkingTreeStatusProvider` seam.
3. Add Bridge adapter backed by `AgentStudioGitLocalClient`.
4. Keep checkpoint resolution, Bridge DTOs, filters, annotation metadata, and review package construction in AgentStudio.
5. Keep Worktrunk UX until a separate product decision moves create/remove/switch commands.

Do not start cross-repo integration until this package has a green SDK proof artifact.

## Validation Commands For This Plan

```bash
rg -n "AgentStudioGitClient|clone, fetch, push.*out of scope|SSH auth.*out of scope|HTTPS auth.*out of scope" docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md
scripts/run-swift-test-filter.sh GitPublicContractTests
swift test
mise run format
mise run lint
mise run check
mise run test-asan
mise run test-tsan
bash scripts/verify-package-consumer.sh
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL=<https-hosted-CLibGit2Local.xcframework.zip> AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM=<swiftpm-checksum> bash scripts/verify-hosted-libgit2-artifact.sh
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio bash scripts/verify-agentstudio-compatibility.sh
```

Expected:
- no stale local-only spec claims
- no filtered SwiftPM gate can pass with zero tests
- formatting/lint pass
- all default tests pass
- sanitizer scope is honest
- downstream consumer proof passes

## Replan Triggers

Pause implementation and update the plan if:

- SwiftPM cannot support the selected local/distributable libgit2 artifact strategy.
- libgit2 worktree APIs cannot safely express create/prune/remove semantics.
- dirty worktree detection cannot match Git safety semantics.
- status/diff reads mutate the actual main or linked worktree index.
- Bridge content loading requires importing Bridge DTOs into `agentstudio-git`.
- remote/auth behavior needs interactive UI that AgentStudio has not designed.
- system Git output parsing cannot be made stable for supported Git versions.

## Recommended Next Step

Run the final implementation review and completion audit against the current diff. If no blocker remains, commit the SDK/proof changes and proceed to the separate AgentStudio consumption plan.
