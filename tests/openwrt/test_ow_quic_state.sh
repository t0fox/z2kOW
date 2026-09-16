#!/bin/sh
# tests/openwrt/test_ow_quic_state.sh - OpenWrt QUIC state migration.
. "$(dirname "$0")/helper.sh"

_t_plan "ow-quic-state"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-state.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_STATE="$T/etc/z2k/state"
export STATE_FILE="$Z2K_STATE/state.tsv"
export Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$T/tmp/z2k"
export Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE="$T/legacy/z2k-autocircular-state.tsv"
export Z2K_QUIC_STATE_MIGRATION_MARKER="$Z2K_STATE/quic-pool-key-migrated"
mkdir -p "$Z2K_STATE" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE" "$(dirname "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE")" || exit 1
. "$REPO/platform/openwrt/state.sh" || exit 1
_tab="$(printf '\t')"

_write_old() {
    printf '# state\nyt_quic\tyoutube.example\t7\t123\tauto\n' > "$1"
    printf 'rkn_tcp\trkn.example\t4\t456\tauto\n' >> "$1"
}

_write_old "$STATE_FILE"
_write_old "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv"
_write_old "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE"
chmod 640 "$STATE_FILE" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE"
_primary_meta="$(stat -c '%a:%u:%g' "$STATE_FILE" 2>/dev/null)"
_fallback_meta="$(stat -c '%a:%u:%g' "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" 2>/dev/null)"

if z2k_ow_migrate_quic_state; then _t_ok; else _t_bad "primary/fallback migration failed"; fi
assert_contains "primary canonical pool" "$STATE_FILE" "quic${_tab}youtube.example${_tab}7${_tab}123${_tab}auto"
assert_contains "fallback canonical pool" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "quic${_tab}youtube.example${_tab}7${_tab}123${_tab}auto"
assert_contains "legacy fallback canonical pool" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE" "quic${_tab}youtube.example${_tab}7${_tab}123${_tab}auto"
assert_not_contains "primary has no legacy pool" "$STATE_FILE" "^yt_quic${_tab}"
assert_not_contains "fallback has no legacy pool" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "^yt_quic${_tab}"
assert_not_contains "legacy fallback has no legacy pool" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE" "^yt_quic${_tab}"
assert_contains "unrelated primary pool preserved" "$STATE_FILE" "rkn_tcp${_tab}rkn.example${_tab}4${_tab}456${_tab}auto"
assert_contains "unrelated fallback pool preserved" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "rkn_tcp${_tab}rkn.example${_tab}4${_tab}456${_tab}auto"
assert_file "completion marker" "$Z2K_QUIC_STATE_MIGRATION_MARKER"
assert_eq "primary metadata preserved" "$_primary_meta" "$(stat -c '%a:%u:%g' "$STATE_FILE" 2>/dev/null)"
assert_eq "fallback metadata preserved" "$_fallback_meta" "$(stat -c '%a:%u:%g' "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" 2>/dev/null)"

# Idempotency and marker advisory behavior: a later legacy fallback is still
# inspected despite the marker left by the first successful run.
_before_primary="$(cksum "$STATE_FILE")"
printf 'yt_quic\tlater.example\t9\t789\tauto\n' >> "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv"
if z2k_ow_migrate_quic_state; then _t_ok; else _t_bad "marker bypassed later fallback migration"; fi
assert_contains "later fallback legacy row migrated" "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "quic${_tab}later.example${_tab}9${_tab}789${_tab}auto"
assert_eq "idempotent primary bytes" "$_before_primary" "$(cksum "$STATE_FILE")"

# Busy lock: no state corruption, no completion marker, and a later retry can
# finish. The fallback is intentionally allowed to migrate before busy primary
# is reported; marker remains absent until both are complete.
rm -f "$Z2K_QUIC_STATE_MIGRATION_MARKER"
_write_old "$STATE_FILE"
printf '%s' "$(date +%s)" > "$STATE_FILE.lock"
if z2k_ow_migrate_quic_state; then
    _t_bad "busy primary lock did not fail lifecycle"
else
    _t_ok
fi
assert_contains "busy primary left legacy row intact" "$STATE_FILE" "yt_quic${_tab}youtube.example${_tab}7${_tab}123${_tab}auto"
if [ ! -f "$Z2K_QUIC_STATE_MIGRATION_MARKER" ]; then _t_ok; else _t_bad "marker set while primary lock busy"; fi
rm -f "$STATE_FILE.lock"
if z2k_ow_migrate_quic_state; then _t_ok; else _t_bad "retry after busy lock failed"; fi
assert_contains "retry migrated primary" "$STATE_FILE" "quic${_tab}youtube.example${_tab}7${_tab}123${_tab}auto"
assert_file "marker after all state files" "$Z2K_QUIC_STATE_MIGRATION_MARKER"

# Missing/empty state files are valid on fresh install and must not create a
# spurious completion marker or block daemon startup.
rm -f "$Z2K_QUIC_STATE_MIGRATION_MARKER" "$STATE_FILE" \
    "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" \
    "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE"
if z2k_ow_migrate_quic_state; then _t_ok; else _t_bad "empty state blocked startup"; fi
if [ ! -f "$Z2K_QUIC_STATE_MIGRATION_MARKER" ]; then _t_ok; else _t_bad "marker set for missing/empty files"; fi

# Lifecycle source proof: migration is loaded and called after preflight but
# before the first procd instance is opened.
SVC="$REPO/package/openwrt/files/etc/init.d/z2k"
assert_contains "state adapter loaded" "$SVC" 'platform/openwrt/state.sh'
assert_contains "state migration called" "$SVC" 'z2k_ow_migrate_quic_state || return 1'
_pre="$(grep -n 'z2k_ow_runtime_preflight' "$SVC" | head -1 | cut -d: -f1)"
_mig="$(grep -n 'z2k_ow_migrate_quic_state || return 1' "$SVC" | head -1 | cut -d: -f1)"
_procd="$(grep -n 'procd_open_instance "z2k"' "$SVC" | head -1 | cut -d: -f1)"
if [ -n "$_pre" ] && [ -n "$_mig" ] && [ -n "$_procd" ] && [ "$_pre" -lt "$_mig" ] && [ "$_mig" -lt "$_procd" ]; then
    _t_ok
else
    _t_bad "migration ordering is not preflight -> migration -> procd"
fi

_t_done
