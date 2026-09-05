# AgentStudioGit

Swift Git data-plane package for AgentStudio.

This repo is intended to own high-performance Git access behind typed Swift contracts. AgentStudio should consume this package through narrow provider seams instead of spreading shell parsing or Bridge-specific models through Git code.

## Current Scope

- SwiftPM library product: `AgentStudioGit`
- Swift 6.2 package baseline
- Swift Testing test suite
- AgentStudio-style `swift-format`, SwiftLint, and `mise` tasks
- Initial typed command, response, status, diff-target, and worktree descriptors

## Commands

```bash
mise run build
mise run lint
mise run test
mise run check
```

The package checks are independently runnable and do not locate or invoke an
AgentStudio checkout. The external real-consumer gate is explicit:

```bash
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio \
  mise run verify-agentstudio-compatibility
```

That gate refuses any dirty SDK `Package.swift` or `Sources/` candidate, requires
both the AgentStudio manifest declaration and `Package.resolved` pin to equal
the SDK checkout's current `HEAD`, runs AgentStudio's ordinary
`mise run test:swift` task over the real compiled SDK consumers, and verifies
the resolved pin again after the task. Success also requires the App task to
report a positive Swift Testing terminal count, so an empty or unmatched filter
fails closed. The gate does not recurse into this package's test task or copy
AgentStudio declarations into a synthetic build.

The compatibility obligations remain attached to their real owners:

- `GitStatusIntegrationTests` proves SDK status behavior against real Git
  repositories; `AgentStudioGitWorkingTreeStatusProviderTests` proves the App's
  status, branch, origin, upstream-optional, detached/unborn, failure, timeout,
  cancellation, and capacity mappings.
- `BridgeGitReviewSourceProviderTests` and
  `BridgeGitReviewContributionSourceProviderTests` prove the production Bridge
  adapter's diff, tree, content-handle, fallback, contribution, and real dirty
  worktree behavior.
- `BridgeGitReviewBoundaryTests`, `BridgeReviewGitRefreshScopeTests`,
  `BridgeReviewDeltaBuilderTests`,
  `WorktreeAnnotationGitSourceMaterialProviderTests`, and
  `WorktreeAnnotationSourceCaptureReviewProportionalTests` prove the remaining
  SDK-backed Bridge boundaries, refresh/delta behavior, and annotation reads.
- Package consumption and hosted/local libgit2 header and artifact behavior
  remain owned by the independent package-consumer and artifact verification
  gates; they are not App compatibility assertions.

## Architecture Boundary

This package owns Git data access and Git-shaped value types. It should not import AgentStudio app modules, Bridge UI contracts, atoms, stores, or persistence systems.

Blocking Git and filesystem work belongs off the main actor. Public async APIs should be safe to call from AgentStudio actors without doing blocking work on the caller executor.
