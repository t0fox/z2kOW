#!/bin/sh
# Privileged route seam for mtproxy-client's Telegram UDP-v1 transport.
# This is intentionally an OpenWrt executable, not the Keenetic iptables
# helper. The client calls it only with ensure/down and never passes secrets.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

. "$Z2K_ROOT/platform/openwrt/paths.sh" 2>/dev/null || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" 2>/dev/null || exit 1
. "$Z2K_ROOT/platform/openwrt/tg.sh" 2>/dev/null || exit 1

[ "${1:-}" = ensure ] || [ "${1:-}" = down ] || {
    echo "usage: tg-udp-route.sh {ensure|down}" >&2
    exit 2
}
z2k_ow_tg_udp_route "$1"
