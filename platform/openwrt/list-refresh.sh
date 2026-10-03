#!/bin/sh
# Bind the upstream full list updater to OpenWrt-owned state and services.

Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1

INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"
Z2K_WARP_IPSET_SCRIPT="${Z2K_WARP_IPSET_SCRIPT:-$Z2K_ROOT/platform/openwrt/warp.sh}"
Z2K_RKN_FP_MARK="${Z2K_RKN_FP_MARK:-$Z2K_STATE/.z2k-rkn-fp.sha256}"
Z2K_RKN_FP_COPY="${Z2K_RKN_FP_COPY:-$Z2K_STATE/.z2k-rkn-fp.list}"
Z2K_GEOSITE_STATE_FILE="${Z2K_GEOSITE_STATE_FILE:-$STATE_FILE}"
Z2K_GEOSITE_GOOGLE_PURGE_MARKER="${Z2K_GEOSITE_GOOGLE_PURGE_MARKER:-$Z2K_STATE/.geosite-google-purge-2026-05-24.done}"
Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER="${Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER:-$Z2K_STATE/.geosite-instagram-purge-2026-05-28.done}"
LOG_FILE="${LOG_FILE:-$Z2K_LOG/z2k-update-lists.log}"
export INIT_SCRIPT Z2K_WARP_IPSET_SCRIPT Z2K_RKN_FP_MARK Z2K_RKN_FP_COPY \
    Z2K_GEOSITE_STATE_FILE Z2K_GEOSITE_GOOGLE_PURGE_MARKER \
    Z2K_GEOSITE_INSTAGRAM_PURGE_MARKER LOG_FILE

exec sh "$Z2K_ROOT/z2k-update-lists.sh" all
