#!/bin/bash
# Runs against the actual image pipeline using only the Swift command-line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/horizon-edge-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

# Keep compiler caches and the test executable outside the app and source tree.
# Exclude only the GUI entry point; the regression runner supplies its own.
sources=()
for source in Sources/horizon/*.swift; do
  if [[ "$source" != */main.swift ]]; then sources+=("$source"); fi
done
swiftc -O -g -module-cache-path "${HORIZON_TEST_MODULE_CACHE:-$test_dir/module-cache}" \
  "${sources[@]}" Tests/InvertEdgeTests.swift \
  -o "$test_dir/invert-edge-tests"
"$test_dir/invert-edge-tests"