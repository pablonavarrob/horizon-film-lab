#!/bin/bash
# Runs the in-process regression harness using the installed Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/horizon-edge-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export HORIZON_TEST_TMP="$test_dir"

# Keep compiler caches and the test executable outside the app and source tree.
# Exclude only the GUI entry point; the regression runner supplies its own.
sources=()
for source in Sources/horizon/*.swift; do
  if [[ "$source" != */main.swift ]]; then sources+=("$source"); fi
done
tests=()
for test_source in Tests/*.swift; do tests+=("$test_source"); done
swiftc -O -g -module-cache-path "$test_dir/module-cache" \
  "${sources[@]}" "${tests[@]}" \
  -o "$test_dir/invert-edge-tests"
"$test_dir/invert-edge-tests"
