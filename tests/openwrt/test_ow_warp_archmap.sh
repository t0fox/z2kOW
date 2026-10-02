#!/bin/sh
# tests/openwrt/test_ow_warp_archmap.sh - WARP and the full-payload wrappers
# must select the same architecture from OpenWrt's DISTRIB_ARCH.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-archmap"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WARP="$REPO/platform/openwrt/warp.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-arch.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
printf "DISTRIB_ARCH='x86_64'\n" > "$T/openwrt_release"

# 1. standalone panel entry resolves the host architecture from arch.sh.
_out="$(Z2K_WARP_SOURCE_ONLY=1 Z2K_LIB="$REPO/lib" Z2K_ROOT="$REPO" \
    Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" \
    sh -c '. "$0"; warp_arch' "$WARP" 2>/dev/null)"
# Хост CI/WSL — x86_64 или aarch64: оба обязаны поддерживаться.
case "$_out" in
    x86_64|arm64) _t_ok ;;
    *) _t_bad "standalone warp_arch: [$_out]" ;;
esac

# 2. MIPS endianness comes from OpenWrt's target, not ambiguous uname -m.
printf "DISTRIB_ARCH='mipsel_24kc'\n" > "$T/openwrt_release"
_out="$(Z2K_WARP_SOURCE_ONLY=1 Z2K_ROOT="$REPO" Z2K_ADAPTER_DIR="$REPO/platform/openwrt" \
    Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" sh -c '. "$0"; warp_arch' "$WARP" 2>/dev/null)"
assert_eq "WARP architecture uses OpenWrt MIPS little-endian target" "mipsel" "$_out"

# 3. Missing OpenWrt arch selector reports its actual source.
_out="$(Z2K_WARP_SOURCE_ONLY=1 Z2K_LIB=/nonexistent Z2K_ROOT=/nonexistent \
    sh -c '. "$0"; warp_arch' "$WARP" 2>&1)"
_rc=$?
[ "$_rc" != "0" ] && _t_ok || _t_bad "без arch.sh warp_arch прошёл"
case "$_out" in
    *"arch.sh"*) _t_ok ;;
    *) _t_bad "без arch.sh нет причины в сообщении: [$_out]" ;;
esac

# 4. Architecture mapping is owned by platform/openwrt/arch.sh.
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
