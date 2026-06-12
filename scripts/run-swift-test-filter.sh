#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: scripts/run-swift-test-filter.sh [swift test options...] <SwiftPM filter>" >&2
  exit 64
fi

filter="${!#}"
swift_test_arguments=()
if [ "$#" -gt 1 ]; then
  swift_test_arguments=("${@:1:$#-1}")
fi
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

if [ "${#swift_test_arguments[@]}" -gt 0 ]; then
  swift test "${swift_test_arguments[@]}" --filter "$filter" 2>&1 | tee "$output_file"
else
  swift test --filter "$filter" 2>&1 | tee "$output_file"
fi

zero_test_pattern="No matching test cases were run|Test run with 0 tests in 0 suites"
if command -v rg >/dev/null 2>&1; then
  zero_tests_found() {
    rg -q "$zero_test_pattern" "$output_file"
  }
else
  zero_tests_found() {
    grep -Eq "$zero_test_pattern" "$output_file"
  }
fi

if zero_tests_found; then
  echo "filtered Swift test gate executed zero tests: $filter" >&2
  exit 1
fi
