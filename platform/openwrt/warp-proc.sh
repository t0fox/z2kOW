#!/bin/sh
# platform/openwrt/warp-proc.sh - process-only bounce WARP-демона (Stage 5).
#
# Вызывается refresh-binaries (au_service_for_binary, openwrt-ветка) как
#   warp-proc.sh stop   (до atomic replace: PBR down + kill)
#   warp-proc.sh start  (после: kill под новый inode + wait-ready + PBR up)
# DNS/nft-sets/exclusion НЕ трогаем (gap запрещён). (Ре)старт делает procd.
# start всегда возвращает 0 (fail-open; PBR доводит cron при живом ready).
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

# sbin — В КОНЕЦ (не в начало, как update.sh): операторский и тестовый
# PATH важнее системного (иначе настоящий /usr/sbin/ip забил бы мок/override);
# в cron-окружении sbin всё равно находится.
export PATH="$PATH:/usr/sbin:/sbin"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1
Z2K_WARP_SOURCE_ONLY=1; export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/warp.sh" || exit 1

case "${1:-}" in
    stop)
        warp_pbr_down 2>/dev/null || true
        if warp_running; then
            for _p in $(warp_pids); do _z2k_ow_warp_kill "$_p"; done
        fi
        exit 0
        ;;
    start)
        if warp_running; then
            for _p in $(warp_pids); do _z2k_ow_warp_kill "$_p"; done
        fi
        # Ждём ready ограниченно (тестам — WARP_PROC_WAIT); не дождались —
        # PBR доводит cron при живом ready. Возврат всегда 0 (fail-open).
        if _warp_wait_ready "${WARP_PROC_WAIT:-60}"; then
            warp_pbr_up >/dev/null 2>&1 || true
        fi
        exit 0
        ;;
    *)
        echo "usage: warp-proc.sh {stop|start}" >&2
        exit 1
        ;;
esac
