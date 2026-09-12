#!/bin/sh
# platform/openwrt/tg-check.sh - cron entrypoint TG health-check (Stage 3).
# Каждые 5 минут: конвергенция TG rules + probe + kill-only backoff.
# Никогда не стартует демона (это делает procd) и не воскрешает при disable.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

export PATH="/usr/sbin:/sbin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/tg.sh" || exit 0

[ "${1:-check}" = "check" ] || { echo "usage: tg-check.sh [check]" >&2; exit 1; }
z2k_ow_tg check
exit 0
