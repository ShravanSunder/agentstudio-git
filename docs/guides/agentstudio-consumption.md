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
AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1 \
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
The manifest only enters URL-binary-target mode when `AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1`; ambient URL/checksum variables alone are ignored so ordinary local builds cannot silently switch to a remote artifact.

After publishing the release zip to a public HTTPS location, prove that SwiftPM can download and link the hosted artifact:

```bash
AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1 \
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" \
AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" \
bash scripts/verify-hosted-libgit2-artifact.sh
```

The hosted-artifact verifier builds and runs a scratch SwiftPM consumer that imports `AgentStudioGitLocal` while the package manifest is forced into URL-binary-target mode. It does not run repo-local `mise` tasks inside the consumer. It uses an isolated SwiftPM cache/scratch path so a pass requires resolving the current hosted artifact, suppresses raw SwiftPM output so configured URLs do not leak into proof logs, rejects loopback/private artifact hosts, and asserts the pinned libgit2 version `1.9.4`.

## Remote/Auth Policy

Remote/auth work is intentionally system-Git-backed. The SDK does not store credentials and does not implement a custom credential vault. `SystemGitRemoteClient.Configuration` owns:

- trusted executable selection
- inherited environment policy
- prompt policy
- protocol allowlist
- operation timeout
- additional trusted environment values

Defaults inherit the user's environment, strip Git tracing variables, set `LC_ALL=C`, suppress terminal prompts with `GIT_TERMINAL_PROMPT=0`, disable Git/SSH askpass helpers, normalize SSH batch mode to `-oBatchMode=yes`, enforce the configured timeout, and allow HTTPS plus SSH. Timeout cleanup kills the spawned process group so Git SSH/helper descendants are covered. Interactive prompting is a trusted opt-in for a caller that owns UI or terminal behavior.

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
mise run test-asan
mise run test-tsan
bash scripts/verify-package-consumer.sh
AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL=1 AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" bash scripts/verify-hosted-libgit2-artifact.sh
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio bash scripts/verify-agentstudio-compatibility.sh
```

The consumer verifier builds a scratch SwiftPM package with two consumers: one imports only the `AgentStudioGit` umbrella product, and one imports all public leaf products: `AgentStudioGitContracts`, `AgentStudioGitLocal`, and `AgentStudioGitRemote`. It clears ambient release-artifact environment variables during local-path proof, then evaluates the HTTPS/checksum release-manifest mode. A real hosted artifact URL is still required before claiming an actual remote artifact download proof.

The hosted-artifact verifier is the external gate for that final download proof. It requires a real public HTTPS URL and the matching SwiftPM checksum, so it is not run by default CI.

The AgentStudio compatibility verifier requires `AGENTSTUDIO_GIT_AGENTSTUDIO_PATH` because this repository cannot prove the app seams from an isolated checkout.

For live remote/auth proof, run:

```bash
AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE=1 \
AGENTSTUDIO_GIT_LIVE_REMOTE_URL="<https-or-ssh-remote>" \
scripts/run-swift-test-filter.sh SystemGitRemoteClientTests
```

That lightweight smoke proves remote reference discovery. The full live auth gate requires both HTTPS and SSH writeable disposable remotes:

```bash
AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL="<https-writeable-remote>" \
AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL="<ssh-writeable-remote>" \
bash scripts/verify-live-remote-auth.sh
```

The full gate uses `SystemGitRemoteClient` for clone, fetch, push, and remote reference discovery. It creates and deletes temporary refs under `refs/heads/agentstudio-git-live-smoke/`; use a disposable smoke repository, not an important application repo.
The verifier enforces lane-specific URL shapes (`https://` for the HTTPS lane and SSH URL/scp syntax for the SSH lane), clears the older read-only live-smoke environment while it runs, and does not print configured remote URL values.
