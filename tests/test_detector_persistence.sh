#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
LUA=${LUA:-lua}
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM HUP
mkdir -p "$TEST_DIR/fallback"
export Z2K_STATE_DIR_OVERRIDE="$TEST_DIR"
export Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TEST_DIR/fallback"
"$LUA" tests/test_detector_persistence.lua
