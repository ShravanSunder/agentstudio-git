# AgentStudio Git SDK Final Proof

Date: 2026-06-12

Goal:

- `docs/wip/goals/2026-06-11-agentstudio-git-sdk-goal.md`

Plan/spec/review:

- `docs/superpowers/plans/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/specs/2026-06-10-agentstudio-git-libgit2-data-plane.md`
- `docs/wip/plan-reviews/2026-06-11-agentstudio-git-sdk-plan-review.md`

## Scope Proven

- local libgit2 repository, worktree, status, diff, tree, and content operations
- safe worktree create, validate, prune, lock/unlock, and remove behavior
- system Git remote/auth operations through the user's configured Git client
- public Codable contracts, wire enum snapshots, negative decode tests, and redaction tests
- downstream SwiftPM package consumption
- AgentStudio working-tree status and Bridge review-source compatibility harnesses
- hosted public SwiftPM binary-target download/link proof for `CLibGit2Local.xcframework.zip`

## External Values Policy

Configured smoke remotes and hosted artifact URL values are intentionally omitted from proof artifacts. The public artifact directory contains only `CLibGit2Local.xcframework.zip`, its checksum, and a README.

## Local Gates

```bash
mise run check
```

Exit code: 0

Result:

- rebuilt and verified `Artifacts/CLibGit2Local.xcframework`
- `swift build` completed
- `swift-format lint` passed
- SwiftLint found 0 violations in 54 files
- guarded Swift Testing suite list passed: 18 suites, 107 reported tests
- live remote auth smoke was skipped in the default test lane because it is explicitly opt in

```bash
mise run test-asan
```

Exit code: 0

Result:

- guarded Swift Testing suite list passed under AddressSanitizer wrapper scope
- sanitizer scope covers Swift wrapper/process/libgit2 call sites over the prebuilt libgit2 artifact; it is not a claim that libgit2 itself was rebuilt with ASan

```bash
mise run test-tsan
```

Exit code: 0

Result:

- guarded Swift Testing suite list passed under ThreadSanitizer wrapper scope
- sanitizer scope covers Swift wrapper/process/libgit2 call sites over the prebuilt libgit2 artifact; it is not a claim that libgit2 itself was rebuilt with TSan

```bash
bash scripts/verify-package-consumer.sh
```

Exit code: 0

Result:

- clean downstream SwiftPM consumer built and ran
- umbrella and leaf consumers reported libgit2 `1.9.4` and `SystemGitRemoteClient true`

```bash
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/Users/shravansunder/Documents/dev/project-dev/agent-studio.bridge-start bash scripts/verify-agentstudio-compatibility.sh
```

Exit code: 0

Result:

- `Git working tree status compatibility`: 5 tests passed
- `Bridge review source compatibility`: 2 tests passed
- total verifier result: `Test run with 7 tests in 2 suites passed`

## Live Remote/Auth Gate

```bash
AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL=<https-smoke-remote> AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL=<ssh-smoke-remote> bash scripts/verify-live-remote-auth.sh
```

Exit code: 0

Result:

- HTTPS credential-helper lane: `Test run with 6 tests in 1 suite passed`
- SSH-agent lane: `Test run with 6 tests in 1 suite passed`
- verifier output did not print configured remote URL values

```bash
git ls-remote --heads <https-smoke-remote> 'refs/heads/agentstudio-git-live-smoke/*'
git ls-remote --heads <ssh-smoke-remote> 'refs/heads/agentstudio-git-live-smoke/*'
```

Exit code: 0 for both commands.

Result:

- no leftover `refs/heads/agentstudio-git-live-smoke/*` refs were reported for either disposable smoke remote

## Hosted Artifact Gate

Public artifact branch commit: `aa2c8b9`

Artifact path shape:

- `agentstudio-git/libgit2/2026-06-12/CLibGit2Local.xcframework.zip`

SwiftPM checksum:

```text
33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d
```

```bash
curl -L --fail --max-time 60 --output /tmp/agentstudio-git-libgit2-raw-probe.zip <public-raw-artifact-url>
```

Exit code: 0

Result:

- downloaded the public 1.8 MB `CLibGit2Local.xcframework.zip` artifact
- SHA-256 matched the SwiftPM checksum above

```bash
AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL=<public-raw-artifact-url> AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM=33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d bash scripts/verify-hosted-libgit2-artifact.sh
```

Exit code: 0

Result:

- verifier used isolated SwiftPM cache/scratch paths
- verifier output did not print the configured artifact URL
- verifier reported `hosted libgit2 artifact linked successfully`

## Review Follow-Up Gate

Implementation review found and the current tree fixes:

- plain HTTPS process-failure remotes are fully redacted
- process-output capture is pipe-bounded instead of temp-file polling
- process-group cleanup no longer sends SIGKILL after the process has already exited during the grace wait
- quoted `GIT_SSH_COMMAND` arguments are preserved while forcing noninteractive `BatchMode=yes`
- hosted-artifact preflight rejects literal private/local IPs and non-allowlisted hostnames that resolve to private/local IPs; known public GitHub artifact hosts are allowlisted to avoid local DNS hangs

Focused proof after these fixes:

- `bash scripts/run-swift-test-filter.sh GitRedactionTests`: exit 0; `Test run with 5 tests in 1 suite passed`
- `bash scripts/run-swift-test-filter.sh GitProcessRunnerTests`: exit 0; `Test run with 14 tests in 1 suite passed`
- `bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests`: exit 0; `Test run with 16 tests in 1 suite passed`

## Privacy Audit

```bash
rg -n "<real experiment repo URL patterns>" docs Sources Tests scripts Package.swift .github || true
```

Exit code: 0

Result:

- no real experiment repo URLs were present in repo docs, sources, tests, scripts, package manifest, or GitHub workflow files

## Current Completion Status

- local SDK gates: green
- sanitizer gates: green
- downstream SwiftPM consumer proof: green
- AgentStudio seam compatibility proof: green
- live HTTPS remote-auth proof: green
- live SSH remote-auth proof: green
- hosted libgit2 artifact proof: green
- goal proof gates are current and green
