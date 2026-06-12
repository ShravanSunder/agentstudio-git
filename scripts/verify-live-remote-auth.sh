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

is_ssh_remote() {
  local remote_url="$1"
  [[ "$remote_url" == ssh://* || "$remote_url" =~ ^[^/:[:space:]]+@[^:[:space:]]+:.+ ]]
}

require_remote_protocol() {
  local variable_name="$1"
  local expected_protocol="$2"
  local label="$3"
  local remote_url="${!variable_name:-}"
  require_remote "$variable_name" "$label"
  case "$expected_protocol" in
    https)
      if [[ "$remote_url" != https://* ]]; then
        echo "$variable_name must be an expected https remote URL for the live $label remote/auth gate." >&2
        exit 2
      fi
      ;;
    ssh)
      if ! is_ssh_remote "$remote_url"; then
        echo "$variable_name must be an expected ssh remote URL for the live $label remote/auth gate." >&2
        exit 2
      fi
      ;;
    *)
      echo "Unsupported live remote/auth protocol gate: $expected_protocol" >&2
      exit 2
      ;;
  esac
}

run_remote_auth_smoke() {
  local label="$1"
  local expected_protocol="$2"
  local remote_url="$3"
  echo "--- live $label remote/auth smoke ---"
  echo "remote: configured $label URL (value not printed)"
  env -u AGENTSTUDIO_GIT_LIVE_REMOTE_SMOKE \
    -u AGENTSTUDIO_GIT_LIVE_REMOTE_URL \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_SMOKE=1 \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_LABEL="$label" \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_PROTOCOL="$expected_protocol" \
    AGENTSTUDIO_GIT_LIVE_REMOTE_AUTH_URL="$remote_url" \
    bash "$ROOT_DIR/scripts/run-swift-test-filter.sh" SystemGitRemoteClientTests
}

require_remote_protocol AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL "https" "HTTPS credential-helper"
require_remote_protocol AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL "ssh" "SSH-agent"

run_remote_auth_smoke "https" "https" "$AGENTSTUDIO_GIT_LIVE_HTTPS_REMOTE_URL"
run_remote_auth_smoke "ssh" "ssh" "$AGENTSTUDIO_GIT_LIVE_SSH_REMOTE_URL"
