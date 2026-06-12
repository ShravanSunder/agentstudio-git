#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-git-consumer.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

mkdir -p "$SCRATCH_DIR/Sources/Consumer"

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
  printf '%s\n' '        .executable(name: "consumer", targets: ["Consumer"]),'
  printf '%s\n' '    ],'
  printf '%s\n' '    dependencies: ['
  printf '        .package(path: "%s"),\n' "$ROOT_DIR"
  printf '%s\n' '    ],'
  printf '%s\n' '    targets: ['
  printf '%s\n' '        .executableTarget('
  printf '%s\n' '            name: "Consumer",'
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
  printf '%s\n' 'print("\(version.major).\(version.minor).\(version.revision)")'
} >"$SCRATCH_DIR/Sources/Consumer/main.swift"

swift build --package-path "$SCRATCH_DIR"
swift run --package-path "$SCRATCH_DIR" consumer
