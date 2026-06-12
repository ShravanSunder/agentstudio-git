#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_remote() {
  local variable_name="$1"
  local label="$2"
  local remote_url="${!variable_name:-}"
  if [ -z "$remote_url" ]; then
    cat >&2 <<EOF
$variable_name is required for the live $label remote/auth gate.

Set it to a disposable repository URL where your current system Git
configuration can clone, fetch, push, and delete a temporary branch.
The test creates and removes refs under:

  refs/heads/agentstudio-git-live-smoke/

EOF
    exit 2
  fi
}

run_remote_auth_smoke() {
  local label="$1"
  local remote_url="$2"
  echo "--- live $label remote/auth smoke ---"
  echo "remote: configured $label URL (value not printed)"
  AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_SMOKE=1 \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_LABEL="$label" \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_URL="$remote_url" \
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" SystemGitRemoteClientTests
}

require_remote AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL "HTTPS credential-helper"
require_remote AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL "SSH-agent"

run_remote_auth_smoke "https" "$AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL"
run_remote_auth_smoke "ssh" "$AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL"
