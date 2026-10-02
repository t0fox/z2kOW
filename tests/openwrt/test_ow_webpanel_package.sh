#!/bin/sh
# Panel is part of the full rootfs; only lighttpd and modules remain APK dependencies.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-payload"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PANEL="$REPO/platform/openwrt/files/etc/init.d/z2k-webpanel"
RELEASE="$REPO/platform/openwrt/release.sh"
BOOTSTRAP="$REPO/scripts/openwrt/install.sh"
STAGE="$REPO/scripts/openwrt/stage-rootfs.sh"
assert_file "panel init exists in release source" "$PANEL"
assert_contains "full rootfs stages the panel service" "$STAGE" 'files/etc/init.d/z2k-webpanel'
assert_contains "panel dependency uses no-script system install" "$RELEASE" 'apk add --no-scripts lighttpd'
assert_contains "panel web modules remain real OpenWrt dependencies" "$RELEASE" 'lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias'
assert_contains "panel refuses LuCI ports" "$REPO/platform/openwrt/webpanel.sh" '80|443)'
assert_not_contains "panel init does not stop stock HTTP services" "$PANEL" 'uhttpd|killall.*lighttpd|service.*lighttpd'
assert_not_contains "fresh installer installs no product APK" "$BOOTSTRAP" 'z2k-(adapter|webpanel|zapret2-runtime|warp-runtime)'
[ ! -e "$REPO/package/openwrt/Makefile" ] && _t_ok || _t_bad "obsolete component APK recipe remains"
[ ! -e "$REPO/platform/openwrt/product-update.sh" ] && _t_ok || _t_bad "second component updater remains"
_t_done
