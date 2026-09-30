#!/bin/sh
# tests/openwrt/test_ow_snapshot_authority.sh - snapshots stay internal to
# provisioning; ordinary update check/apply uses the signed upstream release.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-snapshot-authority"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-snapauth.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/share" "$T/bin" "$T/etc"
export Z2K_ROOT="$T/root" Z2K_BIN="$T/bin" Z2K_TMP="$T/tmp" \
    Z2K_ETC="$T/etc" Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_PLATFORM=openwrt
export Z2K_AU_TMP_DIR="$T/tmp/update"
mkdir -p "$T/bin" "$T/tmp/update"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/manifest.sh" || exit 1
. "$REPO/platform/openwrt/binaries.sh" || exit 1
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" || exit 1
# The ordinary updater must use the signed channel even when a CI snapshot is
# embedded. Provisioning continues to use that immutable snapshot internally.
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" || exit 1

# Настоящий au недоступен изолированно — стабы точек ветвления.
au_fetch_pair() {
    echo "FETCH-PAIR-CALLED" >> "$T/calls"
    printf '{"current":"p-99.99","platform":"openwrt","install_map":{},"files_sha256":{"z2k-warpd/builds/z2k-warpd-linux-arm64":"%s"}}\n' \
        "$_remote_hash" > "$3"
    printf 'signed\n' > "$4"
    return 0
}
au_manifest_verify() { echo "VERIFY-CALLED" >> "$T/calls"; return 0; }
au_manifest_platform_ok() { echo "platform-ok:$1" >> "$T/calls"; return 0; }
au_step_refresh_binaries() { echo "refresh" >> "$T/calls"; return 0; }
au_log() { echo "aulog:$*" >> "$T/calls"; }

_snapshot_hash="$(printf '%064d' 0 | tr '0' 'a')"
_remote_hash="$(printf '%064d' 0 | tr '0' 'b')"
printf '{"current":"p-84.17","platform":"openwrt","snapshot":true,"install_map":{},"files_sha256":{"z2k-warpd/builds/z2k-warpd-linux-arm64":"%s"}}\n' \
    "$_snapshot_hash" > "$T/root/share/snapshot-manifest.json"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$T/root/share/snapshot-commit"

: > "$T/calls"
au_fetch_manifest >/dev/null 2>&1
assert_eq "ordinary update manifest fetch succeeds" "0" "$?"
assert_contains "ordinary updater fetches signed channel" "$T/calls" "FETCH-PAIR-CALLED"
assert_contains "ordinary updater verifies signature" "$T/calls" "VERIFY-CALLED"
assert_eq "ordinary updater selects upstream release" "p-99.99" "$(sed -n 's/.*\"current\":\"\([^\"]*\)\".*/\1/p' "$T/tmp/update/UPDATES.json")"
assert_eq "ordinary updater does not pin CI commit" "" "${Z2K_AU_TARGET_REF:-}"

: > "$T/calls"
z2k_ow_ensure_binaries >/dev/null 2>&1
assert_eq "ensure rc" "0" "$?"
if grep -q "FETCH-PAIR-CALLED" "$T/calls"; then
    _t_bad "provisioning stopped using its embedded snapshot"
else
    _t_ok
fi
assert_contains "provisioning manifest remains embedded snapshot" "$T/tmp/update/UPDATES.json" '"snapshot":true'
assert_eq "provisioning target ref keeps internal pin" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$Z2K_AU_TARGET_REF"
assert_contains "provisioning refresh called" "$T/calls" "refresh"

# Без embedded snapshot — production path fetches and verifies the signed pair.
rm -f "$T/root/share/snapshot-manifest.json" "$T/root/share/snapshot-commit"
rm -f "$T/tmp/update/UPDATES.json"
: > "$T/calls"
z2k_ow_ensure_binaries >/dev/null 2>&1
assert_eq "channel rc" "0" "$?"
assert_contains "без snapshot канал опрашивается" "$T/calls" "FETCH-PAIR-CALLED"
assert_contains "production подпись проверяется" "$T/calls" "VERIFY-CALLED"
assert_eq "production target ref сброшен" "" "$Z2K_AU_TARGET_REF"

_t_done
