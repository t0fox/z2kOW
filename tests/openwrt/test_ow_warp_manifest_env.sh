#!/bin/sh
# tests/openwrt/test_ow_warp_manifest_env.sh - standalone installer must map
# OpenWrt paths before auto_update.sh captures its manifest verifier defaults.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-manifest-env"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warp-env.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/platform/openwrt" "$T/root/lib" "$T/root/etc" "$T/etc" "$T/tmp"
cp "$REPO/platform/openwrt/paths.sh" "$T/root/platform/openwrt/paths.sh"
cp "$REPO/platform/openwrt/env.sh" "$T/root/platform/openwrt/env.sh"
cp "$REPO/platform/openwrt/warp.sh" "$T/root/platform/openwrt/warp.sh"
printf 'test public key\n' > "$T/root/etc/z2k-update-pub.pem"
: > "$T/root/lib/utils.sh"
cat > "$T/root/lib/auto_update.sh" <<'EOF'
Z2K_AU_PUBKEY="${Z2K_AU_PUBKEY:-${ZAPRET2_DIR:-/opt/zapret2}/etc/z2k-update-pub.pem}"
au_fetch_pair() { : > "$3"; : > "$4"; }
au_manifest_verify() {
    printf '%s' "$Z2K_AU_PUBKEY" > "$Z2K_WARP_TEST_CAPTURE"
    [ -s "$Z2K_AU_PUBKEY" ]
}
EOF

_out="$( (
    unset ZAPRET2_DIR Z2K_AU_PUBKEY Z2K_ADAPTER_DIR WARP_FETCH_STUB
    export Z2K_ROOT="$T/root" Z2K_LIB="$T/root/lib" Z2K_ETC="$T/etc" \
           Z2K_TMP="$T/tmp" Z2K_WARP_SOURCE_ONLY=1 \
           Z2K_WARP_TEST_CAPTURE="$T/key.path" WARP_BIN="$T/tmp/z2k-warpd" \
           WARP_LOG="$T/warp.log"
    sh -c '. "$0"; warp_fetch_engine arm64' \
        "$T/root/platform/openwrt/warp.sh" 2>&1
) )"
_rc=$?
_got="$(cat "$T/key.path" 2>/dev/null)"
assert_eq "standalone installer maps verifier key from payload" \
    "$T/root/etc/z2k-update-pub.pem" "$_got"
[ "$_rc" -ne 0 ] && _t_ok || _t_bad "empty test manifest unexpectedly accepted"

_t_done
