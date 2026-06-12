# AgentStudio Git SDK Implementation Proof

Date: 2026-06-11

Goal:

- `docs/wip/goals/2026-06-11-agentstudio-git-sdk-goal.md`

Plan:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`

## Current Scope

Tasks 0-4: spec/tooling, public contracts, repository identity/runtime lanes, libgit2 artifact packaging, and libgit2 runtime/session wrappers.

## Coverage

- Plan line count: 925; read in chunks 1-240, 241-480, 481-720, 721-925.
- Spec line count: 201; read 1-201.
- Goal contract line count: 156; read 1-156.
- Plan review line count: 125; read 1-125.
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
