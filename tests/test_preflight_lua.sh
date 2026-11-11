#!/bin/sh
# Проверка автомата Lua-проверки Googlevideo; локально допускается отсутствие Lua.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUA="$(command -v lua5.3 || command -v lua5.4 || command -v lua || true)"
if [ -z "$LUA" ]; then
    echo "[SKIP] нет Lua — автомат z2k_preflight не проверен"
    exit 0
fi
cd "$ROOT" || exit 1
exec "$LUA" tests/test_preflight_lua.lua
