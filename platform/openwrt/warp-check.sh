#!/bin/sh
# platform/openwrt/warp-check.sh - cron entrypoint WARP selfheal (Stage 5).
# Каждую минуту: converge-to-ready-or-fail-open. Демона не стартует
# (это делает procd); PBR — только при доказанной ready.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

# sbin — в конец (приоритет операторского/тестового PATH; см. warp-proc.sh).
export PATH="$PATH:/usr/sbin:/sbin"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1
Z2K_WARP_SOURCE_ONLY=1; export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/warp.sh" || exit 1

[ "${1:-check}" = "check" ] || { echo "usage: warp-check.sh [check]" >&2; exit 1; }
Z2K_WARP_QUIET=1; export Z2K_WARP_QUIET
z2k_ow_warp check
exit $?
