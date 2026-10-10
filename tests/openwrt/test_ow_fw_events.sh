#!/bin/sh
# Coalesce firewall reload events into one bounded OpenWrt fw4 reconciliation.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-fw-events"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-fw-events.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/run" "$T/bin"
export Z2K_RUN="$T/run" Z2K_FW_EVENT_SETTLE=0 Z2K_FW_EVENT_MAX_ATTEMPTS=3
. "$REPO/platform/openwrt/firewall.sh" || exit 1

if ! command -v z2k_ow_fw_event >/dev/null 2>&1; then
    _t_bad "fw4 event recovery entrypoint exists"
else
    _t_ok
fi

if command -v z2k_ow_fw_event >/dev/null 2>&1; then
    # A reload arriving while the first repair runs must leave a pending bit;
    # the owner consumes it and verifies the settled state before returning.
    : > "$T/run/core-ready"
    : > "$T/reload-once"
    printf 'broken\n' > "$T/dataplane"
    calls=0
    z2k_ow_fw_check() {
        calls=$((calls + 1))
        if [ -f "$T/reload-once" ]; then
            rm -f "$T/reload-once"
            z2k_ow_fw_event reload >/dev/null 2>&1 || true
            printf 'broken\n' > "$T/dataplane"
        else
            printf 'healthy\n' > "$T/dataplane"
        fi
        return 0
    }
    z2k_ow_fw_verify() { [ "$(cat "$T/dataplane")" = healthy ]; }
    z2k_ow_fw_event reload
    assert_eq "reload during repair is reconciled" "0" "$?"
    assert_eq "lost event causes a trailing reconciliation" "2" "$calls"
    assert_eq "final fw4 state is verified" healthy "$(cat "$T/dataplane")"
    [ ! -e "$T/run/fw-recovery.pending" ] && _t_ok || _t_bad "pending event drained"

    # A process storm shares one owner, never runs parallel checkers, and caps
    # total repair attempts even when every callback arrives during a repair.
    : > "$T/run/core-ready"
    rm -f "$T/active.lock" "$T/overlap"
    : > "$T/check.count"
    printf 'healthy\n' > "$T/dataplane"
    cat > "$T/worker.sh" <<'EOF'
#!/bin/sh
. "$FIREWALL_ADAPTER" || exit 1
z2k_ow_fw_check() {
        mkdir "$T/active.lock" 2>/dev/null || : > "$T/overlap"
        printf '%s\n' check >> "$T/check.count"
        sleep 0.05
        rmdir "$T/active.lock" 2>/dev/null || true
        return 0
    }
z2k_ow_fw_verify() { [ "$(cat "$T/dataplane")" = healthy ]; }
z2k_ow_fw_event storm
EOF
    chmod +x "$T/worker.sh"
    export T FIREWALL_ADAPTER="$REPO/platform/openwrt/firewall.sh"
    i=0
    while [ "$i" -lt 20 ]; do
        "$T/worker.sh" &
        i=$((i + 1))
    done
    wait
    [ ! -e "$T/overlap" ] && _t_ok || _t_bad "event storm has one active reconciler"
    _checks=$(wc -l < "$T/check.count" | tr -d ' ')
    [ "$_checks" -le 3 ] && [ "$_checks" -ge 1 ] && _t_ok || _t_bad "storm repair attempts are bounded (count=$_checks)"

    # An event that reappears during every attempt must stop at the configured
    # ceiling and remain marked for the existing periodic convergence pass.
    attempts=0
    z2k_ow_fw_check() {
        attempts=$((attempts + 1))
        z2k_ow_fw_event storm >/dev/null 2>&1 || true
    }
    z2k_ow_fw_verify() { return 0; }
    z2k_ow_fw_event storm >/dev/null 2>&1
    assert_eq "continuous storm reports the undrained event" 1 "$?"
    assert_eq "continuous storm stops exactly at its bounded ceiling" 3 "$attempts"
    [ -e "$T/run/fw-recovery.pending" ] && _t_ok || _t_bad "undrained storm remains pending for periodic convergence"

    # Persistent drift fails the final-state proof after the bounded attempts.
    : > "$T/run/core-ready"
    attempts=0
    z2k_ow_fw_check() { attempts=$((attempts + 1)); return 0; }
    z2k_ow_fw_verify() { return 1; }
    z2k_ow_fw_event reload >/dev/null 2>&1
    assert_eq "unverified final firewall state is reported" 1 "$?"
    [ "$attempts" -le 3 ] && [ "$attempts" -ge 1 ] && _t_ok || _t_bad "failed-state retries are bounded (count=$attempts)"

    # A killed recovery process leaves only its pid lock; the next event can
    # reclaim it and still prove the current dataplane.
    printf '99999999\n' > "$T/run/fw-recovery.lock"
    : > "$T/run/core-ready"
    attempts=0
    z2k_ow_fw_check() { attempts=$((attempts + 1)); return 0; }
    z2k_ow_fw_verify() { return 0; }
    z2k_ow_fw_event reload >/dev/null 2>&1
    assert_eq "event reclaims a dead-owner lock" 0 "$?"
    [ ! -e "$T/run/fw-recovery.lock" ] && _t_ok || _t_bad "dead-owner lock released after recovery"
    assert_eq "stale-lock recovery still verifies final state" 1 "$attempts"
fi

# Exercise the init callback with procd/config dependencies stubbed at their
# documented shell boundary; the callback still executes the real event path.
INIT="$REPO/platform/openwrt/files/etc/init.d/z2k"
# shellcheck disable=SC1090
. "$INIT" || exit 1
procd_add_reload_trigger() { printf '%s\n' "$*" >> "$T/procd-triggers"; }
z2k_load_adapter() { return 0; }
z2k_ow_fw_event() { printf '%s\n' "$1" >> "$T/reload-callback"; return 0; }
mkdir -p "$T/etc"
printf 'INIT_APPLY_FW=1\n' > "$T/etc/config"
export Z2K_CONFIG="$T/etc/config" Z2K_CORE_READY="$T/run/core-ready"
: > "$Z2K_CORE_READY"
service_triggers
reload_service
assert_contains "procd listens to firewall config changes" "$T/procd-triggers" firewall
assert_eq "native reload callback invokes event reconciliation" reload "$(cat "$T/reload-callback")"

# Retain explicit source contracts for the artifact review.
assert_contains "z2k subscribes to the native firewall reload trigger" "$INIT" 'procd_add_reload_trigger firewall'
assert_contains "z2k reload callback converges through fw event recovery" "$INIT" 'z2k_ow_fw_event reload'
assert_not_contains "recovery does not launch a second firewall worker" "$INIT" 'fw-check.sh.*&'

_t_done
