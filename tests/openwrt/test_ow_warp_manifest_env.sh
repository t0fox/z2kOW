#!/bin/sh
# OpenWrt WARP is bundled in the full signed release; it has no component
# fetch/manifest path of its own. Verify the single payload's paths.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-payload-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "/tmp/z2k-ow-warp-env.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/platform/openwrt/bin/linux-x86_64" "$T/root/etc" \
    "$T/etc" "$T/tmp/warp"
cp "$REPO/platform/openwrt/arch.sh" "$T/root/platform/openwrt/arch.sh"
printf 'test public key\n' > "$T/root/etc/z2k-update-pub.pem"
printf 'DISTRIB_ARCH="x86_64"\n' > "$T/openwrt_release"
cat > "$T/root/platform/openwrt/bin/linux-x86_64/z2k-warpd" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo 'bundled z2k-warpd'; exit 0 ;;
    register) echo 'device ok test-id'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/root/platform/openwrt/bin/linux-x86_64/z2k-warpd"

_got="$(
    (
        unset ZAPRET2_DIR Z2K_AU_PUBKEY WARP_BIN WARP_FETCH_STUB
        export Z2K_ROOT="$T/root" Z2K_ADAPTER_DIR="$T/root/platform/openwrt" \
            Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_STATE="$T/etc/state" \
            Z2K_USER_LISTS="$T/etc/user-lists" Z2K_LISTS_DIR="$T/root/lists" \
            Z2K_ZAPRET2_RUNTIME="$T/zapret2" \
            Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" \
            Z2K_WARP_SOURCE_ONLY=1 WARP_LISTS_DIR="$T/etc/user-lists/warp" \
            WARP_ENABLED_FILE="$T/etc/user-lists/warp/.enabled" \
            WARP_DEVICE="$T/etc/state/warp/device.json" WARP_LOG="$T/tmp/warp/warpd.log"
        . "$REPO/platform/openwrt/paths.sh" || exit 1
        . "$REPO/platform/openwrt/env.sh" || exit 1
        . "$REPO/lib/auto_update.sh" || exit 1
        . "$T/root/platform/openwrt/arch.sh" || exit 1
        . "$REPO/platform/openwrt/warp.sh" || exit 1
        printf '%s\n%s\n' "$Z2K_AU_PUBKEY" "$WARP_BIN"
    )
)"
_key="$(printf '%s\n' "$_got" | sed -n '1p')"
_bin="$(printf '%s\n' "$_got" | sed -n '2p')"
assert_eq "updater verifier key comes from the full payload" \
    "$T/root/etc/z2k-update-pub.pem" "$_key"
assert_eq "WARP binary comes from the architecture bundle" \
    "$T/root/platform/openwrt/bin/linux-x86_64/z2k-warpd" "$_bin"
[ -s "$_key" ] && _t_ok || _t_bad "full payload verifier key is missing"
assert_not_contains "no standalone WARP component downloader" \
    "$REPO/platform/openwrt/warp.sh" 'warp_fetch_engine'
assert_contains "missing engine directs users to full convergence" \
    "$REPO/platform/openwrt/warp.sh" 'restore it with install_release <tag>'

_t_done
