#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

AGENTSTUDIO_GIT_REQUIRE_AGENTSTUDIO_COMPATIBILITY=1 \
  AGENTSTUDIO_GIT_AGENTSTUDIO_PATH="$AGENTSTUDIO_GIT_AGENTSTUDIO_PATH" \
  bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" CompatibilityTests
