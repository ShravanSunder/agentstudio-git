# AgentStudio Git Tracked Paths Plan

## Steps

1. Add failing public contract tests for tracked-path payload encoding and stable wire enum values.
2. Add failing integration tests covering:
   - tracked files sorted by repository-relative path,
   - scoped exact path and directory-boundary filtering,
   - invalid absolute and `..` scopes rejected,
   - symlink and submodule/gitlink classification where fixture support allows,
   - linked worktree reads using the linked worktree's own index without mutating index bytes or lock sentinels,
   - conflict-stage entries excluded from returned entries while counted in `rawIndexEntryCount`.
3. Add `GitTrackedPathContracts.swift` to `AgentStudioGitContracts`.
4. Extend `AgentStudioGitLocalClient` with `trackedPaths(for worktreePath:options:)` and update protocol stubs in compatibility tests.
5. Add `LibGit2TrackedPathReader` using `git_repository_index`, `git_index_entrycount`, and `git_index_get_byindex`.
6. Wire `LibGit2AgentStudioGitLocalClient` to the reader.
7. Run focused tests, formatting, linting, full tests, build, and check.
8. If all relevant gates pass, commit only the scoped changed files.

## Proof Gates

- RED: focused contract/integration tests fail for missing tracked-path API.
- GREEN: focused tracked-path tests pass.
- Quality: `mise run format`, `mise run lint`.
- Repo health: `mise run test`, `mise run build`, `mise run check`.

## Risks

- Linked worktree correctness depends on opening the requested worktree before resolving the index.
- Conflict-stage coverage requires a real merge-conflict fixture; the test should assert omission from `entries` and raw index count.
- Submodule classification may require a local file-protocol fixture that avoids network and global Git config.
- `scopePath` is a public option boundary. Tight validation avoids accidental prefix matches and path escape semantics leaking to callers.
