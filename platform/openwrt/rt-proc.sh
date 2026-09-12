#!/bin/sh
# platform/openwrt/rt-proc.sh - process-only bounce RT-демона (Stage 4).
#
# Вызывается refresh-binaries (au_service_for_binary, openwrt-ветка) как
#   rt-proc.sh stop   (до atomic replace)
#   rt-proc.sh start  (после)
# и разделяет stop_proxy/stop upstream S96: ТОЛЬКО kill процесса, DNS-пины,
# nft-redirect/guard и desync-exclusion НЕ трогаем (gap запрещён — клиент
# иначе закеширует реальный IP). (Ре)старт делает сам procd; второй kill
# в start гарантирует новый inode после подмены бинарника.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"

export PATH="/usr/sbin:/sbin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/rt.sh" || exit 1

case "${1:-}" in
    stop|start)
        if z2k_ow_rt_running; then
            for _p in $(z2k_ow_rt_pids); do _z2k_ow_rt_kill "$_p"; done
        fi
        exit 0
        ;;
    *)
        echo "usage: rt-proc.sh {stop|start}" >&2
        exit 1
        ;;
esac
