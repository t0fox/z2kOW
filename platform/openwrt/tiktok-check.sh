#!/bin/sh
# Periodic TikTok CDN health/failover entrypoint.
set -eu
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ADAPTER_DIR="${Z2K_ADAPTER_DIR:-$Z2K_ROOT/platform/openwrt}"
. "$Z2K_ADAPTER_DIR/paths.sh"
. "$Z2K_ADAPTER_DIR/env.sh"
. "$Z2K_ADAPTER_DIR/tiktok.sh"

# A stopped z2k service must not be able to resurrect its DNS override from a
# cron process that started just before stop_service removed the schedule.
_ready="${Z2K_CORE_READY:-${Z2K_RUN:-/tmp/z2k/runtime}/core-ready}"
[ -e "$_ready" ] || exit 0
Z2K_TIKTOK_REQUIRE_READY="$_ready"
export Z2K_TIKTOK_REQUIRE_READY

_lock="${Z2K_TIKTOK_LOCK_DIR:-${Z2K_TMP:-/tmp/z2k}/tiktok-check.lock}"
if ! mkdir "$_lock" 2>/dev/null; then
    exit 0
fi
cleanup() { rmdir "$_lock" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

case "${1:-check}" in
    check) z2k_ow_tiktok_check "${2:-automatic}" ;;
    *) echo 'usage: tiktok-check.sh check [explicit|scheduled]' >&2; exit 2 ;;
esac
