#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTSTUDIO_GIT_REMOTE_URL="https://github.com/ShravanSunder/agentstudio-git.git"
AGENTSTUDIO_CONSUMER_SUITE_FILTER="AgentStudioGitWorkingTreeStatusProviderTests|BridgeGitReviewSourceProviderTests|BridgeGitReviewContributionSourceProviderTests|BridgeGitReviewBoundaryTests|BridgeReviewGitRefreshScopeTests|BridgeReviewDeltaBuilderTests|WorktreeAnnotationGitSourceMaterialProviderTests|WorktreeAnnotationSourceCaptureReviewProportionalTests"

if [ -z "${AGENTSTUDIO_GIT_AGENTSTUDIO_PATH:-}" ]; then
  cat >&2 <<'EOF'
AGENTSTUDIO_GIT_AGENTSTUDIO_PATH is required for the AgentStudio compatibility gate.
Set it to a checked-out AgentStudio repository, then rerun:

  AGENTSTUDIO_GIT_AGENTSTUDIO_PATH=/path/to/agent-studio \
    bash scripts/verify-agentstudio-compatibility.sh
EOF
  exit 2
fi

if [ ! -d "$AGENTSTUDIO_GIT_AGENTSTUDIO_PATH/Sources/AgentStudio" ]; then
  echo "AGENTSTUDIO_GIT_AGENTSTUDIO_PATH does not look like an AgentStudio checkout: $AGENTSTUDIO_GIT_AGENTSTUDIO_PATH" >&2
  exit 2
fi

AGENTSTUDIO_ROOT="$(cd "$AGENTSTUDIO_GIT_AGENTSTUDIO_PATH" && pwd -P)"
MANIFEST_PATH="$AGENTSTUDIO_ROOT/Package.swift"
RESOLVED_PATH="$AGENTSTUDIO_ROOT/Package.resolved"

if [ ! -f "$MANIFEST_PATH" ] || [ ! -f "$RESOLVED_PATH" ]; then
  echo "AgentStudio compatibility requires Package.swift and Package.resolved in the configured checkout." >&2
  exit 2
fi

production_changes="$(git -C "$ROOT_DIR" status --porcelain -- Package.swift Sources)"
if [ -n "$production_changes" ]; then
  echo "AgentStudio compatibility refused: SDK candidate has production changes in Package.swift or Sources/." >&2
  exit 2
fi

candidate_revision="$(git -C "$ROOT_DIR" rev-parse HEAD)"

manifest_revision="$({
  awk -v dependency_url="$AGENTSTUDIO_GIT_REMOTE_URL" '
    /^[[:space:]]*\.package\(/ {
      package_block = $0
      reading_package = 1
      next
    }
    reading_package {
      package_block = package_block "\n" $0
      if ($0 ~ /^[[:space:]]*\),?[[:space:]]*$/) {
        if (index(package_block, dependency_url) > 0 &&
            match(package_block, /revision:[[:space:]]*"[0-9a-fA-F]+"/)) {
          revision_clause = substr(package_block, RSTART, RLENGTH)
          split(revision_clause, fields, "\"")
          print fields[2]
        }
        package_block = ""
        reading_package = 0
      }
    }
  ' "$MANIFEST_PATH"
} | sort -u)"

agentstudio_resolved_revision() {
  awk '
    /"identity"[[:space:]]*:[[:space:]]*"agentstudio-git"/ {
      reading_agentstudio_git_pin = 1
      next
    }
    reading_agentstudio_git_pin && match($0, /"revision"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]+"/) {
      revision_clause = substr($0, RSTART, RLENGTH)
      split(revision_clause, fields, "\"")
      print fields[4]
      exit
    }
  ' "$RESOLVED_PATH"
}

resolved_revision="$(agentstudio_resolved_revision)"

if [ "$manifest_revision" != "$candidate_revision" ]; then
  echo "AgentStudio Package.swift does not declare the SDK candidate revision." >&2
  exit 2
fi

if [ "$resolved_revision" != "$candidate_revision" ]; then
  echo "AgentStudio Package.resolved does not pin the SDK candidate revision." >&2
  exit 2
fi

echo "AgentStudio compatibility: exact SDK candidate pin verified; running real consumer suites."
agentstudio_test_output="$(mktemp)"
trap 'rm -f "$agentstudio_test_output"' EXIT
agentstudio_test_status=0
(
  cd "$AGENTSTUDIO_ROOT"
  set -o pipefail
  mise run test:swift -- --filter "$AGENTSTUDIO_CONSUMER_SUITE_FILTER" 2>&1 \
    | tee "$agentstudio_test_output"
) || agentstudio_test_status=$?

post_test_resolved_revision="$(agentstudio_resolved_revision)"

if [ "$post_test_resolved_revision" != "$candidate_revision" ]; then
  echo "AgentStudio Package.resolved changed away from the SDK candidate revision while the consumer gate ran." >&2
  exit 2
fi

if [ "$agentstudio_test_status" -ne 0 ]; then
  exit "$agentstudio_test_status"
fi

if ! grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$agentstudio_test_output"; then
  echo "AgentStudio compatibility failed: consumer task did not report a positive Swift Testing terminal count." >&2
  exit 2
fi

echo "AgentStudio compatibility: real consumer suites passed at the exact SDK candidate pin."
