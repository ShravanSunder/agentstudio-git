# AgentStudio Git Tracked Paths

## Outcome

AgentStudioGit exposes a first-party tracked-path enumeration API for callers that need a complete manifest of tracked repository-relative paths. The local implementation reads the requested worktree's libgit2 index directly and does not shell out to `git` in production.

## Contract

- `GitTrackedPathsOptions(scopePath: String? = nil)` optionally restricts results to one repository-relative POSIX path.
- `GitTrackedPathKind` is a stable wire enum with `file`, `symlink`, and `submodule`.
- `submodule` means a gitlink index mode (`0160000`), not submodule working-tree inspection.
- `GitTrackedPathEntry(path:kind:)` carries one repo-relative POSIX path.
- `GitTrackedPathsSnapshot(entries:rawIndexEntryCount:)` returns sorted entries and the raw `git_index_entrycount` observed before scope or stage filtering.
- `AgentStudioGitLocalClient.trackedPaths(for worktreePath:options:)` reads tracked paths for the requested worktree path.

## Scope Semantics

- `nil`, `""`, and trimmed-empty slash-only strings mean the whole worktree.
- Non-empty scope values must be repository-relative POSIX paths.
- Absolute paths and `..` segments are rejected with `GitDataPlaneError.pathEscapesRepository`.
- Surrounding slashes are trimmed after absolute-path rejection, so `Sources/` is equivalent to `Sources`.
- Matching is exact path or directory boundary only: `Sources` matches `Sources/App.swift`, but not `Sources2/App.swift`.

## Libgit2 Rules

- Open the requested worktree with the same `git_repository_open_ext` pattern used by `LibGit2StatusReader`.
- Resolve the worktree-specific index through `git_repository_index`, validating it through `GitIndexPathResolver.indexPath(repository:)`.
- Iterate `git_index_entrycount` and `git_index_get_byindex`.
- Include only stage-0 index entries in returned entries. A conflicted path with only stages 1/2/3 is omitted from `entries`; those rows still contribute to `rawIndexEntryCount`.
- Classify index modes as `0160000` submodule/gitlink, `0120000` symlink, and file otherwise.
- Return repository-relative POSIX paths sorted by path.

## Boundaries

- Production code must not use the Git CLI.
- Tests may use `GitFixtureRepository` and `GitProcess` to create fixture states and compare behavior.
- AgentStudio BridgeViewer models stay outside this package; this API returns Git-shaped facts only.

## Proof Gates

- Contract round-trip and wire enum snapshot tests.
- Integration coverage for sorted tracked files, exact scope boundaries, invalid scope rejection, symlink/submodule classification, linked-worktree index selection and immutability, and conflict-stage omission plus raw index count metadata.
- `mise run format`
- `mise run lint`
- `mise run test`
- `mise run build`
- `mise run check`
