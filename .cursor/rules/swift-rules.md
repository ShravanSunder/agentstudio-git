---
alwaysApply: true
---
# Swift Package Rules

## Types

- **No `Any` type** — Always use explicit, narrow types or generics
- **Avoid force unwraps (`!`)** — Use `guard let`, `if let`, or nil coalescing (`??`)
- **Avoid force casts (`as!`)** — Use conditional casts (`as?`) with proper error handling
- **Prefer generics** — Use `<T>`, `<T: SomeProtocol>` for flexible, type-safe functions
- **Strict concurrency** — Enable strict concurrency checking, use `Sendable` where required
- For functions with >3 parameters, use a dedicated configuration struct
- Prefer descriptive generic names such as `TGitPayload`, not single-letter generics in public APIs

## Data Models

- **Codable for serialization** — Implement `Codable` for all data transfer types
- No persistence models in this package unless explicitly designed first
- **Value types by default** — Prefer `struct` over `class` unless reference semantics are needed
- **No force unwraps in models** — All optional properties must be safely unwrapped
- Prefer Unix millisecond timestamps at package boundaries for Swift/TypeScript parity

## Formatting

- Indent code with 4 spaces
- Follow `swift-format` configuration in `.swift-format`
- Maximum line length: 120 characters
- Use trailing closures for single-closure parameters

## Concurrency

- Keep Git and filesystem work off the main actor
- Prefer actors for repository backends and mutable caches
- Do not use `@MainActor` in this package unless a future design explicitly proves why Git code needs it
- Public async APIs must not perform blocking I/O on the caller executor
- Use `@concurrent nonisolated` helpers when blocking I/O must leave an actor executor

## Architecture

- **Protocol-oriented design** — Define narrow contracts with concrete value types
- **Dependency injection** — Inject dependencies through initializers
- **Error handling** — Use typed errors (`enum AppError: Error`) over generic `Error`
- Do not import AgentStudio app modules, Bridge UI contracts, atoms, stores, or persistence systems
- Keep Bridge review/checkpoint/collation models in AgentStudio; this package returns Git-shaped facts
- Do not add duplicate provider contracts for AgentStudio integration

## Testing

### Test Setup

- Test framework: **Swift Testing** (`import Testing`)
- Test location: `Tests/` directory following SPM convention
- Use `@Test` macro for test functions
- Use `@Suite` for test organization
- Use XCTest only if a future Apple API requires it

### Test Quality

- Follow Arrange / Act / Assert structure
- No wall-clock sleeps in tests; wait on exact events or inject clocks
- Keep tests minimal, valuable, and easy to maintain

### Testing Pyramid

- Most tests: unit tests for value models, path rules, command/response encoding, error mapping, and pure diff/status classification
- Some tests: integration tests with temporary Git repositories, checked against `git` CLI oracle behavior
- Few tests: e2e smoke only if this repo later owns a runnable CLI or fixture harness

## Documentation

- Skip return-type sections in docstrings when type annotations suffice
- Write concise, high-impact documentation that explains *why*, not just *what*

## Swift Commands

Do not run random commands for linting and testing. You MUST follow the ones below without any variations.

### Build & Test

- `mise run build` to build the project
- `mise run test` to run tests
- `mise run lint` to run linting

### SwiftLint

- `swiftlint lint --strict` to run linting

### swift-format

- `swift-format format --in-place --recursive Sources/ Tests/` to format code
