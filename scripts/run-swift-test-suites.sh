#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_test_arguments=()
if [ "$#" -gt 0 ]; then
  swift_test_arguments=("$@")
fi

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
  SourceStructureTests
  GitStatusIntegrationTests
  GitTrackedPathIntegrationTests
  GitWorktreeIntegrationTests
  GitReviewDataIntegrationTests
  GitWorkingTreeStatusCompatibilityTests
  BridgeReviewSourceCompatibilityTests
)

for suite in "${suites[@]}"; do
  echo "--- swift test filter: ${suite} ---"
  if [ "${#swift_test_arguments[@]}" -gt 0 ]; then
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "${swift_test_arguments[@]}" "$suite"
  else
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "$suite"
  fi
done
