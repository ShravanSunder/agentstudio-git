#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-git-hosted-artifact.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

require_env() {
  local variable_name="$1"
  local description="$2"
  if [ -z "${!variable_name:-}" ]; then
    cat >&2 <<EOF
$variable_name is required for the hosted libgit2 artifact gate.

Set it to $description, then rerun:

  AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" \\
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" \\
    bash scripts/verify-hosted-libgit2-artifact.sh
EOF
    exit 2
  fi
}

require_env AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL "the public HTTPS URL for CLibGit2Local.xcframework.zip"
require_env AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM "the SwiftPM checksum for that hosted zip"

binary_url="$AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"
binary_checksum="$AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"

if [[ "$binary_url" != https://* ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL must be an https URL for SwiftPM binary target download proof." >&2
  exit 2
fi

if [[ "$binary_url" == *"@"* || "$binary_url" == *"?"* ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL must be a public release artifact URL without userinfo or query credentials." >&2
  exit 2
fi

if [[ ! "$binary_checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM must be a 64-character SwiftPM checksum." >&2
  exit 2
fi

mkdir -p "$SCRATCH_DIR/Sources/HostedArtifactConsumer"

{
  printf '%s\n' '// swift-tools-version: 6.2'
  printf '%s\n' 'import PackageDescription'
  printf '%s\n' ''
  printf '%s\n' 'let package = Package('
  printf '%s\n' '    name: "AgentStudioGitHostedArtifactConsumer",'
  printf '%s\n' '    platforms: ['
  printf '%s\n' '        .macOS(.v14),'
  printf '%s\n' '    ],'
  printf '%s\n' '    products: ['
  printf '%s\n' '        .executable(name: "hosted-artifact-consumer", targets: ["HostedArtifactConsumer"]),'
  printf '%s\n' '    ],'
  printf '%s\n' '    dependencies: ['
  printf '        .package(path: "%s"),\n' "$ROOT_DIR"
  printf '%s\n' '    ],'
  printf '%s\n' '    targets: ['
  printf '%s\n' '        .executableTarget('
  printf '%s\n' '            name: "HostedArtifactConsumer",'
  printf '%s\n' '            dependencies: ['
  printf '%s\n' '                .product(name: "AgentStudioGitLocal", package: "agentstudio-git"),'
  printf '%s\n' '            ]'
  printf '%s\n' '        ),'
  printf '%s\n' '    ]'
  printf '%s\n' ')'
} >"$SCRATCH_DIR/Package.swift"

{
  printf '%s\n' 'import AgentStudioGitLocal'
  printf '%s\n' ''
  printf '%s\n' 'let version = LibGit2ImportCanary.version()'
  printf '%s\n' 'precondition(version.major == 1)'
  printf '%s\n' 'print("hosted libgit2 \(version.major).\(version.minor).\(version.revision)")'
} >"$SCRATCH_DIR/Sources/HostedArtifactConsumer/main.swift"

echo "--- hosted libgit2 artifact proof ---"
echo "artifact: configured HTTPS URL (value not printed)"
echo "checksum: configured SwiftPM checksum"

AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="$binary_url" \
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="$binary_checksum" \
  swift run --package-path "$SCRATCH_DIR" hosted-artifact-consumer
