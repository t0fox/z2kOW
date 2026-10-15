#!/bin/sh
# Тонкий updater-hook: вся координация процесса и маршрутизации находится в Rust.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"
export PATH="$PATH:/usr/sbin:/sbin"

case "${1:-}" in
    stop|start) action="$1" ;;
    *) echo "использование: warp-proc.sh {stop|start}" >&2; exit 1 ;;
esac
[ "$#" -eq 1 ] || { echo "warp-proc.sh: лишние аргументы" >&2; exit 1; }

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/warp.sh" || exit 1

[ -x "${WARP_CONTROLLER_BIN:-}" ] || {
    echo "warp-proc.sh: бинарник Rust-контроллера WARP отсутствует" >&2
    exit 127
}
exec env Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" \
    "$WARP_CONTROLLER_BIN" engine-refresh "$action"
