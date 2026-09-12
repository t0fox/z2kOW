#!/bin/sh
# platform/openwrt/rt-check.sh - cron entrypoint RT health-check (Stage 4).
# Каждые 5 минут: конвергенция RT (DNS/rules/whitelist) + halt-teardown
# при стойкой смерти демона. Демона не стартует (это делает procd).
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

export PATH="/usr/sbin:/sbin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/rt.sh" || exit 0

[ "${1:-check}" = "check" ] || { echo "usage: rt-check.sh [check]" >&2; exit 1; }
Z2K_RT_QUIET=1; export Z2K_RT_QUIET
z2k_ow_rt check
exit 0
