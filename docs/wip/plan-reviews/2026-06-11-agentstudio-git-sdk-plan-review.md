# AgentStudio Git SDK Plan Review

Date: 2026-06-11

Plan reviewed:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`

Verdict before edits: needs revision.

Verdict after edits: revised in place; ready for one focused re-review before implementation.

## Review Lanes

- Codex spec compliance lane
- Codex architecture assumptions lane
- Codex testability and validation lane
- Codex security and reliability lane
- Codex execution scope lane
- Codex high-effort lane, `gpt-5.5`, `xhigh`
- Gemini external counsel through `agy`, `Gemini 3.1 Pro (High)`
- Claude external counsel through Claude Code, `fable`, `xhigh`

## Coverage

Reviewed against current package files:

- `Package.swift`
- `.mise.toml`
- `CLAUDE.md`
- `Sources/AgentStudioGit/AgentStudioGit.swift`
- `Tests/AgentStudioGitTests/AgentStudioGitTests.swift`
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`

Reviewed against AgentStudio consumer surfaces:

- `GitWorkingTreeStatusProvider`
- `BridgeReviewSourceProvider`
- `BridgeReviewPackageBuilder`
- `BridgeContentStore`
- Bridge review foundation models

Reviewed against external references:

- libgit2 threading documentation
- libgit2 worktree API
- libgit2 index write API
- Git worktree documentation
- Git credential helper documentation
- Git environment-variable documentation
- libgit2 build/link documentation

## Accepted Findings

Root cause: the previous plan still treated the package as a local libgit2 data plane, while the product requirement is a full AgentStudio Git SDK boundary.

Accepted fixes:

- Split the SDK into contracts, local libgit2, remote system-Git, and convenience products.
- Make public contract reshaping and value models one cutover task instead of a dependency-breaking half step.
- Keep Bridge DTOs, checkpoints, package building, atoms, stores, and UI in AgentStudio.
- Add actual AgentStudio adapter compile proof instead of mirror-only tests.
- Require handle-based Bridge content loading proof because AgentStudio requests content by handle.

Root cause: the packaging plan did not prove that a downstream SwiftPM consumer can actually import the libgit2-backed package.

Accepted fixes:

- Require headers, modulemap, link settings, artifact provenance, and a clean downstream consumer proof.
- Distinguish local editable artifact state from distributable release artifact state.
- Treat checksum-only local proof as insufficient.

Root cause: worktree mutation semantics were unsafe or ambiguous.

Accepted fixes:

- Separate stale metadata prune from user-visible worktree removal.
- Require dirty/untracked/locked/main-worktree refusal tests.
- Require explicit force semantics for destructive remove.
- Require validated worktree ID/path targeting.
- Require linked-worktree index path resolution and read-only index hash proof.

Root cause: remote/auth handling was under-modeled.

Accepted fixes:

- Use system Git for clone/fetch/push/remote-ref auth paths so existing user Git credentials and SSH setup remain authoritative.
- Move executable, environment, prompt, and protocol policy into trusted client configuration.
- Default remote operations to noninteractive mode.
- Redact credential-bearing URLs, argv, stderr, and environment values before public errors.
- Add fake-git tests plus opt-in live smoke status for credential-helper behavior.

Root cause: validation gates could false-green or overclaim.

Accepted fixes:

- Add a filtered SwiftPM test wrapper that fails on zero executed tests.
- Narrow sanitizer claims unless libgit2 itself is instrumented.
- Add proof docs with command outputs, test counts, artifact checksum, sanitizer scope, and known limitations.

## Plan Edits Applied

- Rewrote the plan to remove the older local-comparison/local-only framing.
- Added a security context and capability matrix.
- Added a requirements/proof matrix.
- Reordered tasks so spec/tooling, contracts, identity, packaging, runtime, worktree ops, status, Bridge data, remote auth, and CI land in dependency order.
- Added replan triggers for packaging failure, worktree safety gaps, index mutation, Bridge boundary drift, remote prompting, and parser instability.

## Verification

Commands run after the rewrite:

```bash
wc -l docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md
rg -n "TODO|TBD|placeholder|similar to above|appropriate|-Xswiftc -sanitize|swift test --filter GitWorktreeIntegrationTests|swift test --filter GitStatusIntegrationTests|swift test --filter BridgeReviewSourceCompatibilityTests|swift test --filter SystemGitRemoteClientTests" docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md || true
git diff --check -- docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md
```

Results:

- Plan length: 925 lines.
- Stale-term scan only matched intentional spec-verification commands in the plan.
- `git diff --check` passed with no whitespace errors.

No package tests were run because this was a plan-review/documentation revision, not source implementation.
