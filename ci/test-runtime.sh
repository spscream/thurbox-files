#!/usr/bin/env bash
# Compile the regression against the pinned kernel, not a mock of its globals.
set -euo pipefail
UPSTREAM=${1:?usage: test-runtime.sh <thurbox-checkout> <assembled-ui>}
export FILES_TEST_UI=$(realpath "${2:?assembled-ui}")
TEST="$UPSTREAM/tests/files_plugin_runtime.rs"
trap 'rm -f "$TEST"; rm -rf "$(dirname "$FILES_TEST_UI")/runtime-fixture"' EXIT
cp "$(dirname "$0")/files_runtime.rs" "$TEST"
cargo test --manifest-path "$UPSTREAM/Cargo.toml" --test files_plugin_runtime -- --nocapture
