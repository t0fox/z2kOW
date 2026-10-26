#!/bin/sh
# Перенос закреплённых номеров пулов p-86.24 в OpenWrt autocircular.
. "$(dirname "$0")/helper.sh"

_t_plan "ow-pool-renumber"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-pool-renumber.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_ETC="$T/etc/z2k"
export Z2K_STATE="$Z2K_ETC/state"
export Z2K_AUTOCIRCULAR_DIR="$Z2K_ETC/autocircular"
export Z2K_AUTOCIRCULAR_FALLBACK_DIR="$T/tmp/z2k/autocircular"
export Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE="$T/legacy/z2k-autocircular-state.tsv"
export Z2K_ZAPRET2_RUNTIME="$T/opt/zapret2"
export Z2K_POOL_RENUMBER_MIGRATION_MARKER="$Z2K_STATE/pool-renumber-v1.done"
unset STATE_FILE
_primary="$Z2K_AUTOCIRCULAR_DIR/state.tsv"
_fallback="$Z2K_AUTOCIRCULAR_FALLBACK_DIR/z2k-autocircular-state.tsv"
mkdir -p "$Z2K_STATE" "$Z2K_AUTOCIRCULAR_DIR" "$Z2K_AUTOCIRCULAR_FALLBACK_DIR" \
    "$(dirname "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE")" \
    "$Z2K_ZAPRET2_RUNTIME/extra_strats/cache/autocircular" || exit 1
. "$REPO/platform/openwrt/state.sh" || exit 1
_tab="$(printf '\t')"

{
    printf 'rkn_tcp\tauto-rkn.example\t1\t100\tauto\n'
    printf 'rkn_tcp\tfrozen-rkn.example\t2\t200\tfrozen\n'
    printf 'rkn_tcp\tremoved-rkn.example\t10\t300\tfrozen\n'
    printf 'yt_tcp\tfrozen-yt.example\t4\t400\tfrozen\n'
    printf 'gv_tcp\tfrozen-gv.example\t6\t500\tfrozen\n'
    printf 'google_tls\tfrozen-google.example\t23\t600\tfrozen\n'
    printf 'quic\tfrozen-quic.example\t9\t700\tfrozen\n'
} > "$_primary"
{
    printf 'discord_udp\tfrozen-voice.example\t1\t800\tfrozen\n'
    printf 'discord_udp\tauto-voice.example\t2\t900\tauto\n'
} > "$_fallback"
printf 'custom\tuntouched.example\t8\t1000\tfrozen\n' > "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE"
cp "$_primary" "$T/primary.original"
cp "$_fallback" "$T/fallback.original"

if z2k_ow_migrate_pool_renumber; then _t_ok; else _t_bad "pool migration failed"; fi
assert_not_contains "automatic RKN choice removed" "$_primary" 'auto-rkn\.example'
assert_contains "frozen RKN number translated" "$_primary" "frozen-rkn.example${_tab}6${_tab}200${_tab}frozen"
assert_not_contains "removed RKN arm dropped" "$_primary" 'removed-rkn.example'
assert_contains "YouTube pool translated" "$_primary" "frozen-yt.example${_tab}13${_tab}400${_tab}frozen"
assert_contains "GV pool translated" "$_primary" "frozen-gv.example${_tab}31${_tab}500${_tab}frozen"
assert_contains "combined Google pool translated" "$_primary" "frozen-google.example${_tab}36${_tab}600${_tab}frozen"
assert_contains "QUIC pool translated" "$_primary" "frozen-quic.example${_tab}7${_tab}700${_tab}frozen"
assert_contains "Discord frozen choice translated" "$_fallback" "frozen-voice.example${_tab}2${_tab}800${_tab}frozen"
assert_not_contains "Discord automatic choice dropped" "$_fallback" 'auto-voice.example'
assert_contains "unrelated pool untouched" "$Z2K_AUTOCIRCULAR_LEGACY_FALLBACK_OVERRIDE" "custom${_tab}untouched.example${_tab}8"
assert_eq "primary snapshot preserved" "$(cksum "$T/primary.original" | awk '{print $1 " " $2}')" "$(cksum "$_primary.pre-pool-renumber-v1" | awk '{print $1 " " $2}')"
assert_eq "fallback snapshot preserved" "$(cksum "$T/fallback.original" | awk '{print $1 " " $2}')" "$(cksum "$_fallback.pre-pool-renumber-v1" | awk '{print $1 " " $2}')"
assert_file "migration marker" "$Z2K_POOL_RENUMBER_MIGRATION_MARKER"

_before="$(cksum "$_primary")"
if z2k_ow_migrate_pool_renumber; then _t_ok; else _t_bad "repeat migration failed"; fi
assert_eq "repeat is byte-idempotent" "$_before" "$(cksum "$_primary")"

SVC="$REPO/platform/openwrt/files/etc/init.d/z2k"
_pre="$(grep -n 'z2k_ow_migrate_pool_renumber || return 1' "$SVC" | head -1 | cut -d: -f1)"
_procd="$(grep -n 'procd_open_instance "z2k"' "$SVC" | head -1 | cut -d: -f1)"
if [ -n "$_pre" ] && [ -n "$_procd" ] && [ "$_pre" -lt "$_procd" ]; then _t_ok; else _t_bad "pool migration must run before the core process"; fi

_t_done
