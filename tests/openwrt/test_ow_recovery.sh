#!/bin/sh
# test_ow_recovery.sh - core consumer recovery through the existing fw-check
# convergence path. No second watchdog is allowed: procd owns respawn and the
# already scheduled fw-check only reconciles ready/degraded state.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-recovery"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-recovery.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/run" "$T/etc"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_RUN="$T/run"
export Z2K_CONFIG="$T/etc/config" Z2K_CORE_READY="$T/run/core-ready"
export Z2K_NFQUEUE_PROC="$T/nfqueue" QNUM=200 INIT_APPLY_FW=1
printf 'ENABLED=1\nQNUM=200\n' > "$T/etc/config"

cat > "$T/init-stub" <<EOF
#!/bin/sh
[ -f "$T/stopped" ] && exit 1
exit 0
EOF
chmod +x "$T/init-stub"
export INIT_SCRIPT="$T/init-stub"

. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/firewall.sh" || exit 1

sleep 60 & _pid=$!
printf '%s\n' "$_pid" > "$T/run/nfqws2.pid"
printf '200 %s 0 2 65531 0 0 0 1\n' "$_pid" > "$T/nfqueue"
: > "$T/run/core-ready"
z2k_ow_fw_verify() { echo verify >> "$T/calls"; return 0; }
z2k_ow_fw_apply() { echo apply >> "$T/calls"; return 0; }
z2k_ow_offload_prepare() { echo prepare >> "$T/calls"; return 0; }

# Healthy state remains ready and does not need a repair.
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "healthy check" "0" "$?"
[ -f "$T/run/core-ready" ] && _t_ok || _t_bad "healthy: ready снят"

# Reproduce crash: PID/queue owner disappear while procd still reports the
# service running. Existing health convergence must mark degraded and must not
# reapply firewall or create another process.
kill "$_pid" 2>/dev/null
rm -f "$T/nfqueue"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "crash check" "0" "$?"
[ ! -f "$T/run/core-ready" ] && _t_ok || _t_bad "crash: stale ready остался"
grep -q '^apply$' "$T/calls" && _t_bad "crash: firewall reapply без consumer" || _t_ok

# A live PID with a different NFQUEUE owner is still not our consumer.
sleep 60 & _wrong_pid=$!
printf '%s\n' "$_wrong_pid" > "$T/run/nfqws2.pid"
printf '200 999999 0 2 65531 0 0 0 1\n' > "$T/nfqueue"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
[ ! -f "$T/run/core-ready" ] && _t_ok || _t_bad "owner mismatch: ready создан"
grep -q '^verify$' "$T/calls" && _t_bad "owner mismatch: verify продолжен" || _t_ok
kill "$_wrong_pid" 2>/dev/null

# Reproduce procd recovery: a new PID owns the same queue. The same existing
# fw-check path restores ready only after the owner check and static verify.
sleep 60 & _pid=$!
printf '%s\n' "$_pid" > "$T/run/nfqws2.pid"
printf '200 %s 0 2 65531 0 0 0 1\n' "$_pid" > "$T/nfqueue"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "recovery check" "0" "$?"
[ -f "$T/run/core-ready" ] && _t_ok || _t_bad "recovery: ready не восстановлен"
grep -q '^verify$' "$T/calls" && _t_ok || _t_bad "recovery: static verify не вызван"

# Intentional stop fence: even if the old process is still visible during the
# stop race, the scheduled checker must not resurrect ready/firewall state.
: > "$T/run/stopping"
: > "$T/run/core-ready"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "intentional stop check" "0" "$?"
[ ! -f "$T/run/core-ready" ] && _t_ok || _t_bad "stop: ready resurrected"
grep -q '^apply$' "$T/calls" && _t_bad "stop: firewall resurrected" || _t_ok
kill "$_pid" 2>/dev/null

_t_done
