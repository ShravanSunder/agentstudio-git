#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

suites=(
  GitWireEnumSnapshotTests
  GitPublicContractTests
  GitInvalidDecodeTests
  GitRedactionTests
  LibGit2RuntimeTests
  LibGit2RepositorySessionTests
  LibGit2ErrorCaptureTests
  GitRepositoryIdentityTests
  GitRepositoryWriterRegistryTests
  GitProcessRunnerTests
  SystemGitRemoteClientTests
  GitRemoteOutputParserTests
  LibGit2PackagingScriptTests
  GitStatusIntegrationTests
  GitWorktreeIntegrationTests
  GitReviewDataIntegrationTests
  GitWorkingTreeStatusCompatibilityTests
  BridgeReviewSourceCompatibilityTests
)

for suite in "${suites[@]}"; do
  echo "--- swift test filter: ${suite} ---"
  bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "$suite"
done
