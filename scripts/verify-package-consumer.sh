#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-git-consumer.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
PUBLIC_LIBGIT2_ARTIFACT_URL="https://raw.githubusercontent.com/ShravanSunder/experiments-gh-cli-repo-public/aa2c8b9/agentstudio-git/libgit2/2026-06-12/CLibGit2Local.xcframework.zip"
PUBLIC_LIBGIT2_ARTIFACT_CHECKSUM="33a995b26dafeaf0b73ef2d65371653c0e35042d55344fef4acea1b059c2740d"
OVERRIDE_ARTIFACT_URL="https://artifact.invalid/CLibGit2Local.xcframework.zip"

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
  printf '        .package(name: "agentstudio-git", path: "%s"),\n' "$ROOT_DIR"
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

echo "--- downstream consumer proof without hosted artifact overrides ---"
env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  -u AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT \
  swift build --package-path "$SCRATCH_DIR"
env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  -u AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT \
  swift run --package-path "$SCRATCH_DIR" umbrella-consumer
env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  -u AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT \
  swift run --package-path "$SCRATCH_DIR" leaf-consumer

env -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM \
  -u AGENTSTUDIO_GIT_ALLOW_LIBGIT2_BINARY_URL \
  -u AGENTSTUDIO_GIT_USE_LOCAL_LIBGIT2_ARTIFACT \
  swift package dump-package --package-path "$ROOT_DIR" >"$SCRATCH_DIR/default-package.json"
grep -q "$PUBLIC_LIBGIT2_ARTIFACT_URL" "$SCRATCH_DIR/default-package.json"
grep -q "$PUBLIC_LIBGIT2_ARTIFACT_CHECKSUM" "$SCRATCH_DIR/default-package.json"

AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="$OVERRIDE_ARTIFACT_URL" \
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="$PUBLIC_LIBGIT2_ARTIFACT_CHECKSUM" \
  swift package dump-package --package-path "$ROOT_DIR" >"$SCRATCH_DIR/override-package.json"
grep -q "$OVERRIDE_ARTIFACT_URL" "$SCRATCH_DIR/override-package.json"
grep -q "$PUBLIC_LIBGIT2_ARTIFACT_CHECKSUM" "$SCRATCH_DIR/override-package.json"
