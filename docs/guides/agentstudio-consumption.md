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

Default downstream consumption uses the hosted HTTPS binary target embedded in
`Package.swift`. AgentStudio and other SwiftPM consumers should not need a
neighboring `Artifacts/` directory or artifact environment variables to resolve
the SDK.

Local artifact development is an explicit opt-in for rebuilding or inspecting
the generated XCFramework:

```bash
AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT=1 swift build
```

That opt-in switches the manifest to:

```swift
.binaryTarget(
    name: "CLibGit2Local",
    path: "Artifacts/CLibGit2Local.xcframework"
)
```

The hosted zip is created with:

```bash
AGENTSTUDIO_GIT_CREATE_LIBGIT2_ZIP=1 mise run build-libgit2
```

The distribution path is the `libgit2 Artifact Release` GitHub Actions
workflow. Dispatch it with an explicit immutable artifact tag, for example:

```bash
gh workflow run libgit2-artifact.yml \
  --repo ShravanSunder/agentstudio-git \
  -f artifact_tag=libgit2-1.9.4-agentstudio.1 \
  -f prerelease=true
```

The workflow publishes both release assets:

- `Artifacts/CLibGit2Local.xcframework.zip`
- `Artifacts/CLibGit2Local.xcframework.zip.checksum`

It also keeps a temporary Actions artifact for workflow diagnostics, but that
artifact is not a SwiftPM distribution surface. SwiftPM consumers should resolve
from the public GitHub Release URL:

```text
https://github.com/ShravanSunder/agentstudio-git/releases/download/<artifact-tag>/CLibGit2Local.xcframework.zip
```

SwiftPM requires HTTPS for URL binary targets. Local `file://` URL binary
targets are rejected, so the package defaults to the public HTTPS/checksum
artifact and keeps local path mode only for explicit development use.

To verify an alternate hosted artifact before changing the package default,
provide an override URL and checksum:

```bash
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" \
AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" \
bash scripts/verify-hosted-libgit2-artifact.sh
```

The hosted-artifact verifier builds and runs a scratch SwiftPM consumer that
imports `AgentStudioGitLocal` while the package manifest uses the configured
URL/checksum override. It does not run repo-local `mise` tasks inside the
consumer. It uses an isolated SwiftPM cache/scratch path so a pass requires
resolving the current hosted artifact, suppresses raw SwiftPM output so
configured URLs do not leak into proof logs, rejects loopback/private artifact
hosts, and asserts the pinned libgit2 version `1.9.4`.

## Updating The SwiftPM Package Artifact

Binary artifact publication and source package tagging are separate steps:

1. Dispatch the `libgit2 Artifact Release` workflow with a new immutable
   `libgit2-...` artifact tag.
2. Wait for the workflow's `Verify hosted release artifact` step to pass.
3. Update the embedded `hostedLibGit2BinaryURL` and
   `hostedLibGit2BinaryChecksum` constants in `Package.swift`.
4. Run the local package gates from this guide, including the consumer verifier
   and AgentStudio compatibility verifier.
5. Open and merge the package PR.
6. Tag the source package version that AgentStudio will pin.

Do not make AgentStudio CI provide `AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL` or
`AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM`. Those are verification and
development overrides. A released SDK version should be self-contained in
`Package.swift`.

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
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" bash scripts/verify-hosted-libgit2-artifact.sh
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio bash scripts/verify-agentstudio-compatibility.sh
```

The consumer verifier builds a scratch SwiftPM package with two consumers: one
imports only the `AgentStudioGit` umbrella product, and one imports all public
leaf products: `AgentStudioGitContracts`, `AgentStudioGitLocal`, and
`AgentStudioGitRemote`. It clears ambient artifact override variables and the
local-artifact opt-in so the proof exercises the default hosted artifact path,
then evaluates explicit URL/checksum override manifest shape.

The hosted-artifact verifier is the external gate for alternate hosted artifact
download proof. It requires a real public HTTPS URL and the matching SwiftPM
checksum, so it is not run by default CI.

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
