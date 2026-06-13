# 2026-06-13 AgentStudio Git Release Artifact Workflow Plan

## Goal

Make `agentstudio-git` publish its libgit2 SwiftPM binary artifact through a first-party GitHub Release workflow, so downstream consumers can pin the package without knowing local artifact paths or environment-variable plumbing.

## Current Model

- `scripts/build-libgit2-xcframework.sh` owns the reproducible local XCFramework build and optional `.zip` plus `.checksum` output.
- `.github/workflows/libgit2-artifact.yml` currently builds the zip and uploads it as a temporary Actions artifact only.
- `Package.swift` already defaults to a hosted HTTPS binary target and keeps local path mode behind `AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT=1`.
- `scripts/verify-hosted-libgit2-artifact.sh` already proves a public hosted artifact by building a scratch SwiftPM consumer against an override URL and checksum.

## Target Model

```text
tagged/manual workflow dispatch
        |
        v
build-libgit2-xcframework.sh
        |
        v
Artifacts/CLibGit2Local.xcframework.zip
Artifacts/CLibGit2Local.xcframework.zip.checksum
        |
        v
GitHub Release asset under ShravanSunder/agentstudio-git
        |
        v
verify-hosted-libgit2-artifact.sh against the release download URL
        |
        v
Package.swift PR updates the embedded URL/checksum
        |
        v
source package tag consumed by AgentStudio
```

## Implementation Tasks

### Task 1: Pin Release Workflow Contract In Tests

Add packaging-suite tests that assert the workflow:

- declares `contents: write` because GitHub Release asset publication needs repository content permissions
- accepts an explicit `artifact_tag` dispatch input
- rejects accidental mutable overwrites by failing when the release already exists
- rejects a pre-existing remote tag without a release, so `gh release create --target` cannot bind assets to the wrong commit
- uses `GH_TOKEN: ${{ github.token }}` for `gh release`
- creates a GitHub Release with `gh release create`
- publishes both the zip and checksum files
- computes the release download URL from `${{ github.repository }}` and the dispatch tag
- runs `scripts/verify-hosted-libgit2-artifact.sh` against the created release asset with bounded retry
- deletes the created release and tag if hosted verification fails after publication
- keeps `actions/upload-artifact@v4` as a diagnostic artifact, not as the distribution mechanism

Expected failing command before implementation:

```bash
bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
```

### Task 2: Upgrade The Existing Workflow

Update `.github/workflows/libgit2-artifact.yml` in place:

```yaml
name: libgit2 Artifact Release

on:
  workflow_dispatch:
    inputs:
      artifact_tag:
        required: true
        type: string
      prerelease:
        required: false
        default: true
        type: boolean

permissions:
  contents: write
```

The workflow should:

- build and verify libgit2 exactly as today
- compute checksum and release URL in one metadata step
- require artifact tags to start with `libgit2-`
- fail if the release already exists, preserving release immutability
- fail if the remote tag already exists without a release, preserving artifact-to-commit provenance
- create a public GitHub prerelease by default because SwiftPM cannot consume a private/draft asset without custom auth
- upload the zip and checksum as release assets
- run hosted-artifact verification against the release URL and checksum
- clean up the release and tag if post-publication verification fails

### Task 3: Keep Consumer Compatibility On The Hosted Artifact

The AgentStudio compatibility harness should resolve libgit2 headers from the
SwiftPM-extracted hosted artifact by default. It may use repo-local
`Artifacts/CLibGit2Local.xcframework` headers only when
`AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT=1` is explicitly set.

Add focused tests that prove both paths:

- hosted artifact headers are preferred in normal consumer mode
- local artifact headers are used only in explicit local artifact mode
- unrelated headers under `.build/artifacts` are ignored

### Task 4: Document The Two-Stage Package Update

Update `docs/guides/agentstudio-consumption.md` to make the release sequence explicit:

1. Run the GitHub Actions libgit2 artifact release workflow.
2. Confirm hosted-artifact verification passes in the workflow.
3. Update `Package.swift` embedded URL/checksum in a normal PR.
4. Run package gates and AgentStudio compatibility.
5. Tag the source package version that AgentStudio consumes.

This keeps binary-artifact publication separate from source-package tagging while still producing a clean downstream dependency.

### Task 5: Verify

Run:

```bash
bash scripts/run-swift-test-filter.sh LibGit2PackagingScriptTests
bash scripts/run-swift-test-filter.sh GitWorkingTreeStatusCompatibilityTests
mise run format
mise run lint
mise run test
bash scripts/verify-package-consumer.sh
mise run check
mise run test-asan
mise run test-tsan
```

If a repo-wide gate fails outside the packaging surface, stop and report scoped proof plus the unrelated blocker before editing other layers.
