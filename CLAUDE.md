# agentstudio-git

Swift Git data plane for AgentStudio.

This package owns Git access and Git-shaped contracts only. Keep AgentStudio app, Bridge UI, atoms, stores, and persistence concepts outside this repo.

## Working Agreement

Start from evidence: read code, run focused commands, and consult references before changing behavior. Do not guess library APIs, libgit2 behavior, Swift concurrency semantics, or AgentStudio integration boundaries.

When implementation surprises the plan, stop expanding code and update the mental model with evidence first. Keep changes scoped to this Git package unless the user explicitly asks to wire AgentStudio.

## Rules

@.cursor/rules/swift-rules.mdc

## Commands

```bash
mise run format
mise run lint
mise run build
mise run test
mise run check
```

Use `mise run check` before claiming the repo is complete or ready to consume.

## Key Patterns

- Use Swift 6.2 and Swift Testing.
- Keep blocking Git and filesystem work off the main actor.
- Prefer actors for repository backends, mutable caches, and libgit2 resource lifetimes.
- Use `@concurrent nonisolated` helpers for blocking I/O that must leave an actor executor.
- Keep public payloads `Codable`, `Sendable`, and explicitly discriminated for bridge/package boundaries.
- Use Unix millisecond timestamps for Swift/TypeScript parity.
- Use Git compatibility fixtures to compare package behavior against controlled real Git repositories. This is a test strategy, not a product architecture.

## Constraints

- Do not add app-specific imports from AgentStudio.
- Do not add UI, persistence, or Bridge review models here; map to those in AgentStudio.
- Do not add `Any`, force unwraps, force casts, `DispatchQueue.main.async`, Combine, or NotificationCenter-based coordination.
- Do not add compatibility shims or duplicate provider contracts. Cut over deliberately when interfaces change.
- Do not add wall-clock sleeps in tests. Wait on exact events or inject clocks.
- Do not add files over 600 lines without a clear split plan; over 900 lines is a refactoring prompt.

## Testing Pyramid

Most coverage should be unit tests over value models, path rules, command/response encoding, error mapping, and pure diff/status classification.

Integration tests use temporary real Git repositories with scrubbed test Git config. They may call system `git` to create fixture states and expected behavior. Production local status/diff/content/worktree reads must be backed by the SDK local engine, not shell parsing.

End-to-end tests belong in AgentStudio after this package is wired through an app provider seam. This repo should keep e2e coverage minimal unless it owns a runnable CLI or fixture harness.

Every test should use Swift Testing (`@Suite`, `@Test`, `#expect`) and Arrange / Act / Assert structure. XCTest is not used here unless a future Apple API requires it.

## Definition of Done

- Requirements are implemented in this package without leaking AgentStudio app concerns.
- `mise run lint` passes with zero SwiftLint violations and `swift-format` clean.
- `mise run test` passes and reports the test count.
- `mise run build` passes.
- Public payload changes have Codable round-trip tests and, when relevant, fixture parity tests.
- Git behavior changes have compatibility integration tests before replacing shell behavior in AgentStudio.
