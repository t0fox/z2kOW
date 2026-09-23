#!/bin/sh
# Regression: WARP instance registration can be skipped when the startup
# mutation lock is busy; the existing WARP tick must re-register it once.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-missing-instance"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpmiss.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

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
printf 'GAME_WARP_ENABLED=1\n' > "$Z2K_CONFIG"
printf '{"id":"mock-device","addr":"172.16.9.9"}\n' > "$WARP_DEVICE"
printf '{"ready":false}\n' > "$WARP_STATUS"
: > "$CALLS"

. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
Z2K_WARP_SOURCE_ONLY=1
. "$REPO/platform/openwrt/warp.sh" || exit 1

# Isolate the missing-process branch while preserving the real check dispatcher,
# mutation lock and procd-service rebuild helper.
z2k_ow_core_ready() { return 0; }
warp_note_death() { :; }
_warp_converge_off_keep_probe() { echo fail-open >> "$CALLS"; return 0; }
_z2k_ow_service_running() { return 0; }
procd_open_instance() { echo "procd:$1" >> "$CALLS"; }
procd_set_param() { :; }
procd_close_instance() { :; }
_z2k_ow_warp_service_restart() {
    echo restart >> "$CALLS"
    # Model the owning init service's stop phase: the retry latch must survive
    # this internal restart, but is cleared by the new successful registration.
    z2k_ow_warp 0 >/dev/null 2>&1
    [ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo recovery-preserved >> "$CALLS"
    warp_start_instance
}
_warp_wait_and_pbr() { echo bounded-ready-wait >> "$CALLS"; return 0; }
warp_pbr_down() { return 0; }
warp_nft_remove() { return 0; }

# No process and no procd registration: one bounded owner-service rebuild is
# needed. Without the regression fix, check only leaves the feature fail-open.
z2k_ow_warp check >/dev/null 2>&1
assert_eq "missing procd instance is re-registered once" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"
assert_eq "internal restart preserves one-shot latch until registration" "1" "$(grep -c '^recovery-preserved$' "$CALLS" 2>/dev/null || true)"
assert_eq "rebuild waits for proven ready before PBR" "1" "$(grep -c '^bounded-ready-wait$' "$CALLS" 2>/dev/null || true)"
assert_eq "registered instance marker exists" "1" "$([ -e "$WARP_PROCD_INSTANCE_FILE" ] && echo 1 || echo 0)"
assert_eq "recovery attempt cleared after registration" "0" "$([ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo 1 || echo 0)"

# A registered instance whose process is down is left to procd's bounded
# respawn; the cron check must not reset that budget by restarting z2k.
z2k_ow_warp check >/dev/null 2>&1
assert_eq "registered instance is left to procd" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"

# Missing registration is not enough to restart an owning service which is
# itself stopped; this protects intentional stop from resurrection.
rm -f "$WARP_PROCD_INSTANCE_FILE" "$WARP_PROCD_RECOVERY_FILE"
_z2k_ow_service_running() { return 1; }
z2k_ow_warp check >/dev/null 2>&1
assert_eq "inactive owner service is not resurrected" "1" "$(grep -c '^restart$' "$CALLS" 2>/dev/null || true)"
_z2k_ow_service_running() { return 0; }

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
warp_pbr_down() { return 0; }
warp_nft_remove() { return 0; }
: > "$WARP_PROCD_INSTANCE_FILE"
z2k_ow_warp 0 >/dev/null 2>&1
assert_eq "intentional stop removes registration marker" "0" "$([ -e "$WARP_PROCD_INSTANCE_FILE" ] && echo 1 || echo 0)"
assert_eq "intentional stop clears stale recovery latch" "0" "$([ -e "$WARP_PROCD_RECOVERY_FILE" ] && echo 1 || echo 0)"
assert_eq "stop preserves selected WARP setting" "1" "$(warp_flag)"

_t_done
