#!/bin/sh
# tests/openwrt/test_ow_warp_status.sh - WARP status must expose the failed
# daemon attempt and must not confuse transport readiness with platform PBR.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-status"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WARP_SCRIPT="${WARP_SCRIPT:-$REPO/platform/openwrt/warp.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warps.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/etc/state/warp" "$T/etc/user-lists/warp" \
    "$T/root/lists/warp" "$T/tmp/warp" "$T/proc/7777"
export PATH="$T/bin:$PATH"
export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_STATE="$T/etc/state" Z2K_LISTS_DIR="$T/root/lists"
export CONFIG_FILE="$T/etc/config" WARP_BIN="$T/root/bin/z2k-warpd"
export WARP_DEVICE="$T/etc/state/warp/device.json"
export WARP_STATUS="$T/tmp/warp/status.json" WARP_LOG="$T/tmp/warp/warpd.log"
export WARP_PBR_OWNER="$T/tmp/warp/pbr.owner" Z2K_PROC_ROOT="$T/proc"
export WARP_LISTS_DIR="$T/etc/user-lists/warp" WARP_GAMES_DIR="$T/root/lists/warp"
export WARP_ENABLED_FILE="$T/etc/user-lists/warp/.enabled"
export WARP_DEVICES_FILE="$T/etc/user-lists/warp/devices.txt"
export Z2K_WARP_SOURCE_ONLY=1

cat > "$T/root/bin/z2k-warpd" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-warpd"
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '{"id":"test-device"}\n' > "$T/etc/state/warp/device.json"

cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"

cat > "$T/bin/ip" <<EOF
#!/bin/sh
if [ "\$1" = link ] && [ "\$2" = show ]; then
    [ -f "$T/link-\$4" ] && exit 0
    exit 1
fi
if [ "\$1" = rule ] && [ "\$2" = show ]; then
    cat "$T/ip-rules" 2>/dev/null
    exit 0
fi
if [ "\$1" = route ] && [ "\$2" = show ]; then
    cat "$T/ip-route-\$4" 2>/dev/null
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
if [ "\$1" = list ] && [ "\$2" = table ]; then exit 0; fi
if [ "\$1" = list ] && [ "\$2" = set ]; then exit 0; fi
if [ "\$1" = list ] && [ "\$2" = chain ]; then
    [ "\${HAVE_NFT:-0}" = 1 ] || exit 0
    cat <<'RULES'
oifname z2ktun0 tcp flags syn tcp option maxseg size set rt mtu
iifname z2ktun0 tcp flags syn tcp option maxseg size set 1240
oifname z2ktun0 accept
oifname z2ktun0 masquerade
RULES
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"

# A matching live process is part of the existing proof contract.
printf 'z2k-warpd\0run\0--device\0%s\0' "$WARP_DEVICE" > "$T/proc/7777/cmdline"

# shellcheck disable=SC1090,SC1091
. "$WARP_SCRIPT" || { _t_bad "source"; exit 1; }

# RED case: the daemon removed status.json after CreateTUN failed.  The panel
# must receive the concrete failure, not the old generic "starting" state.
cat > "$WARP_LOG" <<'EOF'
2026-09-21 16:35:54 z2k-warpd dev starting
2026-09-21 16:35:54 fatal: tun z2ktun0: CreateTUN("z2ktun0") failed; /dev/net/tun does not exist
EOF
rm -f "$WARP_STATUS"
_out="$(warp_status)"
printf '%s\n' "$_out" > "$T/status-failed.log"
assert_contains "missing TUN is reported" "$T/status-failed.log" "error=tun_failed"
assert_contains "failed attempt is an error state" "$T/status-failed.log" "state=error"
assert_contains "failed attempt has no running process" "$T/status-failed.log" "running=0"

# A later start without a new fatal must clear the old error.  It is recovery,
# not a false successful tunnel.
cat > "$WARP_LOG" <<'EOF'
2026-09-21 16:35:54 z2k-warpd dev starting
2026-09-21 16:35:54 fatal: tun z2ktun0: CreateTUN("z2ktun0") failed; /dev/net/tun does not exist
2026-09-21 16:36:04 z2k-warpd dev starting
EOF
_out="$(warp_status)"
printf '%s\n' "$_out" > "$T/status-recovering.log"
assert_contains "new attempt clears stale error" "$T/status-recovering.log" "error= mem="
assert_contains "new attempt is recovering" "$T/status-recovering.log" "state=recovering"

# An engine-owned status error remains authoritative while status.json exists.
printf '{"ready":false,"last_error":"no_endpoint"}\n' > "$WARP_STATUS"
_out="$(warp_status)"
printf '%s\n' "$_out" > "$T/status-engine-error.log"
assert_contains "engine error is preserved" "$T/status-engine-error.log" "error=no_endpoint"
assert_contains "engine error is not connecting" "$T/status-engine-error.log" "state=error"

# Transport readiness without platform routing is a distinct state.
printf '{"ready":true,"iface":"z2ktun0","transport":"wg"}\n' > "$WARP_STATUS"
: > "$WARP_LOG"
printf '7777\n' > "$T/pidof.out"
: > "$T/link-z2ktun0"
rm -f "$T/ip-rules" "$T/ip-route-989" "$WARP_PBR_OWNER"
unset HAVE_NFT
_out="$(warp_status)"
printf '%s\n' "$_out" > "$T/status-no-route.log"
assert_contains "transport ready is visible" "$T/status-no-route.log" "ready=1"
assert_contains "routing proof is separate" "$T/status-no-route.log" "route_ready=0"
assert_contains "missing routing is not ready" "$T/status-no-route.log" "state=tunnel"

# Full platform proof requires the live interface, nft TUN chains, exact PBR
# rule/route, and the adapter ownership record together.
printf '500: from all fwmark 0x80000000/0x80000000 lookup 989\n' > "$T/ip-rules"
printf 'default dev z2ktun0\n' > "$T/ip-route-989"
cat > "$WARP_PBR_OWNER" <<'EOF'
mark=0x80000000
mask=0x80000000
pref=500
table=989
iface=z2ktun0
EOF
export HAVE_NFT=1
_out="$(warp_status)"
printf '%s\n' "$_out" > "$T/status-ready.log"
assert_contains "routing proof is true" "$T/status-ready.log" "route_ready=1"
assert_contains "complete state is ready" "$T/status-ready.log" "state=ready"

_t_done
