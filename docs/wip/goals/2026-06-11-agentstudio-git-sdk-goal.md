# AgentStudio Git SDK Goal

Date: 2026-06-11

## Objective

Fully implement, test, review, and prove `agentstudio-git` as the Git SDK boundary AgentStudio needs.

The SDK must provide:

- fast local repository, worktree, status, diff, tree, and content operations through libgit2
- safe worktree create, validate, prune, and remove operations for main and linked worktrees
- remote/auth operations through the user's existing system `git` client so HTTPS and SSH auth work with the user's configured credential helpers, SSH agent, certificates, prompts, and Git config
- public contracts that AgentStudio can consume without importing Bridge DTOs, atoms, stores, UI, or persistence

Use TDD throughout: write or update the failing test first, implement the behavior, then prove the test and the relevant broader gate green before advancing.

## Required Reading

Primary plan/spec/review artifacts:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/plan-reviews/2026-06-11-agentstudio-git-sdk-plan-review.md`

Repo source artifacts:

- `AGENTS.md`
- `CLAUDE.md`
- `Package.swift`
- `.mise.toml`
- `Sources/AgentStudioGit/AgentStudioGit.swift`
- `Tests/AgentStudioGitTests/AgentStudioGitTests.swift`

AgentStudio consumer seams to read and prove against:

- `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingTreeStatusProvider.swift`
- `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewSourceProvider.swift`
- `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPackageBuilder.swift`
- `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeContentStore.swift`
- `/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start/Sources/AgentStudio/Features/Bridge/Models/ReviewFoundation/`

External references:

- libgit2 threading docs
- libgit2 worktree/status/diff/index/object/error docs
- Git worktree docs
- Git credentials docs
- Git environment-variable docs
- SwiftPM binary target and package-consumer docs

## Scope Boundary

Allowed write scope:

- `agentstudio-git` production code, tests, scripts, CI, package manifest, docs, and proof artifacts
- AgentStudio read-only inspection and compile/proof harnesses only where required to prove compatibility

Non-goals:

- do not move Bridge DTOs, checkpoint ownership, review package building, atoms, stores, UI, persistence, or app routing into `agentstudio-git`
- do not add forge/GitHub API ownership to this SDK
- do not create a custom credential vault or token store
- do not use system `git` as the hidden implementation for fast local status/diff/content/worktree reads
- do not claim completion from mirrored compatibility structs alone

## Required Behavior

- Split the package into contracts, local libgit2, remote system-Git, and convenience surfaces as the plan requires.
- Public contracts must be Codable where required and must have raw-value, round-trip, negative decode, and redaction tests.
- Repository identity must handle symlinks, main worktrees, linked worktrees, `.git` files, common git dirs, and display-name collisions.
- Local operations must use libgit2 for status, branch, refs, diffs, trees, blobs, content hashes, binary detection, and worktree operations.
- Worktree mutation must protect main worktrees, dirty worktrees, untracked files, locks, stale metadata, symlink escapes, and partial failures.
- Read-only local operations must not mutate the actual main or linked worktree index. Prove by resolving the real index path and comparing strong content identity before and after.
- Remote/auth operations must use system `git` with trusted client configuration for executable, environment, prompt policy, protocol policy, timeouts, and redaction.
- Public errors and values must not expose credential-bearing URLs, raw argv, raw stderr, tokens, private key paths, or sensitive environment values.
- Packaging must produce a libgit2 artifact that can be imported by Swift, verified for headers/modulemap/linking, and consumed by a clean downstream SwiftPM package.
- AgentStudio compatibility must be proven against the actual status and Bridge seams, including handle-based Bridge content loading.

## Required Proof Artifacts

Create or update these artifacts before claiming completion:

- updated source spec if implementation changes the contract
- updated implementation plan checkboxes/status
- `scripts/run-swift-test-filter.sh` or equivalent zero-test-failing filtered-test runner
- libgit2 build and verification scripts
- CI workflow for package checks
- artifact provenance/checksum record
- downstream SwiftPM consumer proof
- AgentStudio adapter compile proof
- fake system-Git remote/auth proof
- opt-in live remote/auth smoke status, including whether it ran or why it was skipped
- sanitizer proof with honest scope
- final proof report under `docs/wip/` with commit SHA, commands, exit codes, test counts, filtered gate counts, libgit2 commit, artifact checksum, downstream consumer result, AgentStudio compatibility result, remote/auth smoke status, known limitations, and review findings/resolution

## Proof Gates

Required local gates:

- `mise run format`
- `mise run lint`
- `mise run check`
- `swift test`
- guarded filtered test suites for each implemented public area
- integration fixture suite for status, diff, tree, content, worktree, and remote/auth behavior
- ASan and TSan lanes with explicitly documented sanitizer scope
- clean checkout package resolve/build
- downstream SwiftPM consumer resolve/build
- actual AgentStudio compatibility compile proof
- implementation-review-swarm after substantial implementation

Required behavioral proof:

- status covers clean, modified, staged+modified, untracked, ignored, binary, rename, deleted, added, ahead/behind, detached HEAD, unborn HEAD, origin present, origin absent, and origin lookup failure
- worktree proof covers main, linked, symlink, stale metadata, locked, dirty, staged, untracked, force, create existing branch, create new branch, detached add, prune, and remove
- Bridge proof covers endpoint comparison, tree reads, item descriptors, stable file IDs, content hashes, binary metadata, and content loading by handle
- remote/auth proof covers clone, fetch, push, remoteReferences, HTTPS credential helper compatibility, SSH agent compatibility, prompt policy, protocol allowlist, environment policy, timeout, and redaction

## Stop Condition

The goal is complete only when:

- every requirement in this goal and the active plan has current evidence
- all required source, test, script, CI, package, docs, and proof artifacts exist
- all scoped proof gates pass, or any external blocker is documented and accepted
- the SDK can be consumed from a clean downstream SwiftPM client
- AgentStudio compatibility is proven against actual consumer seams
- local libgit2 operations and system Git HTTPS/SSH auth behavior are proven with recorded commands and outputs
- implementation review findings are resolved or explicitly accepted

## Blocked Condition

Treat as blocked only when the same external blocker repeats under the Codex host blocked-state rules and meaningful progress is impossible without user input or an external state change.

Examples:

- unavailable required credentials for a live remote smoke after fake-git and local proof are complete
- upstream libgit2 or SwiftPM behavior prevents the selected packaging strategy and no safe alternative can be chosen without changing the plan
- AgentStudio consumer seam changes underneath the SDK and the compatibility target must be reconverged

## Checkpoint Rhythm

After every major plan task:

- update the plan checkbox/status
- update the proof artifact with commands, outputs, and counts
- run the relevant proof layer before advancing
- report changed files and exact validation evidence
- stop and reconverge if reality breaks the plan's model

## Next Workflow

Next workflow owner: `shravan-dev-workflow:implementation-execute-plan`.

Reason: the plan has been reviewed and revised; execution should validate the plan against the current repo, then implement task-by-task with TDD, proof artifacts, and review gates.
