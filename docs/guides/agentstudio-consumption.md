# AgentStudio Consumption Guide

`agentstudio-git` is the Git SDK boundary for AgentStudio. It exposes Git-shaped Swift contracts plus two implementation seams:

- `AgentStudioGitLocal`: libgit2-backed local repository operations for worktrees, status, branches, diffs, trees, and content.
- `AgentStudioGitRemote`: system-Git-backed remote/auth operations for clone, fetch, push, and remote reference discovery.

AgentStudio should import the narrowest product it needs:

- Use `AgentStudioGitContracts` for shared payloads, protocol declarations, fakes, and adapter tests that do not need an implementation.
- Use `AgentStudioGitLocal` for fast local worktree/status/diff/content adapters.
- Use `AgentStudioGitRemote` only where AgentStudio intentionally wants the user's configured `git`, credential helpers, SSH agent, certificates, and Git config.
- Use `AgentStudioGit` only when a caller needs both local and remote implementations.

## Artifact Modes

Local development uses the generated XCFramework path:

```swift
.binaryTarget(
    name: "CLibGit2Local",
    path: "Artifacts/CLibGit2Local.xcframework"
)
```

Release consumption uses an HTTPS binary target with a checksum:

```bash
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" \
AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-compute-checksum>" \
swift package dump-package
```

The release zip is created with:

```bash
AGENTSTUDIO_GIT_CREATE_LIBGIT2_ZIP=1 mise run build-libgit2
```

Publish both:

- `Artifacts/CLibGit2Local.xcframework.zip`
- `Artifacts/CLibGit2Local.xcframework.zip.checksum`

SwiftPM requires HTTPS for URL binary targets. Local `file://` URL binary targets are rejected, so the package keeps a local path mode for development and an explicit HTTPS/checksum mode for release manifest proof.

## Remote/Auth Policy

Remote/auth work is intentionally system-Git-backed. The SDK does not store credentials and does not implement a custom credential vault. `SystemGitRemoteClient.Configuration` owns:

- trusted executable selection
- inherited environment policy
- prompt policy
- protocol allowlist
- operation timeout
- additional trusted environment values

Defaults inherit the user's environment, strip Git tracing variables, set `LC_ALL=C`, suppress terminal prompts with `GIT_TERMINAL_PROMPT=0`, disable Git/SSH askpass helpers, enable SSH batch mode, enforce the configured timeout, and allow HTTPS plus SSH. Interactive prompting is a trusted opt-in for a caller that owns UI or terminal behavior.

## AgentStudio Adapter Boundary

AgentStudio should keep app-owned concepts outside this package:

- Bridge DTOs and review package builders
- checkpoint resolution and checkpoint metadata
- atoms, stores, persistence, UI, and command routing
- forge APIs

The replacement order is:

1. Add `agentstudio-git` through the proven SwiftPM path.
2. Replace the existing shell-backed `GitWorkingTreeStatusProvider` implementation behind the current seam.
3. Add a Bridge adapter backed by `AgentStudioGitLocalClient`.
4. Keep checkpoint-to-Git endpoint composition in AgentStudio.

## Required Proof Before Consuming

Run these gates before AgentStudio pins or updates this SDK:

```bash
mise run check
swift test --sanitize address
swift test --sanitize thread
bash scripts/verify-package-consumer.sh
```

The consumer verifier builds a scratch SwiftPM package that imports all public products: `AgentStudioGit`, `AgentStudioGitContracts`, `AgentStudioGitLocal`, and `AgentStudioGitRemote`. It also evaluates the HTTPS/checksum release-manifest mode. A real hosted artifact URL is still required before claiming an actual remote artifact download proof.

For live remote/auth proof, run:

```bash
AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE=1 \
AGENTSTUDIO_GIT_LIVE_REMOTE_URL="<https-or-ssh-remote>" \
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```
