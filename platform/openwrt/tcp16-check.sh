#!/bin/sh
# Run the upstream TCP16 probe only until the first valid line verdict exists.
# The 03:30 cron entry invokes the probe directly for nightly remeasurement.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1

if [ -s "$Z2K_TCP16_FLAG" ] && [ -s "$Z2K_TCP16_TIMESTAMP" ]; then
    _verdict=$(cat "$Z2K_TCP16_FLAG" 2>/dev/null)
    _stamp=$(cat "$Z2K_TCP16_TIMESTAMP" 2>/dev/null)
    case "$_verdict:$_stamp" in
        0:*[!0-9]*|1:*[!0-9]*|0:|1:) ;;
        0:*|1:*) exit 0 ;;
    esac
fi

exec sh "$Z2K_TCP16_PROBE"
