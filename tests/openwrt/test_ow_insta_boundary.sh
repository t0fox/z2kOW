#!/bin/sh
# The Instagram/WhatsApp IP refresher is a Keenetic ndmc helper.  OpenWrt must
# neither ship nor invoke it: its list-refresh caller belongs to the Keenetic
# scheduler, while OpenWrt owns platform/openwrt/update.sh and cron.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-insta-boundary"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || exit 1

_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-insta-ip-refresh.sh 2>/dev/null)"
[ -z "$_mapped" ] && _t_ok || _t_bad "Keenetic insta helper получил OpenWrt target: $_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-update-lists.sh 2>/dev/null)"
assert_eq "WARP list refresher доставляется в OpenWrt payload" "/usr/lib/z2k/z2k-update-lists.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths lib/install.sh 2>/dev/null)"
assert_eq "Keenetic installer не доставляется в OpenWrt payload" "" "$_mapped"

# Package and OpenWrt-owned lifecycle files contain no direct invocation or
# install recipe for the helper.  The only source caller remains upstream.
_ow_files="$(find "$REPO/platform/openwrt" "$REPO/package/openwrt" -type f -print 2>/dev/null)"
if [ -n "$_ow_files" ] && ! grep -lF 'z2k-insta-ip-refresh.sh' $_ow_files >/dev/null 2>&1; then
    _t_ok
else
    _t_bad "OpenWrt-owned files invoke or install insta refresh"
fi
assert_not_contains "package не ставит Keenetic insta helper" "$REPO/package/openwrt/Makefile" 'z2k-insta-ip-refresh\.sh'
assert_not_contains "package не ставит Keenetic S99" "$REPO/package/openwrt/Makefile" 'S99zapret2\.new'
assert_not_contains "package не ставит Keenetic scheduler" "$REPO/package/openwrt/Makefile" 'z2k-scheduler\.sh'
assert_contains "helper сам гейтится по ndmc" "$REPO/files/z2k-insta-ip-refresh.sh" 'ndmc not found'

# The old defect was a delivery gap: OpenWrt did not ship the common helper,
# so its empty gaming-list directory could never converge. Keep the truthful
# source-error UI while asserting the helper and cron now reach OpenWrt.
assert_contains "gaming-list source failure остаётся видимым" "$REPO/files/z2k-update-lists.sh" 'warp games index unavailable'
assert_contains "UI сохраняет gaming-list error" "$REPO/webpanel/www/js/pages/warp.js" 'Списки не загрузились — источник был недоступен'
assert_contains "OpenWrt cron обновляет gaming lists" "$REPO/platform/openwrt/schedule.sh" 'z2k-warp-games'
assert_contains "OpenWrt cron запускает common helper через sh" "$REPO/platform/openwrt/schedule.sh" 'sh $Z2K_ROOT/z2k-update-lists.sh warp-games'
assert_contains "OpenWrt helper принимает payload root" "$REPO/files/z2k-update-lists.sh" 'ZAPRET2_DIR:-/opt/zapret2'
assert_contains "OpenWrt cron передаёт canonical config" "$REPO/platform/openwrt/schedule.sh" 'CONFIG_FILE=${Z2K_CONFIG:-/etc/z2k/config}'
assert_contains "OpenWrt cron вызывает platform WARP reload" "$REPO/platform/openwrt/schedule.sh" 'Z2K_WARP_IPSET_SCRIPT=$Z2K_ROOT/platform/openwrt/warp.sh'

_t_done
