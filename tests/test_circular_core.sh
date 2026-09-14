#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
LUA=${LUA:-lua}
"$LUA" "${Z2K_FORK_DIR:-../zapret2-z2k-fork}/tests/test_circular.lua"
