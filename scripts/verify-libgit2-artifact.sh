#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK_PATH="$ROOT_DIR/Artifacts/CLibGit2Local.xcframework"

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
  echo "missing $XCFRAMEWORK_PATH" >&2
  exit 1
fi

INFO_PLIST="$XCFRAMEWORK_PATH/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "missing $INFO_PLIST" >&2
  exit 1
fi

LIB_PATH="$(find "$XCFRAMEWORK_PATH" -name 'libgit2.a' -type f | head -n 1)"
if [ -z "$LIB_PATH" ]; then
  echo "missing libgit2.a inside $XCFRAMEWORK_PATH" >&2
  exit 1
fi

HEADERS_DIR="$(find "$XCFRAMEWORK_PATH" -type d -name Headers | head -n 1)"
if [ -z "$HEADERS_DIR" ]; then
  echo "missing Headers directory inside $XCFRAMEWORK_PATH" >&2
  exit 1
fi

for required_header in "$HEADERS_DIR/git2.h" "$HEADERS_DIR/git2/common.h" "$HEADERS_DIR/git2_features.h" "$HEADERS_DIR/module.modulemap"; do
  if [ ! -f "$required_header" ]; then
    echo "missing required header artifact: $required_header" >&2
    exit 1
  fi
done

if ! grep -q 'umbrella header "git2.h"' "$HEADERS_DIR/module.modulemap"; then
  echo "module.modulemap does not expose git2.h as umbrella header" >&2
  exit 1
fi

lipo -info "$LIB_PATH"
echo "Verified $XCFRAMEWORK_PATH"
