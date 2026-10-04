#!/bin/sh
# p-86.2 rotator-key migration, adapted to the OpenWrt procd lifecycle.
. "$(dirname "$0")/helper.sh"

_t_plan "ow-sld-state"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-sld.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_STATE="$T/etc/z2k/state"
export STATE_FILE="$Z2K_STATE/state.tsv"
export Z2K_TMP="$T/tmp/z2k"
export Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$Z2K_TMP"
export Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE="$T/legacy/z2k-autocircular-state.tsv"
export Z2K_SLD_STATE_MIGRATION_MARKER="$Z2K_STATE/domain-sld-v1.done"
mkdir -p "$Z2K_STATE" "$Z2K_TMP" "$(dirname "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE")" || exit 1
. "$REPO/platform/openwrt/state.sh" || exit 1
_tab="$(printf '\t')"
_fallback="$Z2K_TMP/z2k-autocircular-state.tsv"
_cksum_data() { cksum "$1" | awk '{ print $1 " " $2 }'; }

printf 'rkn_tcp\tapi.discord.com|4\t2\t100\tfrozen\tgood.example\nquic\tcdn.discord.com|4\t3\t200\tauto\n' > "$STATE_FILE"
printf 'rkn_tcp\twww.discord.com|4\t6\t150\tfrozen\tnew.example\nrkn_tcp\tapi.discord.com|6\t5\t110\tauto\ndiscord_udp\tnohost\t1\t200\tfrozen\nrkn_tcp\t1.2.3.4|4\t1\t200\tauto\n' > "$_fallback"
chmod 640 "$STATE_FILE" "$_fallback"
cp "$STATE_FILE" "$T/original-primary"
cp "$_fallback" "$T/original-fallback"

if z2k_ow_migrate_sld_state; then _t_ok; else _t_bad "merge/migration failed"; fi
assert_contains "frozen winner from fallback" "$STATE_FILE" "rkn_tcp${_tab}discord.com|4${_tab}6${_tab}150${_tab}frozen${_tab}new.example"
assert_contains "family kept separate" "$STATE_FILE" "rkn_tcp${_tab}discord.com|6${_tab}5${_tab}110${_tab}auto"
assert_contains "nohost untouched" "$STATE_FILE" "discord_udp${_tab}nohost${_tab}1"
assert_contains "IPv4 untouched" "$STATE_FILE" "rkn_tcp${_tab}1.2.3.4|4${_tab}1"
assert_eq "merged row count" "5" "$(awk '!/^#/ && NF {n++} END {print n+0}' "$STATE_FILE")"
assert_eq "persistent/fallback copies agree" "$(_cksum_data "$STATE_FILE")" "$(_cksum_data "$_fallback")"
assert_eq "primary backup preserved" "$(_cksum_data "$T/original-primary")" "$(_cksum_data "$STATE_FILE.pre-86.2")"
assert_eq "fallback backup preserved" "$(_cksum_data "$T/original-fallback")" "$(_cksum_data "$_fallback.pre-86.2")"
assert_eq "source mode preserved" "640" "$(stat -c '%a' "$STATE_FILE" 2>/dev/null)"
assert_file "completion marker" "$Z2K_SLD_STATE_MIGRATION_MARKER"

_before="$(cksum "$STATE_FILE")"
if z2k_ow_migrate_sld_state; then _t_ok; else _t_bad "repeat migration failed"; fi
assert_eq "repeat is byte-idempotent" "$_before" "$(cksum "$STATE_FILE")"

rm -f "$Z2K_SLD_STATE_MIGRATION_MARKER"
cp "$STATE_FILE" "$T/before-lock"
printf '%s' "$(date +%s)" > "$_fallback.lock"
if z2k_ow_migrate_sld_state; then _t_bad "busy fallback lock accepted"; else _t_ok; fi
assert_eq "busy migration leaves primary intact" "$(_cksum_data "$T/before-lock")" "$(_cksum_data "$STATE_FILE")"
assert_eq "busy migration leaves fallback intact" "$(_cksum_data "$T/before-lock")" "$(_cksum_data "$_fallback")"
assert_eq "busy migration writes no marker" "0" "$([ -f "$Z2K_SLD_STATE_MIGRATION_MARKER" ] && echo 1 || echo 0)"
rm -f "$_fallback.lock"

# The migration is called only after runtime preflight and before the procd
# core instance, through the existing OpenWrt state adapter.
SVC="$REPO/platform/openwrt/files/etc/init.d/z2k"
assert_contains "state adapter loaded" "$SVC" 'platform/openwrt/state.sh'
assert_contains "SLD migration called" "$SVC" 'z2k_ow_migrate_sld_state || return 1'
_pre="$(grep -n 'z2k_ow_runtime_preflight' "$SVC" | head -1 | cut -d: -f1)"
_mig="$(grep -n 'z2k_ow_migrate_sld_state || return 1' "$SVC" | head -1 | cut -d: -f1)"
_procd="$(grep -n 'procd_open_instance "z2k"' "$SVC" | head -1 | cut -d: -f1)"
if [ -n "$_pre" ] && [ -n "$_mig" ] && [ -n "$_procd" ] && [ "$_pre" -lt "$_mig" ] && [ "$_mig" -lt "$_procd" ]; then
    _t_ok
else
    _t_bad "lifecycle order must be preflight -> migration -> procd"
fi

# A pre-86.2 install may have only the old /tmp fallback. Migration must seed
# the new canonical persistent path, which the Lua runtime reads after upgrade.
rm -f "$STATE_FILE" "$_fallback" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE" \
    "$STATE_FILE.pre-86.2" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE.pre-86.2" \
    "$Z2K_SLD_STATE_MIGRATION_MARKER"
printf 'rkn_tcp\tlegacy.example.com\t7\t789\tauto\n' \
    > "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE"
if z2k_ow_migrate_sld_state; then _t_ok; else _t_bad "legacy-only migration failed"; fi
assert_file "legacy-only migration creates persistent state" "$STATE_FILE"
assert_contains "legacy-only row reaches persistent state" "$STATE_FILE" \
    "rkn_tcp${_tab}example.com${_tab}7${_tab}789${_tab}auto"

_t_done
