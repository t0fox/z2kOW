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

_warp_controller_disable_state
check equal "$(cat "$TMP/args")" disable-state
cat > "$TMP/expected" <<EOF
version=1
config=$TMP/config
interface=z2ktun0
probe_address=172.16.9.9
table=989
user_pref=500
probe_pref=499
mark=0x80000000
mask=0x80000000
pbr_owner=$TMP/pbr.owner
probe_owner=$TMP/probe.owner
route_error=$TMP/route-error
fw4_family=inet
fw4_table=fw4
fw4_chain=forward
fw4_comment=!z2k: WARP forwarded traffic
nft_family=inet
nft_table=zapret2
mark_chain=z2k_warp_mark
mss_chain=z2k_warp_mss
forward_chain=z2k_warp_fwd
nat_chain=z2k_warp_nat
observer_family=inet
observer_table=z2k_warp_dns
pair_family=inet
pair_table=zapret2
pair_set=z2k_warp_domain4
domain_error=$TMP/domain-error
EOF
check cmp -s "$TMP/expected" "$TMP/input"

WARP_TEST_EXIT=1
export WARP_TEST_EXIT
warp_op_current() { return 0; }
warp_running() { return 1; }
_warp_service_transition() { : > "$TMP/service-transition"; }
_warp_procd_recovery_clear() { : > "$TMP/recovery-clear"; }
warp_unpin_legacy() { : > "$TMP/unpin"; }
if warp_disable; then
    FAIL=$((FAIL + 1))
    echo "FAIL: отказ очистки должен прервать отключение" >&2
else
    PASS=$((PASS + 1))
fi
check equal "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$TMP/config")" 1
check exists "$TMP/procd-instance"
check exists "$TMP/procd-recovery"
check missing "$TMP/service-transition"
check missing "$TMP/recovery-clear"
check missing "$TMP/unpin"

WARP_CONTROLLER_BIN="$TMP/no-controller"
warp_pbr_down() { return 1; }
if warp_disable; then
    FAIL=$((FAIL + 1))
    echo "FAIL: legacy-совместимость должна прервать отключение при ошибке PBR" >&2
else
    PASS=$((PASS + 1))
fi
check equal "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$TMP/config")" 1
check equal "$(sed -n 's/ .*//p' "$TMP/route-error")" warp-disable-pbr-remove-failed
check exists "$TMP/procd-instance"
check exists "$TMP/procd-recovery"
check missing "$TMP/service-transition"

echo "SUITE[warp-disable-guard]: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
