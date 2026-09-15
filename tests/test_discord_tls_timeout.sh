#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
"${LUA:-lua}" tests/test_discord_tls_timeout.lua
