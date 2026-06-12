#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/run-swift-test-filter.sh <SwiftPM filter>" >&2
  exit 64
fi

filter="$1"
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

swift test --filter "$filter" 2>&1 | tee "$output_file"

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
