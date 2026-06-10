# AgentStudioGit Libgit2 Data Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `agentstudio-git` into a real SwiftPM libgit2 data-plane package that AgentStudio can import for local worktree, status, branch, diff, and content facts.

**Architecture:** `AgentStudioGit` exposes method-oriented Swift APIs and immutable Git-shaped values. libgit2 is pinned and built as a local-only static XCFramework; mutating operations go through a repository writer actor keyed by canonical common git directory, while read operations use isolated per-operation libgit2 sessions. AgentStudio owns Bridge/app adapters; this package does not own Bridge DTOs or app persistence.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftLint, swift-format, mise, libgit2 1.9.x, CMake, GitHub Actions, ASan/TSan sanitizer test lanes.

---

## File Structure

Create or modify these files:

- `Package.swift` — SwiftPM products/targets, `AgentStudioGit`, `CLibGit2Local`, binary artifact target when available.
- `.mise.toml` — pinned tools and build/test/lint/artifact tasks.
- `.swiftlint.yml` — remove copied AgentStudio app comments; enforce package-specific safety rules.
- `.github/workflows/check.yml` — CI for build, lint, tests, sanitizer lanes.
- `scripts/build-libgit2-xcframework.sh` — reproducibly build local-only static libgit2 XCFramework.
- `scripts/verify-libgit2-artifact.sh` — verify artifact exists, architectures, checksum.
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md` — design source of truth.
- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md` — this plan.
- `Sources/AgentStudioGit/AgentStudioGit.swift` — temporary barrel exports only after split.
- `Sources/AgentStudioGit/Models/GitStatusModels.swift` — two-axis status values.
- `Sources/AgentStudioGit/Models/GitWorktreeModels.swift` — worktree snapshots and requests.
- `Sources/AgentStudioGit/Models/GitBranchModels.swift` — branch/head snapshots.
- `Sources/AgentStudioGit/Models/GitDiffModels.swift` — diff requests and snapshots.
- `Sources/AgentStudioGit/Models/GitContentModels.swift` — blob/tree content payloads.
- `Sources/AgentStudioGit/Errors/GitDataPlaneError.swift` — typed error taxonomy.
- `Sources/AgentStudioGit/Client/AgentStudioGitClient.swift` — public protocol.
- `Sources/AgentStudioGit/Client/LibGit2AgentStudioGitClient.swift` — concrete client.
- `Sources/AgentStudioGit/Runtime/LibGit2Runtime.swift` — init/shutdown and version validation.
- `Sources/AgentStudioGit/Runtime/LibGit2ErrorCapture.swift` — same-frame error capture.
- `Sources/AgentStudioGit/Runtime/LibGit2RepositorySession.swift` — non-Sendable pointer owner.
- `Sources/AgentStudioGit/Runtime/GitRepositoryWriterActor.swift` — serialized writer lane.
- `Sources/AgentStudioGit/Runtime/GitRepositoryIdentity.swift` — canonical path and common-git-dir identity.
- `Sources/AgentStudioGit/Readers/GitWorktreeReader.swift` — read worktree facts.
- `Sources/AgentStudioGit/Readers/GitStatusReader.swift` — read status facts without index writes.
- `Sources/AgentStudioGit/Readers/GitBranchReader.swift` — read branch facts.
- `Sources/AgentStudioGit/Readers/GitDiffReader.swift` — read diffs.
- `Sources/AgentStudioGit/Readers/GitContentReader.swift` — read tree/blob content.
- `Sources/AgentStudioGit/Writers/GitWorktreeWriter.swift` — create/prune/lock/unlock worktrees.
- `Tests/AgentStudioGitTests/Contracts/*.swift` — payload and decoding tests.
- `Tests/AgentStudioGitTests/Fixtures/*.swift` — temp repo fixture builders.
- `Tests/AgentStudioGitTests/Integration/*.swift` — real repository behavior tests.
- `Tests/AgentStudioGitTests/Runtime/*.swift` — runtime/error/lifecycle tests.

## Task 1: Repo Standards And CI Baseline

**Files:**
- Modify: `.mise.toml`
- Modify: `.swiftlint.yml`
- Create: `.github/workflows/check.yml`
- Modify: `.claude/settings.local.json`

- [ ] **Step 1: Pin tools in mise**

Replace `.mise.toml` with:

```toml
[tools]
swiftlint = "0.63.3"
swiftformat = "602.0.0"
cmake = "latest"

[env]
PROJECT_ROOT = "{{config_root}}"

[tasks.format]
description = "Format Swift sources with swift-format"
run = """
swift-format format --in-place --recursive Sources/ Tests/
echo "Formatted all Swift sources"
"""

[tasks.lint]
description = "Lint Swift sources with swift-format and SwiftLint"
run = """
#!/usr/bin/env bash
set -euo pipefail
echo "--- swift-format lint ---"
swift-format lint --recursive Sources/ Tests/ 2>&1 && echo "swift-format: OK" || { echo "swift-format: FAIL"; exit 1; }
echo "--- swiftlint ---"
swiftlint lint --strict 2>&1 && echo "swiftlint: OK" || { echo "swiftlint: FAIL"; exit 1; }
"""

[tasks.build]
description = "Build the Swift package"
run = "swift build"

[tasks.test]
description = "Run Swift Testing suites"
run = "swift test"

[tasks.test-asan]
description = "Run tests with Address Sanitizer"
run = "swift test -Xswiftc -sanitize=address"

[tasks.test-tsan]
description = "Run tests with Thread Sanitizer"
run = "swift test -Xswiftc -sanitize=thread"

[tasks.check]
description = "Run build, lint, and tests"
depends = ["build", "lint", "test"]
```

- [ ] **Step 2: Run format and lint**

Run: `mise run format && mise run lint`

Expected: `swift-format: OK` and `swiftlint: OK`.

- [ ] **Step 3: Retarget SwiftLint thresholds**

In `.swiftlint.yml`, remove comments that mention AgentStudio app files, `LUNA-325`, and `Sources/AgentStudio/Legacy`. Set:

```yaml
file_length:
  warning: 600
  error: 900

type_body_length:
  warning: 400
  error: 700

function_body_length:
  warning: 80
  error: 160
```

Also remove `force_cast`, `force_try`, and `force_unwrapping` from `disabled_rules`.

- [ ] **Step 4: Add CI**

Create `.github/workflows/check.yml`:

```yaml
name: check

on:
  pull_request:
  push:
    branches: [main]

jobs:
  swift:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - run: mise run check
      - run: mise run test-asan
      - run: mise run test-tsan
```

- [ ] **Step 5: Verify**

Run: `mise run check`

Expected: build passes, lint passes, current tests pass.

- [ ] **Step 6: Commit**

```bash
git add .mise.toml .swiftlint.yml .github/workflows/check.yml .claude/settings.local.json
git commit -m "chore: add package validation baseline"
```

## Task 2: Replace Placeholder Contracts

**Files:**
- Delete content from: `Sources/AgentStudioGit/AgentStudioGit.swift`
- Create: `Sources/AgentStudioGit/Errors/GitDataPlaneError.swift`
- Create: `Sources/AgentStudioGit/Models/GitStatusModels.swift`
- Create: `Sources/AgentStudioGit/Models/GitWorktreeModels.swift`
- Create: `Sources/AgentStudioGit/Models/GitBranchModels.swift`
- Create: `Sources/AgentStudioGit/Models/GitDiffModels.swift`
- Create: `Sources/AgentStudioGit/Models/GitContentModels.swift`
- Create: `Sources/AgentStudioGit/Client/AgentStudioGitClient.swift`
- Test: `Tests/AgentStudioGitTests/Contracts/GitContractRoundTripTests.swift`

- [ ] **Step 1: Write failing contract tests**

Create `Tests/AgentStudioGitTests/Contracts/GitContractRoundTripTests.swift`:

```swift
import Foundation
import Testing

@testable import AgentStudioGit

@Suite("AgentStudioGit contract round trips")
struct GitContractRoundTripTests {
    @Test("status supports staged and unstaged modifications at the same path")
    func statusEntrySupportsTwoAxisState() throws {
        let entry = GitStatusEntry(
            path: "Sources/App.swift",
            previousPath: nil,
            indexState: .modified,
            worktreeState: .modified,
            ignored: false,
            untracked: false
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(GitStatusEntry.self, from: data)

        #expect(decoded == entry)
        #expect(decoded.indexState == .modified)
        #expect(decoded.worktreeState == .modified)
    }

    @Test("worktree snapshot carries stable identity and canonical paths")
    func worktreeSnapshotRoundTrip() throws {
        let snapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "repo:/private/tmp/repo|worktree:/private/tmp/repo"),
            name: "main",
            repositoryPath: URL(fileURLWithPath: "/private/tmp/repo"),
            commonGitDirectoryPath: URL(fileURLWithPath: "/private/tmp/repo/.git"),
            worktreePath: URL(fileURLWithPath: "/private/tmp/repo"),
            branchName: "main",
            headCommitSha: "abc123",
            isMainWorktree: true,
            isBareRepository: false,
            lock: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(GitWorktreeSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    @Test("large Unix millisecond timestamps remain Int64 values")
    func generatedTimestampUsesInt64() throws {
        let snapshot = GitStatusSnapshot(
            worktreePath: URL(fileURLWithPath: "/private/tmp/repo"),
            generatedAtUnixMilliseconds: 9_007_199_254_740_993,
            head: nil,
            entries: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(GitStatusSnapshot.self, from: data)

        #expect(decoded.generatedAtUnixMilliseconds == 9_007_199_254_740_993)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter GitContractRoundTripTests`

Expected: compile fails because `GitStatusEntry`, `GitWorktreeID`, and related types do not exist.

- [ ] **Step 3: Add typed error model**

Create `Sources/AgentStudioGit/Errors/GitDataPlaneError.swift`:

```swift
import Foundation

public enum GitDataPlaneError: Error, Codable, Equatable, Sendable {
    case repositoryNotFound(path: String)
    case worktreeNotFound(name: String, repositoryPath: String)
    case locked(operation: String, path: String?, message: String)
    case modifiedConcurrently(operation: String, message: String)
    case unsupported(operation: String, reason: String)
    case libgit2(code: Int32, klass: Int32, message: String)
}
```

- [ ] **Step 4: Add status models**

Create `Sources/AgentStudioGit/Models/GitStatusModels.swift`:

```swift
import Foundation

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

    public init(
        path: String,
        previousPath: String?,
        indexState: GitStatusState?,
        worktreeState: GitStatusState?,
        ignored: Bool,
        untracked: Bool
    ) {
        self.path = path
        self.previousPath = previousPath
        self.indexState = indexState
        self.worktreeState = worktreeState
        self.ignored = ignored
        self.untracked = untracked
    }
}

public struct GitStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public let worktreePath: URL
    public let generatedAtUnixMilliseconds: Int64
    public let head: GitHeadSnapshot?
    public let entries: [GitStatusEntry]

    public init(
        worktreePath: URL,
        generatedAtUnixMilliseconds: Int64,
        head: GitHeadSnapshot?,
        entries: [GitStatusEntry]
    ) {
        self.worktreePath = worktreePath
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.head = head
        self.entries = entries
    }
}

public struct GitStatusOptions: Codable, Equatable, Hashable, Sendable {
    public let includeIgnored: Bool
    public let includeUntracked: Bool

    public static let `default` = Self(includeIgnored: false, includeUntracked: true)

    public init(includeIgnored: Bool, includeUntracked: Bool) {
        self.includeIgnored = includeIgnored
        self.includeUntracked = includeUntracked
    }
}
```

- [ ] **Step 5: Add branch/head models**

Create `Sources/AgentStudioGit/Models/GitBranchModels.swift`:

```swift
import Foundation

public struct GitHeadSnapshot: Codable, Equatable, Hashable, Sendable {
    public let commitSha: String?
    public let branchName: String?
    public let isDetached: Bool

    public init(commitSha: String?, branchName: String?, isDetached: Bool) {
        self.commitSha = commitSha
        self.branchName = branchName
        self.isDetached = isDetached
    }
}

public struct GitBranchSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let commitSha: String?
    public let isHead: Bool
    public let isRemote: Bool

    public init(name: String, commitSha: String?, isHead: Bool, isRemote: Bool) {
        self.name = name
        self.commitSha = commitSha
        self.isHead = isHead
        self.isRemote = isRemote
    }
}
```

- [ ] **Step 6: Add worktree models**

Create `Sources/AgentStudioGit/Models/GitWorktreeModels.swift`:

```swift
import Foundation

public struct GitWorktreeID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct GitWorktreeLock: Codable, Equatable, Hashable, Sendable {
    public let reason: String?

    public init(reason: String?) {
        self.reason = reason
    }
}

public struct GitWorktreeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: GitWorktreeID
    public let name: String
    public let repositoryPath: URL
    public let commonGitDirectoryPath: URL
    public let worktreePath: URL
    public let branchName: String?
    public let headCommitSha: String?
    public let isMainWorktree: Bool
    public let isBareRepository: Bool
    public let lock: GitWorktreeLock?

    public init(
        id: GitWorktreeID,
        name: String,
        repositoryPath: URL,
        commonGitDirectoryPath: URL,
        worktreePath: URL,
        branchName: String?,
        headCommitSha: String?,
        isMainWorktree: Bool,
        isBareRepository: Bool,
        lock: GitWorktreeLock?
    ) {
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.commonGitDirectoryPath = commonGitDirectoryPath
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.headCommitSha = headCommitSha
        self.isMainWorktree = isMainWorktree
        self.isBareRepository = isBareRepository
        self.lock = lock
    }
}

public struct GitCreateWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let name: String
    public let worktreePath: URL
    public let referenceName: String?

    public init(repositoryPath: URL, name: String, worktreePath: URL, referenceName: String?) {
        self.repositoryPath = repositoryPath
        self.name = name
        self.worktreePath = worktreePath
        self.referenceName = referenceName
    }
}

public struct GitRemoveWorktreeRequest: Codable, Equatable, Hashable, Sendable {
    public let repositoryPath: URL
    public let name: String
    public let removeWorkingDirectory: Bool

    public init(repositoryPath: URL, name: String, removeWorkingDirectory: Bool) {
        self.repositoryPath = repositoryPath
        self.name = name
        self.removeWorkingDirectory = removeWorkingDirectory
    }
}

public struct GitWorktreeRemovalResult: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let prunedAdministrativeData: Bool
    public let removedWorkingDirectory: Bool

    public init(name: String, prunedAdministrativeData: Bool, removedWorkingDirectory: Bool) {
        self.name = name
        self.prunedAdministrativeData = prunedAdministrativeData
        self.removedWorkingDirectory = removedWorkingDirectory
    }
}
```

- [ ] **Step 7: Add diff and content models**

Create `Sources/AgentStudioGit/Models/GitDiffModels.swift` and `Sources/AgentStudioGit/Models/GitContentModels.swift` with minimal values:

```swift
import Foundation

public enum GitDiffTarget: Codable, Equatable, Hashable, Sendable {
    case head
    case index
    case workingTree
    case commit(String)
}

public struct GitDiffRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreePath: URL
    public let base: GitDiffTarget
    public let compare: GitDiffTarget

    public init(worktreePath: URL, base: GitDiffTarget, compare: GitDiffTarget) {
        self.worktreePath = worktreePath
        self.base = base
        self.compare = compare
    }
}

public struct GitDiffFile: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let previousPath: String?
    public let isBinary: Bool
    public let additions: Int
    public let deletions: Int

    public init(path: String, previousPath: String?, isBinary: Bool, additions: Int, deletions: Int) {
        self.path = path
        self.previousPath = previousPath
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
    }
}

public struct GitDiffSnapshot: Codable, Equatable, Hashable, Sendable {
    public let generatedAtUnixMilliseconds: Int64
    public let files: [GitDiffFile]

    public init(generatedAtUnixMilliseconds: Int64, files: [GitDiffFile]) {
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.files = files
    }
}
```

```swift
import Foundation

public struct GitContentRequest: Codable, Equatable, Hashable, Sendable {
    public let worktreePath: URL
    public let path: String
    public let target: GitDiffTarget

    public init(worktreePath: URL, path: String, target: GitDiffTarget) {
        self.worktreePath = worktreePath
        self.path = path
        self.target = target
    }
}

public struct GitContentPayload: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let bytes: Data
    public let isBinary: Bool

    public init(path: String, bytes: Data, isBinary: Bool) {
        self.path = path
        self.bytes = bytes
        self.isBinary = isBinary
    }
}
```

- [ ] **Step 8: Add client protocol and remove envelopes**

Create `Sources/AgentStudioGit/Client/AgentStudioGitClient.swift`:

```swift
import Foundation

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

Replace `Sources/AgentStudioGit/AgentStudioGit.swift` with:

```swift
// Public symbols live in focused files under Sources/AgentStudioGit/.
```

- [ ] **Step 9: Run tests**

Run: `swift test --filter GitContractRoundTripTests`

Expected: tests pass.

- [ ] **Step 10: Commit**

```bash
git add Sources Tests
git commit -m "feat: define Git data-plane contracts"
```

## Task 3: Contract Test Base

**Files:**
- Create: `Tests/AgentStudioGitTests/Contracts/GitWireEnumTests.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitErrorContractTests.swift`
- Create: `Tests/AgentStudioGitTests/Contracts/GitDiffTargetCodableTests.swift`

- [ ] **Step 1: Add enum raw value tests**

Create `Tests/AgentStudioGitTests/Contracts/GitWireEnumTests.swift`:

```swift
import Testing

@testable import AgentStudioGit

@Suite("Git wire enum raw values")
struct GitWireEnumTests {
    @Test("status state raw values are stable")
    func statusStateRawValuesAreStable() {
        #expect(GitStatusState.added.rawValue == "added")
        #expect(GitStatusState.deleted.rawValue == "deleted")
        #expect(GitStatusState.modified.rawValue == "modified")
        #expect(GitStatusState.renamed.rawValue == "renamed")
        #expect(GitStatusState.copied.rawValue == "copied")
        #expect(GitStatusState.typeChanged.rawValue == "typeChanged")
        #expect(GitStatusState.unmerged.rawValue == "unmerged")
    }
}
```

- [ ] **Step 2: Add typed error tests**

Create `Tests/AgentStudioGitTests/Contracts/GitErrorContractTests.swift`:

```swift
import Testing

@testable import AgentStudioGit

@Suite("Git data-plane errors")
struct GitErrorContractTests {
    @Test("locked error round trips with operation and path")
    func lockedErrorRoundTrip() throws {
        let error = GitDataPlaneError.locked(
            operation: "createWorktree",
            path: "/private/tmp/repo/.git/index.lock",
            message: "Lock file prevented operation"
        )

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(GitDataPlaneError.self, from: data)

        #expect(decoded == error)
    }
}
```

- [ ] **Step 3: Add diff target tests**

Create `Tests/AgentStudioGitTests/Contracts/GitDiffTargetCodableTests.swift`:

```swift
import Testing

@testable import AgentStudioGit

@Suite("Git diff target coding")
struct GitDiffTargetCodableTests {
    @Test("commit diff target requires a sha payload")
    func commitDiffTargetRoundTrips() throws {
        let target = GitDiffTarget.commit("abc123")

        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(GitDiffTarget.self, from: data)

        #expect(decoded == target)
    }
}
```

- [ ] **Step 4: Run contract tests**

Run: `swift test --filter Contracts`

Expected: all contract tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/AgentStudioGitTests/Contracts
git commit -m "test: cover Git data-plane contracts"
```

## Task 4: Libgit2 Artifact Build

**Files:**
- Modify: `Package.swift`
- Create: `scripts/build-libgit2-xcframework.sh`
- Create: `scripts/verify-libgit2-artifact.sh`
- Modify: `.gitignore`
- Modify: `.mise.toml`
- Create: `ThirdPartyNotices/libgit2.md`

- [ ] **Step 1: Add artifact scripts**

Create `scripts/build-libgit2-xcframework.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBGIT2_DIR="$ROOT/vendor/libgit2"
BUILD_ROOT="$ROOT/.build/libgit2"
ARTIFACT_DIR="$ROOT/Artifacts"
FRAMEWORK_PATH="$ARTIFACT_DIR/CLibGit2Local.xcframework"

if [ ! -f "$LIBGIT2_DIR/CMakeLists.txt" ]; then
  echo "Missing vendor/libgit2. Add libgit2 before building the artifact." >&2
  exit 1
fi

rm -rf "$BUILD_ROOT" "$FRAMEWORK_PATH"
mkdir -p "$BUILD_ROOT/arm64" "$BUILD_ROOT/x86_64" "$ARTIFACT_DIR"

build_arch() {
  local arch="$1"
  local build_dir="$BUILD_ROOT/$arch"
  cmake -S "$LIBGIT2_DIR" -B "$build_dir" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CLAR=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=OFF \
    -DUSE_GSSAPI=OFF
  cmake --build "$build_dir" --config Release
}

build_arch arm64
build_arch x86_64

xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/arm64/libgit2.a" -headers "$LIBGIT2_DIR/include" \
  -library "$BUILD_ROOT/x86_64/libgit2.a" -headers "$LIBGIT2_DIR/include" \
  -output "$FRAMEWORK_PATH"

echo "Built $FRAMEWORK_PATH"
```

- [ ] **Step 2: Add verify script**

Create `scripts/verify-libgit2-artifact.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_PATH="$ROOT/Artifacts/CLibGit2Local.xcframework"

test -d "$FRAMEWORK_PATH" || { echo "Missing $FRAMEWORK_PATH" >&2; exit 1; }
find "$FRAMEWORK_PATH" -name libgit2.a -print | grep -q libgit2.a
echo "CLibGit2Local artifact exists"
```

- [ ] **Step 3: Update mise artifact tasks**

Add to `.mise.toml`:

```toml
[tasks.build-libgit2]
description = "Build local-only static libgit2 XCFramework"
run = "bash scripts/build-libgit2-xcframework.sh"

[tasks.verify-libgit2]
description = "Verify local libgit2 XCFramework"
run = "bash scripts/verify-libgit2-artifact.sh"
```

- [ ] **Step 4: Add artifact ignore policy**

Add to `.gitignore`:

```gitignore
Artifacts/*.xcframework
```

- [ ] **Step 5: Add license notice**

Create `ThirdPartyNotices/libgit2.md`:

```markdown
# libgit2

AgentStudioGit links libgit2 under the libgit2 GPLv2 with Linking Exception license.

Source: https://github.com/libgit2/libgit2
License: https://github.com/libgit2/libgit2/blob/main/COPYING

Network transports are disabled in the initial local-only build.
```

- [ ] **Step 6: Verify scripts parse**

Run: `bash -n scripts/build-libgit2-xcframework.sh scripts/verify-libgit2-artifact.sh`

Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .mise.toml .gitignore scripts ThirdPartyNotices
git commit -m "build: add libgit2 artifact pipeline"
```

## Task 5: Libgit2 Runtime And Error Capture

**Files:**
- Create: `Sources/AgentStudioGit/Runtime/LibGit2Runtime.swift`
- Create: `Sources/AgentStudioGit/Runtime/LibGit2ErrorCapture.swift`
- Create: `Sources/AgentStudioGit/Runtime/LibGit2RepositorySession.swift`
- Test: `Tests/AgentStudioGitTests/Runtime/LibGit2RuntimeTests.swift`

- [ ] **Step 1: Write runtime tests**

Create `Tests/AgentStudioGitTests/Runtime/LibGit2RuntimeTests.swift`:

```swift
import Testing

@testable import AgentStudioGit

@Suite("LibGit2 runtime")
struct LibGit2RuntimeTests {
    @Test("runtime can start and stop")
    func runtimeStartStop() throws {
        let runtime = LibGit2Runtime()

        try runtime.start()
        runtime.shutdown()

        #expect(true)
    }
}
```

- [ ] **Step 2: Run failing test**

Run: `swift test --filter LibGit2RuntimeTests`

Expected: compile fails because `LibGit2Runtime` does not exist.

- [ ] **Step 3: Implement runtime**

Create `Sources/AgentStudioGit/Runtime/LibGit2Runtime.swift`:

```swift
import Foundation

public final class LibGit2Runtime: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    public init() {}

    public func start() throws(GitDataPlaneError) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        started = false
    }
}
```

After Task 4 adds `CLibGit2Local`, replace `LibGit2Runtime.swift` with:

```swift
import CLibGit2Local
import Foundation

public final class LibGit2Runtime: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0

    public init() {}

    public func start() throws(GitDataPlaneError) {
        lock.lock()
        defer { lock.unlock() }

        let result = git_libgit2_init()
        if result < 0 {
            throw LibGit2ErrorCapture.capture(operation: "git_libgit2_init", result: result)
        }
        startCount += 1
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }

        guard startCount > 0 else { return }
        git_libgit2_shutdown()
        startCount -= 1
    }
}
```

- [ ] **Step 4: Run test**

Run: `swift test --filter LibGit2RuntimeTests`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentStudioGit/Runtime Tests/AgentStudioGitTests/Runtime
git commit -m "feat: add libgit2 runtime boundary"
```

## Task 6: Git Compatibility Fixture Harness

**Files:**
- Create: `Tests/AgentStudioGitTests/Fixtures/TemporaryGitRepository.swift`
- Create: `Tests/AgentStudioGitTests/Fixtures/GitProcess.swift`
- Create: `Tests/AgentStudioGitTests/Integration/GitStatusCompatibilityTests.swift`

- [ ] **Step 1: Add temporary repository helper**

Create `Tests/AgentStudioGitTests/Fixtures/TemporaryGitRepository.swift`:

```swift
import Foundation

struct TemporaryGitRepository {
    let rootURL: URL

    static func create() throws -> Self {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try GitProcess.run(["init"], at: url)
        try GitProcess.run(["config", "user.email", "agentstudio@example.com"], at: url)
        try GitProcess.run(["config", "user.name", "AgentStudio Test"], at: url)
        return Self(rootURL: url)
    }

    func writeFile(_ path: String, contents: String) throws {
        let fileURL = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)?.write(to: fileURL)
    }
}
```

- [ ] **Step 2: Add Git process test helper**

Create `Tests/AgentStudioGitTests/Fixtures/GitProcess.swift`:

```swift
import Foundation

enum GitProcess {
    static func run(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw GitDataPlaneError.unsupported(operation: "git \(arguments.joined(separator: " "))", reason: "process failed")
        }
    }
}
```

- [ ] **Step 3: Add compatibility test skeleton**

Create `Tests/AgentStudioGitTests/Integration/GitStatusCompatibilityTests.swift`:

```swift
import Testing

@testable import AgentStudioGit

@Suite("Git status compatibility")
struct GitStatusCompatibilityTests {
    @Test("fixture can create a real repository")
    func fixtureCreatesRepository() throws {
        let repository = try TemporaryGitRepository.create()

        #expect(FileManager.default.fileExists(atPath: repository.rootURL.appendingPathComponent(".git").path))
    }
}
```

- [ ] **Step 4: Run integration fixture test**

Run: `swift test --filter GitStatusCompatibilityTests`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/AgentStudioGitTests/Fixtures Tests/AgentStudioGitTests/Integration
git commit -m "test: add Git compatibility fixtures"
```

## Task 7: First Libgit2 Reader Slice

**Files:**
- Create: `Sources/AgentStudioGit/Readers/GitStatusReader.swift`
- Create: `Sources/AgentStudioGit/Client/LibGit2AgentStudioGitClient.swift`
- Test: `Tests/AgentStudioGitTests/Integration/GitStatusCompatibilityTests.swift`

- [ ] **Step 1: Add failing status test**

Append to `GitStatusCompatibilityTests`:

```swift
@Test("status reports staged and unstaged modification on same path")
func statusReportsStagedAndUnstagedModification() async throws {
    let repository = try TemporaryGitRepository.create()
    try repository.writeFile("file.txt", contents: "one\n")
    try GitProcess.run(["add", "file.txt"], at: repository.rootURL)
    try GitProcess.run(["commit", "-m", "initial"], at: repository.rootURL)
    try repository.writeFile("file.txt", contents: "two\n")
    try GitProcess.run(["add", "file.txt"], at: repository.rootURL)
    try repository.writeFile("file.txt", contents: "three\n")

    let client = LibGit2AgentStudioGitClient()
    let status = try await client.status(for: repository.rootURL, options: .default)

    let entry = try #require(status.entries.first { $0.path == "file.txt" })
    #expect(entry.indexState == .modified)
    #expect(entry.worktreeState == .modified)
}
```

- [ ] **Step 2: Run failing test**

Run: `swift test --filter statusReportsStagedAndUnstagedModification`

Expected: compile fails because `LibGit2AgentStudioGitClient` does not exist.

- [ ] **Step 3: Implement unsupported client scaffold**

Create `Sources/AgentStudioGit/Client/LibGit2AgentStudioGitClient.swift`:

```swift
import Foundation

public actor LibGit2AgentStudioGitClient: AgentStudioGitClient {
    public init() {}

    public func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        throw .unsupported(operation: "worktrees", reason: "pending libgit2 worktree reader slice")
    }

    public func validateWorktree(repositoryPath: URL, name: String) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(operation: "validateWorktree", reason: "pending libgit2 worktree reader slice")
    }

    public func status(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError) -> GitStatusSnapshot {
        throw .unsupported(operation: "status", reason: "pending libgit2 status reader slice")
    }

    public func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw .unsupported(operation: "branches", reason: "pending libgit2 branch reader slice")
    }

    public func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(operation: "createWorktree", reason: "pending libgit2 worktree writer slice")
    }

    public func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeRemovalResult {
        throw .unsupported(operation: "removeWorktree", reason: "pending libgit2 worktree writer slice")
    }

    public func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        throw .unsupported(operation: "diff", reason: "pending libgit2 diff reader slice")
    }

    public func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        throw .unsupported(operation: "content", reason: "pending libgit2 content reader slice")
    }
}
```

- [ ] **Step 4: Implement libgit2-backed status reader**

Replace the `status` unsupported branch with libgit2-backed status reading. Requirements:

- open repository from `worktreePath`
- do not set any status option that updates the index
- map staged flags to `indexState`
- map worktree flags to `worktreeState`
- return `GitStatusSnapshot`
- every libgit2 pointer uses `defer git_*_free(pointer)`
- every negative return captures `git_error_last()` before returning

- [ ] **Step 5: Run status test**

Run: `swift test --filter statusReportsStagedAndUnstagedModification`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentStudioGit/Client Sources/AgentStudioGit/Readers Tests/AgentStudioGitTests/Integration
git commit -m "feat: read worktree status with libgit2"
```

## Task 8: Worktree List And Mutation Slice

**Files:**
- Create: `Sources/AgentStudioGit/Runtime/GitRepositoryWriterActor.swift`
- Create: `Sources/AgentStudioGit/Writers/GitWorktreeWriter.swift`
- Create: `Sources/AgentStudioGit/Readers/GitWorktreeReader.swift`
- Test: `Tests/AgentStudioGitTests/Integration/GitWorktreeCompatibilityTests.swift`

- [ ] **Step 1: Add worktree tests**

Create `Tests/AgentStudioGitTests/Integration/GitWorktreeCompatibilityTests.swift` with tests for:

- main worktree appears in output with `isMainWorktree == true`
- created linked worktree appears with stable ID
- locked worktree reports `GitWorktreeLock`
- locked worktree removal returns `GitDataPlaneError.locked`

- [ ] **Step 2: Implement writer actor**

Create `GitRepositoryWriterActor` keyed by canonical common git directory. Mutating methods call `GitWorktreeWriter`.

- [ ] **Step 3: Implement worktree list**

Use `git_worktree_list`, `git_worktree_lookup`, `git_worktree_name`, `git_worktree_path`, `git_worktree_is_locked`, and `git_worktree_open_from_repository`.

- [ ] **Step 4: Implement worktree create**

Use `git_worktree_add` with explicit options. Do not set `lock` unless request asks for a locked worktree in a later API revision.

- [ ] **Step 5: Implement worktree remove**

Use `git_worktree_prune`. Refuse locked worktrees by default. Do not remove working directory unless `removeWorkingDirectory == true`.

- [ ] **Step 6: Run tests**

Run: `swift test --filter GitWorktreeCompatibilityTests`

Expected: all worktree tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentStudioGit/Runtime Sources/AgentStudioGit/Readers Sources/AgentStudioGit/Writers Tests/AgentStudioGitTests/Integration
git commit -m "feat: manage local worktrees with libgit2"
```

## Task 9: Branch, Diff, And Content Readers

**Files:**
- Create: `Sources/AgentStudioGit/Readers/GitBranchReader.swift`
- Create: `Sources/AgentStudioGit/Readers/GitDiffReader.swift`
- Create: `Sources/AgentStudioGit/Readers/GitContentReader.swift`
- Test: `Tests/AgentStudioGitTests/Integration/GitDiffCompatibilityTests.swift`

- [ ] **Step 1: Add branch/diff/content tests**

Create tests for:

- branch list includes current local branch
- diff reports additions/deletions for modified text file
- diff marks binary file as binary
- content reads bytes for HEAD and working tree targets

- [ ] **Step 2: Implement branch reader**

Use libgit2 branch iteration and HEAD inspection.

- [ ] **Step 3: Implement diff reader**

Use libgit2 diff APIs without index-update flags. Put line stats and binary flags on `GitDiffFile`, not `GitStatusEntry`.

- [ ] **Step 4: Implement content reader**

Use tree/blob lookup for commit targets and filesystem read for working tree target.

- [ ] **Step 5: Run tests**

Run: `swift test --filter GitDiffCompatibilityTests`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentStudioGit/Readers Tests/AgentStudioGitTests/Integration
git commit -m "feat: read branches diffs and content with libgit2"
```

## Task 10: AgentStudio Adapter Plan Gate

**Files:**
- Create: `docs/specs/2026-06-10-agentstudio-integration-boundary.md`

- [ ] **Step 1: Write integration boundary note**

Create `docs/specs/2026-06-10-agentstudio-integration-boundary.md`:

```markdown
# AgentStudio Integration Boundary

AgentStudio consumes AgentStudioGit through adapters.

Adapters:

- `AgentStudioGitWorkingTreeStatusProvider` implements AgentStudio `GitWorkingTreeStatusProvider`.
- `BridgeGitReviewSourceProvider` maps Git-shaped package output into Bridge-owned review contracts.

AgentStudioGit does not import Bridge, AtomRegistry, persistence, AppKit, SwiftUI, Worktrunk, or pane runtime code.
```

- [ ] **Step 2: Commit**

```bash
git add docs/specs/2026-06-10-agentstudio-integration-boundary.md
git commit -m "docs: define AgentStudio adapter boundary"
```

## Task 11: Full Verification

**Files:**
- No source files.

- [ ] **Step 1: Run diff check**

Run: `git diff --check`

Expected: no output.

- [ ] **Step 2: Run validation**

Run: `mise run check`

Expected: build, lint, and tests pass.

- [ ] **Step 3: Run sanitizer lanes**

Run:

```bash
mise run test-asan
mise run test-tsan
```

Expected: both pass, or document an environment-specific sanitizer limitation with exact output.

- [ ] **Step 4: Verify public repo state**

Run:

```bash
git status --short --branch
gh repo view ShravanSunder/agentstudio-git --json url,visibility,defaultBranchRef
```

Expected: clean branch, public repo, default branch `main`.

## Self-Review Notes

- Spec coverage: packaging, auth, locking, actor/read model, public contracts, testing pyramid, AgentStudio boundary, and validation are all covered.
- Type consistency: public protocol and model names match the task snippets.
- Terminology: this plan uses “Git compatibility tests” for fixture behavior checks and does not use ambiguous test-architecture jargon.
