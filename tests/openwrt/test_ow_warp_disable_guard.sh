#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
check() {
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $*" >&2
    fi
}
equal() { [ "$1" = "$2" ]; }
exists() { [ -e "$1" ]; }
missing() { [ ! -e "$1" ]; }

cat > "$TMP/controller" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$WARP_TEST_ARGS"
cat > "$WARP_TEST_INPUT"
exit "${WARP_TEST_EXIT:-0}"
EOF
chmod 700 "$TMP/controller"
printf 'GAME_WARP_ENABLED=1\n' > "$TMP/config"
printf '{"iface":"z2ktun0","addr":"172.16.9.9"}\n' > "$TMP/status.json"
touch "$TMP/procd-instance" "$TMP/procd-recovery"

CONFIG_FILE="$TMP/config"
Z2K_TMP="$TMP"
Z2K_LISTS_DIR="$TMP/lists"
Z2K_ROOT="$ROOT"
WARP_CONTROLLER_BIN="$TMP/controller"
WARP_TEST_ARGS="$TMP/args"
WARP_TEST_INPUT="$TMP/input"
export WARP_TEST_ARGS WARP_TEST_INPUT
WARP_STATUS="$TMP/status.json"
WARP_DEVICE="$TMP/device.json"
WARP_PROCD_INSTANCE_FILE="$TMP/procd-instance"
WARP_PROCD_RECOVERY_FILE="$TMP/procd-recovery"
WARP_LOCK_DIR="$TMP/lock"
WARP_PBR_OWNER="$TMP/pbr.owner"
WARP_PROBE_OWNER="$TMP/probe.owner"
WARP_ROUTE_ERROR_FILE="$TMP/route-error"
WARP_DOMAIN_ERROR="$TMP/domain-error"
WARP_DOMAIN_HELPER="$ROOT/platform/openwrt/warp-domain.sh"
WARP_DOMAIN_RUNTIME_BIN="$TMP/z2k-warpd"
Z2K_WARP_SOURCE_ONLY=1
. "$ROOT/platform/openwrt/warp.sh"

if ! warp_disable </dev/null; then
    FAIL=$((FAIL + 1))
    echo "FAIL: Rust disable-команда должна вызвать контроллер" >&2
else
    PASS=$((PASS + 1))
fi
printf 'lifecycle\ndisable\n' > "$TMP/expected"
check cmp -s "$TMP/expected" "$TMP/args"
check equal "$(wc -c < "$TMP/input" | tr -d ' ')" 0

WARP_TEST_EXIT=1
export WARP_TEST_EXIT
if warp_disable </dev/null; then
    FAIL=$((FAIL + 1))
    echo "FAIL: отказ очистки должен прервать отключение" >&2
else
    PASS=$((PASS + 1))
fi
check equal "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$TMP/config")" 1
check exists "$TMP/procd-instance"
check exists "$TMP/procd-recovery"

WARP_CONTROLLER_BIN="$TMP/no-controller"
if warp_disable; then
    FAIL=$((FAIL + 1))
    echo "FAIL: отключение без Rust-контроллера должно завершиться ошибкой" >&2
else
    PASS=$((PASS + 1))
fi
check equal "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$TMP/config")" 1
check exists "$TMP/procd-instance"
check exists "$TMP/procd-recovery"

echo "SUITE[warp-disable-guard]: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
