#!/bin/sh
# Regression: WARP instance registration can be skipped when the startup
# mutation lock is busy; the existing WARP tick must re-register it once.
. "$(dirname "$0")/helper.sh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "${1:-}" = "--inside" ]; then
    T="$2"
else
    for tool in cargo unshare ip nft; do
        command -v "$tool" >/dev/null 2>&1 || { echo "требуется реальный инструмент $tool" >&2; exit 1; }
    done
    T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpmiss.XXXXXX")" || exit 1
    _cleanup() {
        _rc=$?
        trap - EXIT HUP INT TERM
        if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
            sudo -n rm -rf "$T" || _rc=$?
        else
            rm -rf "$T" || _rc=$?
        fi
        exit "$_rc"
    }
    trap _cleanup EXIT HUP INT TERM
    CARGO_TARGET_DIR="$T/cargo-target"
    export CARGO_TARGET_DIR
    cargo build --locked --manifest-path "$REPO/platform/openwrt/warp-controller/Cargo.toml" --bin z2k-warp-controller || exit 1
    export WARP_CONTROLLER_BIN="$CARGO_TARGET_DIR/debug/z2k-warp-controller"
    if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
        sudo -n unshare -n sh "$0" --inside "$T"
    elif [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ]; then
        unshare -n sh "$0" --inside "$T"
    else
        unshare -Urn sh "$0" --inside "$T"
    fi
    exit $?
fi

_t_plan "ow-warp-missing-instance"

mkdir -p "$T/bin" "$T/etc/state/warp" "$T/tmp/warp" "$T/lists/warp/games" "$T/proc"
export PATH="$T/bin:$PATH"
export Z2K_ROOT="$REPO" Z2K_BIN="$T/bin" Z2K_LIB="$REPO/lib"
export Z2K_ETC="$T/etc" Z2K_CONFIG="$T/etc/config" Z2K_STATE="$T/etc/state"
export Z2K_USER_LISTS="$T/etc/user-lists" Z2K_TMP="$T/tmp" Z2K_RUN="$T/tmp/runtime"
export Z2K_LISTS_DIR="$T/lists" Z2K_PROC_ROOT="$T/proc"
export WARP_BIN="$T/bin/z2k-warpd" WARP_DEVICE="$T/etc/state/warp/device.json"
export WARP_STATUS="$T/tmp/warp/status.json" WARP_LOG="$T/tmp/warp/warpd.log"
export WARP_READY_WAIT=1 WARP_LOCK_WAIT=2 WARP_LOCK_DIR="$T/tmp/warp/mutate.lock"
export WARP_PROCD_INSTANCE_FILE="$T/tmp/warp/procd-instance"
export WARP_PROCD_RECOVERY_FILE="$T/tmp/warp/procd-recovery-attempt"
export WARP_PROCD_REBUILD_FILE="$T/tmp/warp/procd-rebuild-in-progress"
export PROCD_WARP_PRESENT_FILE="$T/tmp/warp/procd-warp-present"
export CALLS="$T/calls"

cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$WARP_BIN" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/pidof" "$WARP_BIN"
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
[ "$1" = "-S" ] && [ "$2" = "call" ] && [ "$3" = "service" ] && [ "$4" = "list" ] || exit 2
if [ "${PROCD_SERVICE_MODE:-active}" = inactive ]; then
    printf '%s\n' '{"network":{}}'
    exit 0
fi
if [ "${PROCD_SERVICE_MODE:-active}" = unreadable ]; then exit 1; fi
if [ -e "$PROCD_WARP_PRESENT_FILE" ]; then
    printf '%s\n' '{"z2k":{"instances":{"z2k":{"running":true},"z2k-warp":{"running":false}}}}'
else
    printf '%s\n' '{"z2k":{"instances":{"z2k":{"running":true}}}}'
fi
EOF
chmod +x "$T/bin/ubus"
cat > "$T/bin/init" <<'EOF'
#!/bin/sh
case "${1:-}" in
    running) [ -e "$PROCD_WARP_PRESENT_FILE" ] ;;
    restart)
        echo restart >> "$CALLS"
        [ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo recovery-preserved >> "$CALLS"
        : > "$PROCD_WARP_PRESENT_FILE"
        printf 'registered\n' > "$WARP_PROCD_INSTANCE_FILE"
        rm -f "$WARP_PROCD_RECOVERY_FILE"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/init"
export Z2K_INIT="$T/bin/init"
printf 'GAME_WARP_ENABLED=1\n' > "$Z2K_CONFIG"
printf '{"id":"mock-device","addr":"172.16.9.9"}\n' > "$WARP_DEVICE"
printf '{"ready":false}\n' > "$WARP_STATUS"
: > "$CALLS"

. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
Z2K_WARP_SOURCE_ONLY=1
. "$REPO/platform/openwrt/warp.sh" || exit 1

# Check the Rust state machine and real iproute2/nftables in an isolated netns;
# only ubus/procd's owning init action is represented by the local fixture.
z2k_ow_core_ready() { return 0; }

# No process and no procd registration: one bounded owner-service rebuild is
# needed. The local marker is stale from an earlier registration and must not
# be trusted over the live procd registry.
printf 'registered\n' > "$WARP_PROCD_INSTANCE_FILE"
if z2k_ow_warp check >"$T/check-first.log" 2>&1; then
    _check_rc=0
else
    _check_rc=$?
    cat "$T/check-first.log"
fi
assert_eq "controller completes the bounded recovery check" 0 "$_check_rc"
assert_eq "missing procd instance is re-registered once" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"
assert_eq "internal restart preserves one-shot latch until registration" "1" "$(grep -c '^recovery-preserved$' "$CALLS" 2>/dev/null || true)"
assert_eq "registered instance marker exists" "1" "$([ -e "$WARP_PROCD_INSTANCE_FILE" ] && echo 1 || echo 0)"
assert_eq "recovery attempt cleared after registration" "0" "$([ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo 1 || echo 0)"

# A registered instance whose process is down is left to procd's bounded
# respawn; the cron check must not reset that budget by restarting z2k.
z2k_ow_warp check >/dev/null 2>&1
assert_eq "registered instance is left to procd" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"

# Missing registration is not enough to restart an owning service which is
# itself stopped; this protects intentional stop from resurrection.
rm -f "$WARP_PROCD_INSTANCE_FILE" "$WARP_PROCD_RECOVERY_FILE" "$PROCD_WARP_PRESENT_FILE"
PROCD_SERVICE_MODE=inactive; export PROCD_SERVICE_MODE
z2k_ow_warp check >/dev/null 2>&1
assert_eq "inactive owner service is not resurrected" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"
PROCD_SERVICE_MODE=active; export PROCD_SERVICE_MODE

# Failed first repair is bounded too: one failed attempt cannot restart the
# core service every minute until an operator or a new explicit action retries.
: > "$WARP_PROCD_RECOVERY_FILE"
z2k_ow_warp check >/dev/null 2>&1
assert_eq "failed recovery attempt is not looped" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"

# The regular lifecycle readiness gate also fences checks during an explicit
# main-service stop, even if stale WARP desired state still says enabled.
rm -f "$WARP_PROCD_RECOVERY_FILE"
z2k_ow_core_ready() { return 1; }
z2k_ow_warp check >/dev/null 2>&1
assert_eq "stopping/not-ready core is not resurrected" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"

# Stop removes the registration marker so a later intentional service start can
# register a fresh WARP instance, while config itself remains untouched.
: > "$WARP_PROCD_INSTANCE_FILE"
z2k_ow_warp 0 >/dev/null 2>&1
assert_eq "intentional stop removes registration marker" "0" "$([ -e "$WARP_PROCD_INSTANCE_FILE" ] && echo 1 || echo 0)"
assert_eq "intentional stop clears stale recovery latch" "0" "$([ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo 1 || echo 0)"
assert_eq "stop preserves selected WARP setting" "1" "$(warp_cfg GAME_WARP_ENABLED "")"

_t_done
