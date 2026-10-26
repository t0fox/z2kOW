#!/bin/sh
# tests/test_nfqws1_compat.sh — badseq и hostfakesplit altorder=1 (z2k-nfqws1-compat.lua)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
"${LUA:-lua}" tests/test_nfqws1_compat.lua
