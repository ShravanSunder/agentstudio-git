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

## Architecture Boundary

This package owns Git data access and Git-shaped value types. It should not import AgentStudio app modules, Bridge UI contracts, atoms, stores, or persistence systems.

Blocking Git and filesystem work belongs off the main actor. Public async APIs should be safe to call from AgentStudio actors without doing blocking work on the caller executor.
