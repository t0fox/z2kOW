#!/bin/sh
# tests/openwrt/test_ow_warp_snapshot_manifest.sh - snapshot/production
# authority and artifact-integrity gates for standalone WARP provisioning.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-snapshot-manifest"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpsnap.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/share" "$T/tmp" "$T/bin"
export Z2K_ROOT="$T/root" Z2K_TMP="$T/tmp" Z2K_AU_TMP_DIR="$T/tmp/update"
export Z2K_ETC="$T/etc" Z2K_PLATFORM=openwrt
export Z2K_AU_RAW_BASE="https://snapshot.example/z2kOW"
export Z2K_AU_REPO_RAW="https://channel.example/z2k-enhanced-openwrt"
mkdir -p "$Z2K_AU_TMP_DIR" "$Z2K_ETC"

# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" || exit 1
. "$REPO/platform/openwrt/manifest.sh" || exit 1

_good_hash="$(printf '%064d' 0 | tr '0' 'a')"
_bad_hash="$(printf '%064d' 0 | tr '0' 'b')"
_ref=0123456789abcdef0123456789abcdef01234567
_warp_key='z2k-warpd/builds/z2k-warpd-linux-arm64'

cat > "$T/root/share/snapshot-manifest.json" <<EOF
{"schema":1,"branch":"z2k-enhanced-openwrt","seq":1,"current":"p-1","platform":"openwrt","install_map":{},"files_sha256":{"$_warp_key":"$_good_hash"},"history":[{"v":"p-1","type":"patch","ts":"2026-09-16T00:00:00Z","ref":"$_ref","desc":"snapshot","changed_files":[]}]}
EOF
printf '%s\n' "$_ref" > "$T/root/share/snapshot-commit"

_remote_calls="$T/remote.calls"
_remote_manifest="$T/remote-manifest.json"
cat > "$_remote_manifest" <<EOF
{"schema":1,"branch":"z2k-enhanced-openwrt","seq":2,"current":"p-2","platform":"openwrt","install_map":{},"files_sha256":{"$_warp_key":"$_bad_hash"},"history":[{"v":"p-2","type":"patch","ts":"2026-09-16T00:00:00Z","ref":"$_ref","desc":"remote","changed_files":[]}]}
EOF
au_fetch_pair() {
    echo "pair:$1" >> "$_remote_calls"
    cp -f "$_remote_manifest" "$3"
    printf 'signed\n' > "$4"
}
au_manifest_verify() { echo "verify" >> "$_remote_calls"; return 0; }

# 1. Snapshot is authoritative even when a newer channel is available.
: > "$_remote_calls"
z2k_ow_manifest_prepare "$T/snapshot.json" arm64 >/dev/null 2>&1
assert_eq "snapshot prepare succeeds" "0" "$?"
assert_eq "snapshot mode selected" "snapshot" "$Z2K_OW_MANIFEST_MODE"
assert_eq "snapshot commit selected" "$_ref" "$Z2K_AU_TARGET_REF"
assert_eq "snapshot hash selected" "$_good_hash" "$(z2k_ow_manifest_file_sha "$T/snapshot.json" "$_warp_key")"
assert_eq "remote manifest not requested" "0" "$(grep -c '^pair:' "$_remote_calls" 2>/dev/null || true)"
assert_eq "snapshot signature not requested" "0" "$(grep -c '^verify$' "$_remote_calls" 2>/dev/null || true)"

# 2. Snapshot binaries use the exact immutable commit, never a branch URL.
assert_eq "snapshot binary URL is immutable" \
    "$Z2K_AU_RAW_BASE/$_ref/$_warp_key" \
    "$(z2k_ow_manifest_file_url "$_warp_key")"
assert_not_contains "snapshot URL has no branch" "$T/remote.calls" 'channel\.example'

# 3. A partial or malformed snapshot commit fails closed.
printf 'short-ref\n' > "$T/root/share/snapshot-commit"
z2k_ow_manifest_prepare "$T/bad-commit.json" arm64 >/dev/null 2>&1
assert_eq "bad snapshot commit rejected" "1" "$?"
rm -f "$T/root/share/snapshot-commit"

# 4. Downloaded WARP bytes must match the embedded snapshot hash.
printf 'wrong binary\n' > "$T/wrong.bin"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_LIB="$REPO/lib"
export WARP_BIN="$T/root/bin/z2k-warpd" WARP_ENDPOINTS="$T/endpoints.txt"
export Z2K_WARP_SOURCE_ONLY=1
z2k_fetch() { echo "fetch:$1" >> "$_remote_calls"; cp -f "$T/wrong.bin" "$2"; }
. "$REPO/platform/openwrt/warp.sh" || exit 1
printf '%s\n' "$_ref" > "$T/root/share/snapshot-commit"
rm -f "$T/root/bin/z2k-warpd"
warp_fetch_engine arm64 >/dev/null 2>&1
assert_eq "snapshot bad binary hash rejected" "1" "$?"
assert_eq "bad binary not installed" "0" "$([ -e "$T/root/bin/z2k-warpd" ] && echo 1 || echo 0)"
assert_contains "binary request uses immutable ref" "$_remote_calls" "fetch:$Z2K_AU_RAW_BASE/$_ref/$_warp_key"

# 5. Production mode fetches and verifies the signed channel manifest.
rm -f "$T/root/share/snapshot-manifest.json" "$T/root/share/snapshot-commit"
: > "$_remote_calls"
au_fetch_pair() {
    echo "pair:$1" >> "$_remote_calls"
    cp -f "$_remote_manifest" "$3"
    printf 'signed\n' > "$4"
}
au_manifest_verify() { echo "verify" >> "$_remote_calls"; return 0; }
z2k_ow_manifest_prepare "$T/production.json" arm64 >/dev/null 2>&1
assert_eq "production prepare succeeds with signature" "0" "$?"
assert_eq "production mode selected" "production" "$Z2K_OW_MANIFEST_MODE"
assert_eq "production target ref empty" "" "$Z2K_AU_TARGET_REF"
assert_contains "production manifest requested" "$_remote_calls" "pair:$Z2K_AU_REPO_RAW/UPDATES.json"
assert_contains "production signature verified" "$_remote_calls" "verify"
assert_eq "production binary URL uses channel" \
    "$Z2K_AU_REPO_RAW/$_warp_key" \
    "$(z2k_ow_manifest_file_url "$_warp_key")"

# 6. Bad or missing production signatures are always rejected.
au_manifest_verify() { echo "verify-bad" >> "$_remote_calls"; return 1; }
z2k_ow_manifest_prepare "$T/bad-signature.json" arm64 >/dev/null 2>&1
assert_eq "bad production signature rejected" "1" "$?"
assert_eq "bad production manifest removed" "0" "$([ -e "$T/bad-signature.json" ] && echo 1 || echo 0)"
au_fetch_pair() {
    echo "pair-no-sig:$1" >> "$_remote_calls"
    cp -f "$_remote_manifest" "$3"
    rm -f "$4"
}
z2k_ow_manifest_prepare "$T/missing-signature.json" arm64 >/dev/null 2>&1
assert_eq "missing production signature rejected" "1" "$?"
assert_eq "unsigned production manifest removed" "0" "$([ -e "$T/missing-signature.json" ] && echo 1 || echo 0)"

_t_done
