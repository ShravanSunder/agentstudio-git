#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBGIT2_DIR="$ROOT_DIR/vendor/libgit2"
BUILD_ROOT="$ROOT_DIR/.build/libgit2"
UNIVERSAL_BUILD_DIR="$BUILD_ROOT/macos-universal"
HEADER_STAGING_DIR="$ROOT_DIR/.build/libgit2/CLibGit2LocalHeaders"
ARTIFACT_DIR="$ROOT_DIR/Artifacts"
XCFRAMEWORK_PATH="$ARTIFACT_DIR/CLibGit2Local.xcframework"
ZIP_PATH="$ARTIFACT_DIR/CLibGit2Local.xcframework.zip"
EXPECTED_COMMIT="f7164261c9bc0a7e0ebf767c584e5192810a8b24"
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CMAKE_ENV=(
  env
  -u CMAKE_TOOLCHAIN_FILE
  -u VCPKG_ROOT
  -u VCPKG_DEFAULT_TRIPLET
  -u CMAKE_C_COMPILER_LAUNCHER
  -u CMAKE_CXX_COMPILER_LAUNCHER
)

if [ ! -d "$LIBGIT2_DIR/.git" ] && [ ! -f "$LIBGIT2_DIR/.git" ]; then
  echo "vendor/libgit2 is missing; run git submodule update --init --recursive" >&2
  exit 1
fi

actual_commit="$(git -C "$LIBGIT2_DIR" rev-parse HEAD)"
if [ "$actual_commit" != "$EXPECTED_COMMIT" ]; then
  echo "vendor/libgit2 is at $actual_commit; expected $EXPECTED_COMMIT" >&2
  exit 1
fi

rm -rf "$BUILD_ROOT/arm64" "$BUILD_ROOT/x86_64" "$UNIVERSAL_BUILD_DIR" "$HEADER_STAGING_DIR" "$XCFRAMEWORK_PATH"
mkdir -p "$UNIVERSAL_BUILD_DIR" "$HEADER_STAGING_DIR" "$ARTIFACT_DIR"

thin_lib_paths=()
for target_arch in arm64 x86_64; do
  BUILD_DIR="$BUILD_ROOT/$target_arch"
  mkdir -p "$BUILD_DIR"

  "${CMAKE_ENV[@]}" cmake -G Ninja -S "$LIBGIT2_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES="$target_arch" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_FUZZERS=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTP=OFF \
    -DUSE_HTTPS=OFF \
    -DUSE_AUTH_NEGOTIATE=OFF \
    -DUSE_GSSAPI=OFF

  "${CMAKE_ENV[@]}" cmake --build "$BUILD_DIR" --config Release --target libgit2package --parallel

  thin_lib_path="$(find "$BUILD_DIR" -name 'libgit2.a' -type f | head -n 1)"
  if [ -z "$thin_lib_path" ]; then
    echo "failed to locate built libgit2.a under $BUILD_DIR" >&2
    exit 1
  fi
  thin_lib_paths+=("$thin_lib_path")
done

LIB_PATH="$UNIVERSAL_BUILD_DIR/libgit2.a"
lipo -create "${thin_lib_paths[@]}" -output "$LIB_PATH"

cp "$LIBGIT2_DIR/include/git2.h" "$HEADER_STAGING_DIR/git2.h"
cp -R "$LIBGIT2_DIR/include/git2" "$HEADER_STAGING_DIR/git2"
if [ -f "$BUILD_ROOT/arm64/gen_headers/git2_features.h" ]; then
  cp "$BUILD_ROOT/arm64/gen_headers/git2_features.h" "$HEADER_STAGING_DIR/git2_features.h"
else
  echo "failed to locate generated git2_features.h" >&2
  exit 1
fi

cat >"$HEADER_STAGING_DIR/module.modulemap" <<'MODULEMAP'
module CLibGit2Local [system] {
  umbrella header "git2.h"
  export *
}
MODULEMAP

xcodebuild -create-xcframework \
  -library "$LIB_PATH" \
  -headers "$HEADER_STAGING_DIR" \
  -output "$XCFRAMEWORK_PATH"

if [ "${AGENTSTUDIO_GIT_CREATE_LIBGIT2_ZIP:-0}" = "1" ]; then
  rm -f "$ZIP_PATH"
  (cd "$ARTIFACT_DIR" && zip -qry "$(basename "$ZIP_PATH")" "$(basename "$XCFRAMEWORK_PATH")")
  swift package compute-checksum "$ZIP_PATH" >"$ZIP_PATH.checksum"
fi

echo "Built $XCFRAMEWORK_PATH"
