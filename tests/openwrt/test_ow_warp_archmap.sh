#!/bin/sh
# tests/openwrt/test_ow_warp_archmap.sh - live-урок: standalone `sh warp.sh
# install` из панели падал с "unsupported architecture" на ПОДДЕРЖИВАЕМОЙ
# арке — map_arch_to_bin_arch из common utils не был подсорсен, и warp_arch
# молча возвращал 1. Карта НЕ дублируется (владеет upstream utils):
# warp_arch подтягивает её best-effort, а без неё отказывает громко.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-archmap"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WARP="$REPO/platform/openwrt/warp.sh"

# 1. без utils в окружении, но с доступным файлом: карта подтягивается.
_out="$(Z2K_WARP_SOURCE_ONLY=1 Z2K_LIB="$REPO/lib" Z2K_ROOT="$REPO" \
    sh -c '. "$0"; warp_arch' "$WARP" 2>/dev/null)"
# Хост CI/WSL — x86_64 или aarch64: оба обязаны маппиться (карта покрывает).
case "$_out" in
    x86_64|arm64) _t_ok ;;
    *) _t_bad "standalone warp_arch без utils: [$_out]" ;;
esac

# 2. utils недоступен вовсе: громкий отказ с причиной, а не голое молчание.
_out="$(Z2K_WARP_SOURCE_ONLY=1 Z2K_LIB=/nonexistent Z2K_ROOT=/nonexistent \
    sh -c '. "$0"; warp_arch' "$WARP" 2>&1)"
_rc=$?
[ "$_rc" != "0" ] && _t_ok || _t_bad "без utils warp_arch прошёл"
case "$_out" in
    *"utils.sh"*) _t_ok ;;
    *) _t_bad "без utils нет причины в сообщении: [$_out]" ;;
esac

# 3. карта НЕ продублирована в warp.sh (владелец — lib/utils.sh).
if grep -q 'linux-mipsel' "$WARP" 2>/dev/null; then
    _t_bad "карта арок продублирована в warp.sh"
else
    _t_ok
fi
# Единственное упоминание linux- — пути артефактов (2), комментарий и
# strip-префикс: итого 5. Рост сверх — ревьюить на дублирование карты.
_n="$(grep -c 'linux-' "$WARP" 2>/dev/null)"
[ "$_n" -le 5 ] && _t_ok || _t_bad "подозрительно много linux- в warp.sh: $_n"

_t_done
