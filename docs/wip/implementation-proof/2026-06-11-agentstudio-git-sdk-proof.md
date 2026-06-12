# AgentStudio Git SDK Implementation Proof

Date: 2026-06-11

Goal:

- `docs/wip/goals/2026-06-11-agentstudio-git-sdk-goal.md`

Plan:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`

## Current Scope

Task 0: reconcile spec, tooling, and proof helpers.

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
