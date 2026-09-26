#!/bin/sh
# tests/test_warp_install_hooks.sh — реальные WARP lifecycle edges установщика.
# Статически проверяются только install destination и состав rollback; refresh,
# remove, stale-download cleanup и scheduler cadence исполняют production code.
# POSIX sh.

TESTS_PASSED=0
TESTS_FAILED=0
assert_eq() {
    if [ "$2" = "$3" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); printf "[PASS] %s\n" "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); printf "[FAIL] %s: expected [%s] got [%s]\n" "$1" "$2" "$3"
    fi
}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
I="$SCRIPT_DIR/lib/install.sh"
S="$SCRIPT_DIR/files/z2k-scheduler.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

. "$I"
print_info() { :; }
print_success() { :; }
print_warning() { :; }
print_error() { :; }

# These are delivery and ownership contracts: the optional init/hook are
# installed at their canonical paths, and the replaced daemon is rollbackable.
assert_eq "install maps WARP init to its service path" "1" "$(grep -F -c 'files/init.d/S51z2k-warp"                 "/opt/etc/init.d/S51z2k-warp"' "$I")"
assert_eq "install maps WARP hook to NDM destination" "1" \
    "$([ "$(grep -F -c 'files/ndm/93-z2k-warp.sh' "$I")" -eq 1 ] && \
       [ "$(grep -F -c '"/opt/etc/ndm/netfilter.d/93-z2k-warp.sh"' "$I")" -eq 1 ] && echo 1 || echo 0)"
case " $ROLLBACK_SBIN_BINS " in *" z2k-warpd "*) _rollback_warp=yes ;; *) _rollback_warp=no ;; esac
case " $ROLLBACK_SBIN_BINS " in *" z2k-usque "*) _rollback_usque=yes ;; *) _rollback_usque=no ;; esac
assert_eq "rollback owns installed WARP engine" yes "$_rollback_warp"
assert_eq "rollback excludes retired usque engine" no "$_rollback_usque"
assert_eq "rollback restarts WARP through its owned init" /opt/etc/init.d/S51z2k-warp \
    "$( _rollback_service_for_binary z2k-warpd )"

# Exercise the same refresh helper called by step_finalize. A missing engine is
# migration-only; an installed engine is refreshed after migration. Failures
# must reach step_finalize so the install transaction rolls back.
WARP_CALL_LOG="$TMP/warp.calls"
export WARP_CALL_LOG
WARP_SCRIPT="$TMP/z2k-warp.sh"
WARP_BIN="$TMP/sbin/z2k-warpd"
mkdir -p "$TMP/sbin"
cat > "$WARP_SCRIPT" <<'WARP'
#!/bin/sh
printf '%s\n' "$1" >> "$WARP_CALL_LOG"
case "$1" in
    migrate) [ "${FAIL_MIGRATE:-0}" = 0 ] ;;
    install) [ "${FAIL_INSTALL:-0}" = 0 ] ;;
    remove) [ "${FAIL_REMOVE:-0}" = 0 ] ;;
esac
WARP
chmod +x "$WARP_SCRIPT"

: > "$WARP_CALL_LOG"
_rc=0; z2k_refresh_installed_warp "$WARP_SCRIPT" "$WARP_BIN" || _rc=$?
assert_eq "refresh without installed engine succeeds" 0 "$_rc"
assert_eq "refresh without engine only runs migration" migrate "$(cat "$WARP_CALL_LOG")"

_rc=0; z2k_refresh_installed_warp "$TMP/missing-z2k-warp.sh" "$TMP/missing-engine" || _rc=$?
assert_eq "uninstalled WARP stays optional without its manager" 0 "$_rc"

touch "$WARP_BIN"; chmod +x "$WARP_BIN"
: > "$WARP_CALL_LOG"
_rc=0; z2k_refresh_installed_warp "$TMP/missing-z2k-warp.sh" "$WARP_BIN" || _rc=$?
assert_eq "installed WARP without its manager aborts transaction" 1 "$_rc"
: > "$WARP_CALL_LOG"
_rc=0; z2k_refresh_installed_warp "$WARP_SCRIPT" "$WARP_BIN" || _rc=$?
assert_eq "refresh installed engine succeeds" 0 "$_rc"
assert_eq "refresh migrates before installing" "$(printf 'migrate\ninstall')" "$(cat "$WARP_CALL_LOG")"

: > "$WARP_CALL_LOG"; FAIL_MIGRATE=1; export FAIL_MIGRATE
_rc=0; z2k_refresh_installed_warp "$WARP_SCRIPT" "$WARP_BIN" || _rc=$?
assert_eq "migration failure aborts refresh" 1 "$_rc"
assert_eq "migration failure prevents engine install" migrate "$(cat "$WARP_CALL_LOG")"
unset FAIL_MIGRATE

: > "$WARP_CALL_LOG"; FAIL_INSTALL=1; export FAIL_INSTALL
_rc=0; z2k_refresh_installed_warp "$WARP_SCRIPT" "$WARP_BIN" || _rc=$?
assert_eq "installed engine refresh failure reaches rollback path" 1 "$_rc"
assert_eq "failed refresh follows migration" "$(printf 'migrate\ninstall')" "$(cat "$WARP_CALL_LOG")"
unset FAIL_INSTALL

# Uninstall removes only runtime artifacts after the engine accepted remove;
# on failure, keep hooks/files so the installed service can still be recovered.
mkdir -p "$TMP/init" "$TMP/ndm" "$TMP/run" "$TMP/runtime" "$TMP/persistent"
touch "$TMP/init/S51z2k-warp" "$TMP/ndm/93-z2k-warp.sh" "$TMP/run/z2k-warpd.pid"
touch "$TMP/runtime/cache" "$TMP/persistent/device.json"
: > "$WARP_CALL_LOG"; FAIL_REMOVE=1; export FAIL_REMOVE
_rc=0
z2k_remove_warp_installation "$WARP_SCRIPT" "$TMP/init/S51z2k-warp" \
    "$TMP/ndm/93-z2k-warp.sh" "$TMP/run/z2k-warpd.pid" "$TMP/runtime" "$WARP_BIN" || _rc=$?
assert_eq "failed engine removal is reported" 1 "$_rc"
assert_eq "failed engine removal keeps init hook and pid" yes \
    "$([ -f "$TMP/init/S51z2k-warp" ] && [ -f "$TMP/ndm/93-z2k-warp.sh" ] && [ -f "$TMP/run/z2k-warpd.pid" ] && echo yes || echo no)"
unset FAIL_REMOVE
_rc=0
z2k_remove_warp_installation "$WARP_SCRIPT" "$TMP/init/S51z2k-warp" \
    "$TMP/ndm/93-z2k-warp.sh" "$TMP/run/z2k-warpd.pid" "$TMP/runtime" "$WARP_BIN" || _rc=$?
assert_eq "successful engine removal cleans runtime artifacts" 0 "$_rc"
assert_eq "successful engine removal preserves device identity" yes "$([ -f "$TMP/persistent/device.json" ] && echo yes || echo no)"
assert_eq "successful engine removal removes init and NDM hook" no \
    "$([ -e "$TMP/init/S51z2k-warp" ] || [ -e "$TMP/ndm/93-z2k-warp.sh" ] && echo yes || echo no)"

# Load the exact production scheduler functions without running its daemon loop.
# This keeps cadence and state assertions behavioral while leaving startup and
# the ordinary long-lived supervisor lifecycle untouched.
extract_function() {
    awk -v name="$2" '
        BEGIN { pattern = "^" name "\\(\\)[[:space:]]*\\{" }
        !active && $0 ~ pattern { active = 1; found = 1 }
        active {
            print
            line = $0
            opens = 0; rest = line
            while ((pos = index(rest, "{")) > 0) { opens++; rest = substr(rest, pos + 1) }
            closes = 0; rest = line
            while ((pos = index(rest, "}")) > 0) { closes++; rest = substr(rest, pos + 1) }
            depth += opens - closes
            if (depth == 0) exit
        }
        END { if (!found) exit 1 }
    ' "$1"
}

# Capture and execute the real production dispatch statement with fixture-owned
# state. Removing a call site therefore fails this suite while the lifecycle
# helpers remain exercised against temporary files above.
extract_call() {
    awk -v name="$2" '
        !active && $0 ~ "^[[:space:]]*" name "[[:space:]]+" { active = 1 }
        active {
            print
            if ($0 !~ /\\[[:space:]]*$/) exit
        }
        END { if (!active) exit 1 }
    ' "$1"
}

_refresh_call=$(extract_call "$I" z2k_refresh_installed_warp 2>/dev/null)
assert_eq "installer production refresh dispatch is present" yes "$([ -n "$_refresh_call" ] && echo yes || echo no)"
_refresh_args="$TMP/refresh.dispatch"
z2k_refresh_installed_warp() {
    printf '%s|%s\n' "$1" "$2" >> "$_refresh_args"
    [ "${DISPATCH_FAIL:-0}" = 0 ]
}
run_installer_refresh_dispatch() { eval "$_refresh_call"; }
: > "$_refresh_args"
ZAPRET2_DIR="$TMP/installed-root"; DISPATCH_FAIL=0
run_installer_refresh_dispatch; _rc=$?
assert_eq "installer dispatch calls refresh with production paths" \
    "$TMP/installed-root/z2k-warp.sh|/opt/sbin/z2k-warpd" "$(cat "$_refresh_args")"
assert_eq "installer refresh dispatch succeeds" 0 "$_rc"
DISPATCH_FAIL=1
_rc=0; run_installer_refresh_dispatch || _rc=$?
assert_eq "installer refresh dispatch propagates failure to transaction" 1 "$_rc"
unset DISPATCH_FAIL

_remove_call=$(extract_call "$I" z2k_remove_warp_installation 2>/dev/null)
assert_eq "uninstall production removal dispatch is present" yes "$([ -n "$_remove_call" ] && echo yes || echo no)"
_remove_args="$TMP/remove.dispatch"
z2k_remove_warp_installation() {
    printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$_remove_args"
    [ "${DISPATCH_FAIL:-0}" = 0 ]
}
run_uninstall_warp_dispatch() { eval "$_remove_call"; }
: > "$_remove_args"
ZAPRET2_DIR="$TMP/uninstall-root"; DISPATCH_FAIL=0
run_uninstall_warp_dispatch; _rc=$?
assert_eq "uninstall dispatch supplies all production-owned paths" \
    "$TMP/uninstall-root/z2k-warp.sh|/opt/etc/init.d/S51z2k-warp|/opt/etc/ndm/netfilter.d/93-z2k-warp.sh|/var/run/z2k-warpd.pid|/tmp/z2k-warp|/opt/sbin/z2k-warpd" \
    "$(cat "$_remove_args")"
assert_eq "uninstall dispatch succeeds" 0 "$_rc"
DISPATCH_FAIL=1
_rc=0; run_uninstall_warp_dispatch || _rc=$?
assert_eq "uninstall dispatch stops on failed WARP removal" 1 "$_rc"
unset DISPATCH_FAIL
for _fn in last_fired_in mark_fired_in z2k_scheduler_warp_selfheal_tick; do
    extract_function "$S" "$_fn" >> "$TMP/scheduler-functions.sh" || :
done
[ -f "$TMP/scheduler-functions.sh" ] && . "$TMP/scheduler-functions.sh"
_scheduler_call=$(extract_call "$S" z2k_scheduler_warp_selfheal_tick 2>/dev/null)
assert_eq "scheduler production selfheal dispatch is present" yes "$([ -n "$_scheduler_call" ] && echo yes || echo no)"
run_scheduler_warp_dispatch() { eval "$_scheduler_call"; }
mkdir -p "$TMP/scheduler-root"
cat > "$TMP/scheduler-root/z2k-warp.sh" <<'SCHED_WARP'
#!/bin/sh
printf '%s\n' "$1" >> "$WARP_CALL_LOG"
SCHED_WARP
chmod +x "$TMP/scheduler-root/z2k-warp.sh"
: > "$WARP_CALL_LOG"
ZAPRET2_DIR="$TMP/scheduler-root"; TMP_STATE="$TMP/warp-state"; now_epoch=100
_rc=0; run_scheduler_warp_dispatch || _rc=$?
_pid=$!; [ -n "$_pid" ] && wait "$_pid" 2>/dev/null || :
assert_eq "scheduler first tick launches WARP selfheal" selfheal "$(cat "$WARP_CALL_LOG" 2>/dev/null)"
assert_eq "scheduler records first WARP selfheal tick" warp-selfheal-epoch=100 "$(cat "$TMP/warp-state" 2>/dev/null)"
now_epoch=124; run_scheduler_warp_dispatch
_pid=$!; [ -n "$_pid" ] && wait "$_pid" 2>/dev/null || :
assert_eq "scheduler suppresses selfheal before 25 seconds" 1 "$(wc -l < "$WARP_CALL_LOG" | tr -d ' ')"
now_epoch=125; run_scheduler_warp_dispatch
_pid=$!; [ -n "$_pid" ] && wait "$_pid" 2>/dev/null || :
assert_eq "scheduler launches selfheal at the 25-second boundary" 2 "$(wc -l < "$WARP_CALL_LOG" | tr -d ' ')"
assert_eq "scheduler advances cadence marker after launch" warp-selfheal-epoch=125 "$(cat "$TMP/warp-state")"

# The retired service control surface must never be restored by emergency cleanup.
C="$SCRIPT_DIR/z2k_cleanup.sh"
assert_eq "emergency cleanup never restores S51usque" 0 "$(grep -c 'S51usque' "$C")"

printf "\nPASSED: %d\nFAILED: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
