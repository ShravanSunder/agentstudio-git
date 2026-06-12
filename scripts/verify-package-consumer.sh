#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-git-consumer.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
ZIP_CHECKSUM_PATH="$ROOT_DIR/Artifacts/CLibGit2Local.xcframework.zip.checksum"
RELEASE_ARTIFACT_URL="https://artifact.invalid/CLibGit2Local.xcframework.zip"

if [ ! -f "$ZIP_CHECKSUM_PATH" ]; then
  AGENTSTUDIO_GIT_CREATE_LIBGIT2_ZIP=1 bash "$ROOT_DIR/scripts/build-libgit2-xcframework.sh"
fi

libgit2_checksum="$(tr -d '[:space:]' <"$ZIP_CHECKSUM_PATH")"

mkdir -p "$SCRATCH_DIR/Sources/UmbrellaConsumer"
mkdir -p "$SCRATCH_DIR/Sources/LeafConsumer"

{
  printf '%s\n' '// swift-tools-version: 6.2'
  printf '%s\n' 'import PackageDescription'
  printf '%s\n' ''
  printf '%s\n' 'let package = Package('
  printf '%s\n' '    name: "AgentStudioGitConsumer",'
  printf '%s\n' '    platforms: ['
  printf '%s\n' '        .macOS(.v14),'
  printf '%s\n' '    ],'
  printf '%s\n' '    products: ['
  printf '%s\n' '        .executable(name: "umbrella-consumer", targets: ["UmbrellaConsumer"]),'
  printf '%s\n' '        .executable(name: "leaf-consumer", targets: ["LeafConsumer"]),'
  printf '%s\n' '    ],'
  printf '%s\n' '    dependencies: ['
  printf '        .package(path: "%s"),\n' "$ROOT_DIR"
  printf '%s\n' '    ],'
  printf '%s\n' '    targets: ['
  printf '%s\n' '        .executableTarget('
  printf '%s\n' '            name: "UmbrellaConsumer",'
  printf '%s\n' '            dependencies: ['
  printf '%s\n' '                .product(name: "AgentStudioGit", package: "agentstudio-git"),'
  printf '%s\n' '            ]'
  printf '%s\n' '        ),'
  printf '%s\n' '        .executableTarget('
  printf '%s\n' '            name: "LeafConsumer",'
  printf '%s\n' '            dependencies: ['
  printf '%s\n' '                .product(name: "AgentStudioGit", package: "agentstudio-git"),'
  printf '%s\n' '                .product(name: "AgentStudioGitContracts", package: "agentstudio-git"),'
  printf '%s\n' '                .product(name: "AgentStudioGitLocal", package: "agentstudio-git"),'
  printf '%s\n' '                .product(name: "AgentStudioGitRemote", package: "agentstudio-git"),'
  printf '%s\n' '            ]'
  printf '%s\n' '        ),'
  printf '%s\n' '    ]'
  printf '%s\n' ')'
} >"$SCRATCH_DIR/Package.swift"

{
  printf '%s\n' 'import AgentStudioGit'
  printf '%s\n' ''
  printf '%s\n' 'let version = LibGit2ImportCanary.version()'
  printf '%s\n' 'let remoteClient = SystemGitRemoteClient(configuration: .init(inheritEnvironment: false))'
  printf '%s\n' 'let statusOptions = GitStatusOptions()'
  printf '%s\n' 'let promptPolicy = GitRemotePromptPolicy.noninteractive'
  printf '%s\n' 'let remoteProtocol = GitRemoteProtocol.https'
  printf '%s\n' 'let unsupported = GitDataPlaneError.unsupported(message: "consumer smoke")'
  printf '%s\n' 'precondition(version.major == 1)'
  printf '%s\n' 'print("umbrella \(version.major).\(version.minor).\(version.revision) \(type(of: remoteClient)) \(statusOptions.includeUntracked) \(promptPolicy.rawValue) \(remoteProtocol.rawValue) \(unsupported)")'
} >"$SCRATCH_DIR/Sources/UmbrellaConsumer/main.swift"

{
  printf '%s\n' 'import AgentStudioGit'
  printf '%s\n' 'import AgentStudioGitContracts'
  printf '%s\n' 'import AgentStudioGitLocal'
  printf '%s\n' 'import AgentStudioGitRemote'
  printf '%s\n' ''
  printf '%s\n' 'let version = LibGit2ImportCanary.version()'
  printf '%s\n' 'let remoteClient = SystemGitRemoteClient(configuration: .init(inheritEnvironment: false))'
  printf '%s\n' 'let statusOptions = GitStatusOptions()'
  printf '%s\n' 'let promptPolicy = GitRemotePromptPolicy.noninteractive'
  printf '%s\n' 'let remoteProtocol = GitRemoteProtocol.https'
  printf '%s\n' 'let unsupported = GitDataPlaneError.unsupported(message: "consumer smoke")'
  printf '%s\n' 'precondition(version.major == 1)'
  printf '%s\n' 'print("leaf \(version.major).\(version.minor).\(version.revision) \(type(of: remoteClient)) \(statusOptions.includeUntracked) \(promptPolicy.rawValue) \(remoteProtocol.rawValue) \(unsupported)")'
} >"$SCRATCH_DIR/Sources/LeafConsumer/main.swift"

env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  swift build --package-path "$SCRATCH_DIR"
env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  swift run --package-path "$SCRATCH_DIR" umbrella-consumer
env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  swift run --package-path "$SCRATCH_DIR" leaf-consumer

AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="$RELEASE_ARTIFACT_URL" \
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="$libgit2_checksum" \
  swift package dump-package --package-path "$ROOT_DIR" >"$SCRATCH_DIR/release-package.json"

grep -q "$RELEASE_ARTIFACT_URL" "$SCRATCH_DIR/release-package.json"
grep -q "$libgit2_checksum" "$SCRATCH_DIR/release-package.json"
