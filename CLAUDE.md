# agentstudio-git

Swift Git data plane for AgentStudio.

This package owns Git access and Git-shaped contracts only. Keep AgentStudio app, Bridge UI, atoms, stores, and persistence concepts outside this repo.

## Rules

@.cursor/rules/swift-rules.mdc


## Key Patterns

- Use Swift 6.2 and Swift Testing.
- Keep blocking Git and filesystem work off the main actor.
- Prefer actors for repository backends, mutable caches, and libgit2 resource lifetimes.
- Keep public payloads `Codable`, `Sendable`, and explicitly discriminated for bridge/package boundaries.
- Use Unix millisecond timestamps for Swift/TypeScript parity.

## Constraints

- Run `mise run lint` and `mise run test` before claiming work is complete.
- Do not add app-specific imports from AgentStudio.
- Do not add UI, persistence, or Bridge review models here; map to those in AgentStudio.
