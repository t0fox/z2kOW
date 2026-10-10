#!/bin/sh
# platform/openwrt/fw-check.sh - cron entrypoint core firewall health (p-84.20).
# Каждые 5 минут: тот же сериализованный путь reconciliation, что и нативное
# событие fw4. Проверяется каждое required-состояние; повтор ограничен и
# состояние dataplane доказывается перед успешным возвратом.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

export PATH="/usr/sbin:/sbin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 0
. "$Z2K_ROOT/platform/openwrt/firewall.sh" || exit 0

[ "${1:-check}" = "check" ] || { echo "usage: fw-check.sh [check]" >&2; exit 1; }
z2k_ow_fw_event check
exit $?
