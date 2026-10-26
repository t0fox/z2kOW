#!/bin/sh
# Перенос пользовательских стратегий со снятых fake-блобов p-86.24.
. "$(dirname "$0")/helper.sh"

_t_plan "ow-custom-blob-migration"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-custom-blob.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_STATE="$T/etc/z2k/state"
export Z2K_USER_LISTS="$T/etc/z2k/user-lists"
export Z2K_EXTRA_STRATEGIES_RUNTIME="$Z2K_USER_LISTS/custom-strategies"
export Z2K_CUSTOM_BLOB_MIGRATION_MARKER="$Z2K_STATE/custom-blobs-v1.done"
mkdir -p "$Z2K_STATE" "$Z2K_EXTRA_STRATEGIES_RUNTIME" || exit 1
. "$REPO/platform/openwrt/state.sh" || exit 1

_voice="$Z2K_EXTRA_STRATEGIES_RUNTIME/discord_udp.txt"
_tls="$Z2K_EXTRA_STRATEGIES_RUNTIME/rkn_tcp.txt"
_similar="$Z2K_EXTRA_STRATEGIES_RUNTIME/custom.txt"
printf '%s\n' '# мой голос' '--lua-desync=fake:payload=all:blob=quic_dbankcloud:repeats=8:strategy=1' \
    '--lua-desync=fake:payload=all:blob=quic_dbankcloud' > "$_voice"
printf '%s\n' '--lua-desync=fake:blob=tls_clienthello_www_onetrust_com' > "$_tls"
printf '%s\n' '--lua-desync=fake:blob=quic_dbankcloud_x:repeats=2' > "$_similar"
cp "$_voice" "$T/voice.original"

if z2k_ow_migrate_custom_blobs; then _t_ok; else _t_bad "custom blob migration failed"; fi
assert_contains "voice blob changed and options preserved" "$_voice" 'blob=quic_initial_steamcommunity_com:repeats=8:strategy=1'
if grep -qxF -- '--lua-desync=fake:payload=all:blob=quic_initial_steamcommunity_com' "$_voice"; then
    _t_ok
else
    _t_bad "blob at end of line changed"
fi
assert_not_contains "retired voice blob removed" "$_voice" 'quic_dbankcloud'
assert_contains "retired TLS blob changed" "$_tls" 'blob=tls_clienthello_www_sferum_ru'
assert_contains "similar longer name untouched" "$_similar" 'blob=quic_dbankcloud_x'
assert_eq "original voice file snapshotted" "$(cksum "$T/voice.original" | awk '{print $1 " " $2}')" "$(cksum "$_voice.pre-blob-migration-v1" | awk '{print $1 " " $2}')"
assert_eq "migration marker" "1" "$( [ -f "$Z2K_CUSTOM_BLOB_MIGRATION_MARKER" ] && echo 1 || echo 0 )"

_after="$(cksum "$_voice")"
if z2k_ow_migrate_custom_blobs; then _t_ok; else _t_bad "repeat migration failed"; fi
assert_eq "repeat is byte-idempotent" "$_after" "$(cksum "$_voice")"

# A fresh install without user strategies still completes without blocking start.
rm -rf "$Z2K_EXTRA_STRATEGIES_RUNTIME" "$Z2K_CUSTOM_BLOB_MIGRATION_MARKER"
if z2k_ow_migrate_custom_blobs; then _t_ok; else _t_bad "missing directory blocked startup"; fi
assert_eq "empty install marker" "1" "$( [ -f "$Z2K_CUSTOM_BLOB_MIGRATION_MARKER" ] && echo 1 || echo 0 )"

SVC="$REPO/platform/openwrt/files/etc/init.d/z2k"
_migration_line="$(grep -n 'z2k_ow_migrate_custom_blobs || return 1' "$SVC" | head -1 | cut -d: -f1)"
_procd_line="$(grep -n 'procd_open_instance "z2k"' "$SVC" | head -1 | cut -d: -f1)"
if [ -n "$_migration_line" ] && [ -n "$_procd_line" ] && [ "$_migration_line" -lt "$_procd_line" ]; then
    _t_ok
else
    _t_bad "custom migration must run before the core process"
fi

_t_done
