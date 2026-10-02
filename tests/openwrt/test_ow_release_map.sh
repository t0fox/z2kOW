#!/bin/sh
# The upstream path map is a build-time staging input only. Runtime deployment
# always applies the complete OpenWrt release through install_release(tag).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-map"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/lib/release_map.sh" || exit 1

unset Z2K_PLATFORM
assert_eq "default mapping remains Keenetic" \
    '/opt/zapret2/lua/z2k-alert.lua' "$(z2k_install_paths files/lua/z2k-alert.lua)"
assert_eq "unknown platform fails closed" '' \
    "$(z2k_install_paths_for mars files/lua/z2k-alert.lua 2>/dev/null)"

_ow() { Z2K_PLATFORM=openwrt z2k_install_paths "$1" 2>/dev/null; }
assert_eq "common updater code stages beneath one product root" \
    '/usr/lib/z2k/lib/utils.sh' "$(_ow lib/utils.sh)"
assert_eq "QUIC input stages with the full payload" \
    '/usr/lib/z2k/quic_strats.ini' "$(_ow quic_strats.ini)"
assert_eq "lists stage in product tree plus preserved user destination" \
    '/usr/lib/z2k/lists/extra-domains.txt
/etc/z2k/user-lists/extra-domains.txt' "$(_ow files/lists/extra-domains.txt)"
assert_contains "staging materializes common source into the one full tree" \
    "$REPO/scripts/openwrt/stage-common-payload.sh" 'z2k_install_paths'
assert_contains "full release installer uses the explicit owned-path list" \
    "$REPO/platform/openwrt/release.sh" 'z2k_ow_owned_paths'
assert_not_contains "runtime installer has no per-file map deployment" \
    "$REPO/platform/openwrt/release.sh" 'z2k_install_paths|au_install_paths|stack-update\.sh|product-update\.sh'

_t_done
