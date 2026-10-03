#!/bin/sh
# Upstream Instagram/WhatsApp refresh behavior is shared; OpenWrt replaces only
# the Keenetic ndmc host-record backend with its dnsmasq adapter.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-insta-boundary"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || exit 1

_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-insta-ip-refresh.sh 2>/dev/null)"
assert_eq "shared Instagram/WhatsApp refresh executor is delivered" "/usr/lib/z2k/z2k-insta-ip-refresh.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-update-lists.sh 2>/dev/null)"
assert_eq "WARP list refresher доставляется в OpenWrt payload" "/usr/lib/z2k/z2k-update-lists.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-geosite.sh 2>/dev/null)"
assert_eq "upstream geosite executor доставляется в OpenWrt payload" "/usr/lib/z2k/z2k-geosite.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-stats-upload.sh 2>/dev/null)"
assert_eq "upstream stats executor доставляется в OpenWrt payload" "/usr/lib/z2k/z2k-stats-upload.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths files/z2k-blocked-monitor.sh 2>/dev/null)"
assert_eq "blocked monitor доставляется в OpenWrt payload" "/usr/lib/z2k/z2k-blocked-monitor.sh" "$_mapped"
_mapped="$(Z2K_PLATFORM=openwrt z2k_install_paths lib/install.sh 2>/dev/null)"
assert_eq "Keenetic installer не доставляется в OpenWrt payload" "" "$_mapped"

assert_contains "shared refresher dispatches to OpenWrt DNS backend" "$REPO/files/z2k-insta-ip-refresh.sh" 'z2k_ow_insta_prepare'
assert_contains "OpenWrt owns only the dnsmasq host-record adapter" "$REPO/platform/openwrt/insta-ip.sh" 'addnhosts'
assert_contains "full upstream list refresh invokes the shared IP refresh" "$REPO/files/z2k-update-lists.sh" 'z2k-insta-ip-refresh.sh'
assert_contains "OpenWrt updater exports platform identity to shared refresh" "$REPO/platform/openwrt/env.sh" 'Z2K_PLATFORM="${Z2K_PLATFORM:-openwrt}"'
assert_contains "uninstall removes only the owned dnsmasq include reference" "$REPO/platform/openwrt/uninstall.sh" 'z2k_ow_insta_uninstall'
assert_contains "full payload builder includes shared refresher" "$REPO/scripts/openwrt/stage-rootfs.sh" 'stage-common-payload.sh'
assert_not_contains "full payload builder excludes Keenetic S99" "$REPO/scripts/openwrt/stage-rootfs.sh" 'S99zapret2\.new'
assert_not_contains "full payload builder excludes Keenetic scheduler" "$REPO/scripts/openwrt/stage-rootfs.sh" 'z2k-scheduler\.sh'
assert_contains "Keenetic path retains ndmc backend" "$REPO/files/z2k-insta-ip-refresh.sh" 'ndmc not found'

# The old defect was a delivery gap: OpenWrt did not ship the common helper,
# so its empty gaming-list directory could never converge. Keep the truthful
# source-error UI while asserting the helper and cron now reach OpenWrt.
assert_contains "gaming-list source failure остаётся видимым" "$REPO/files/z2k-update-lists.sh" 'warp games index unavailable'
assert_contains "UI сохраняет gaming-list error" "$REPO/webpanel/www/js/pages/warp.js" 'Списки не загрузились — источник был недоступен'
assert_contains "OpenWrt cron обновляет gaming lists" "$REPO/platform/openwrt/schedule.sh" 'z2k-warp-games'
assert_contains "OpenWrt cron запускает common helper через sh" "$REPO/platform/openwrt/schedule.sh" 'sh $Z2K_ROOT/z2k-update-lists.sh warp-games'
assert_contains "OpenWrt cron enters native list-refresh adapter" "$REPO/platform/openwrt/schedule.sh" 'platform/openwrt/list-refresh.sh # z2k-lists'
assert_contains "full list refresh is scheduled at upstream 04:00" "$REPO/platform/openwrt/schedule.sh" '0 4 * * *'
assert_contains "full list refresh defaults to the OpenWrt service init" "$REPO/platform/openwrt/list-refresh.sh" 'INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"'
assert_contains "full list refresh supplies the OpenWrt WARP replacement" "$REPO/platform/openwrt/list-refresh.sh" 'Z2K_WARP_IPSET_SCRIPT="${Z2K_WARP_IPSET_SCRIPT:-$Z2K_ROOT/platform/openwrt/warp.sh}"'
assert_contains "list refresh sources the shared OpenWrt path adapter" "$REPO/platform/openwrt/list-refresh.sh" 'platform/openwrt/env.sh'
assert_contains "OpenWrt env binds autocircular state to persistent state.tsv" "$REPO/platform/openwrt/env.sh" 'STATE_FILE="${STATE_FILE:-$Z2K_STATE/state.tsv}"'
assert_contains "OpenWrt env binds the merged extra-domain user file" "$REPO/platform/openwrt/env.sh" 'Z2K_EXTRA_DOMAINS_RUNTIME="${Z2K_EXTRA_DOMAINS_RUNTIME:-$Z2K_USER_LISTS/extra-domains.txt}"'
assert_contains "OpenWrt env binds the persistent autohostlist ledger" "$REPO/platform/openwrt/env.sh" 'Z2K_AUTOHOSTLIST_DOMAINS_FILE="${Z2K_AUTOHOSTLIST_DOMAINS_FILE:-$Z2K_STATE/autohostlist-domains.txt}"'
assert_contains "list refresh keeps geosite markers in OpenWrt persistent state" "$REPO/platform/openwrt/list-refresh.sh" 'Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER'
assert_contains "OpenWrt cron preserves upstream 03:00 stats run" "$REPO/platform/openwrt/schedule.sh" '0 3 * * *'
assert_contains "stats uploader consumes persistent OpenWrt state.tsv" "$REPO/platform/openwrt/schedule.sh" 'STATE_FILE=${Z2K_STATE:-/etc/z2k/state}/state.tsv'
assert_contains "OpenWrt geosite executor remains reachable from common refresh" "$REPO/files/z2k-update-lists.sh" 'z2k-geosite.sh" fetch'
assert_contains "blocked monitor is an operator CLI command" "$REPO/platform/openwrt/z2kow.sh" 'blocked-monitor|bm)'
assert_contains "blocked monitor writes outside read-only release payload" "$REPO/platform/openwrt/z2kow.sh" 'Z2K_BLOCKED_MONITOR_CACHE'
assert_contains "OpenWrt helper принимает payload root" "$REPO/files/z2k-update-lists.sh" 'ZAPRET2_DIR:-/opt/zapret2'
assert_contains "OpenWrt cron передаёт canonical config" "$REPO/platform/openwrt/schedule.sh" 'CONFIG_FILE=${Z2K_CONFIG:-/etc/z2k/config}'
assert_contains "OpenWrt cron вызывает platform WARP reload" "$REPO/platform/openwrt/schedule.sh" 'Z2K_WARP_IPSET_SCRIPT=$Z2K_ROOT/platform/openwrt/warp.sh'

_t_done
