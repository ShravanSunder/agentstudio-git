#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_test_arguments=()
if [ "$#" -gt 0 ]; then
  swift_test_arguments=("$@")
fi

suites=(
  GitWireEnumSnapshotTests
  GitBranchIntegrationContractTests
  GitBranchDeletionContractTests
  GitLockContractTests
  GitWorktreeRemovalContractTests
  GitPublicContractTests
  GitInvalidDecodeTests
  GitRedactionTests
  GitWorktreeForkContractTests
  LibGit2BlockingReadExecutorTests
  LibGit2RuntimeTests
  LibGit2RepositorySessionTests
  LibGit2ErrorCaptureTests
  GitLockDiagnosticTests
  GitLockResidueObserverTests
  GitRepositoryIdentityTests
  GitRepositoryWriterRegistryTests
  GitRepositoryWriterLaneTests
  WorktreeForkPolicyTests
  SparseCheckoutMatcherTests
  WorktreeForkCleanEntryAdoptionTests
  GitProcessRunnerTests
  SystemGitRemoteClientTests
  GitRemoteOutputParserTests
  LibGit2PackagingScriptTests
  SourceStructureTests
  GitStatusIntegrationTests
  GitExactCleanBaselineIntegrationTests
  GitImplicitStatusDependencyTests
  GitStagedFetchIntegrationTests
  GitIgnoreIntegrationTests
  GitTrackedPathIntegrationTests
  GitWorktreeIntegrationTests
  GitWorktreeRemovalIntegrationTests
  GitFetchIntegrationTests
  GitLockIntegrationTests
  GitLockRemoteIntegrationTests
  GitWorktreeForkIntegrationTests
  GitWorktreeForkLockIntegrationTests
  GitWorktreeForkIndexLockIntegrationTests
  GitWorktreeForkPackedReferenceLockIntegrationTests
  GitWorktreeForkStorageIntegrationTests
  GitWorktreeForkRollbackIntegrationTests
  GitWorktreeForkTopologyIntegrationTests
  GitWorktreeForkEligibilityIntegrationTests
  GitWorktreeForkChangesOnlyIntegrationTests
  GitWorktreeForkCancellationIntegrationTests
  GitWorktreeForkTrackedStateIntegrationTests
  GitWorktreeForkChangesOnlyFilterIntegrationTests
  GitWorktreeForkCleanAdoptionIntegrationTests
  GitCommitRangeCountIntegrationTests
  GitBranchIntegrationIntegrationTests
  GitBranchIntegrationHistoryIntegrationTests
  GitBranchIntegrationBatchIntegrationTests
  GitBranchIntegrationDeltaTests
  GitBranchIntegrationSquashEdgeIntegrationTests
  GitBranchIntegrationRealSquashIntegrationTests
  GitBranchIntegrationEntryDeltaIntegrationTests
  GitBranchIntegrationPathDeltaIntegrationTests
  GitBranchIntegrationReadOnlyIntegrationTests
  GitBranchDeletionIntegrationTests
  GitBranchDeletionRaceIntegrationTests
  GitDiffImpactSummaryIntegrationTests
  GitReviewDataIntegrationTests
  GitLargeFilePointerReviewIntegrationTests
  AgentStudioCompatibilityGateTests
)

for suite in "${suites[@]}"; do
  echo "--- swift test filter: ${suite} ---"
  if [ "${#swift_test_arguments[@]}" -gt 0 ]; then
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "${swift_test_arguments[@]}" "$suite"
  else
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" "$suite"
  fi
done
