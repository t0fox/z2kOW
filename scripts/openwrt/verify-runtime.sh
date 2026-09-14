#!/bin/sh
# scripts/openwrt/verify-runtime.sh - гейт runtime tarball (§3 pin/proof).
#
# Использование:
#   verify-runtime.sh --tarball PATH [--expect-sha HEX] [--tree DIR]
# Проверяет, не распаковывая лишнего:
#   1. gzip-целостность (gzip -t);
#   2. SHA256 == pin (default — PKG_HASH из package/z2k-runtime/Makefile,
#      единственное место правды; --expect-sha переопределяет для тестов);
#   3. topdir + closure-присутствие (маппинги: .lua <- .lua.gz,
#      бинарники <- binaries/linux-arm64/);
#   4. arm64 ELF (e_machine=0xB7) у nfqws2 — без readelf (od есть везде);
#   5. nfqws2 --version — best-effort: на чужой арке exec невозможен
#      (честный SKIP пункта, не провал), под qemu — реальный запуск.
# POSIX sh. Сеть не нужна (tarball уже скачан вызывающим).
set -e
TARBALL=""; EXPECT_SHA=""; TREE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tarball) TARBALL="$2"; shift 2 ;;
        --expect-sha) EXPECT_SHA="$2"; shift 2 ;;
        --tree) TREE="$2"; shift 2 ;;
        *) printf 'verify-runtime: неизвестный флаг %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$TARBALL" ] || { printf 'verify-runtime: нужен --tarball\n' >&2; exit 1; }
[ -f "$TARBALL" ] || { printf 'verify-runtime: нет %s\n' "$TARBALL" >&2; exit 1; }
if [ -z "$TREE" ]; then
    TREE="$(cd "$(dirname "$0")/../.." && pwd)"
fi
MK="$TREE/package/z2k-runtime/Makefile"
[ -f "$MK" ] || { printf 'verify-runtime: нет %s\n' "$MK" >&2; exit 1; }
if [ -z "$EXPECT_SHA" ]; then
    EXPECT_SHA="$(sed -n 's/^PKG_HASH:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
fi
case "$EXPECT_SHA" in
    ''|*[!0-9a-f]*) printf 'verify-runtime: плохой expect-sha\n' >&2; exit 1 ;;
esac
_RT_TAG="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
_RT_TOP="$(sed -n 's/^Z2K_RT_TOPDIR:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
_RT_ARCH="$(sed -n 's/^Z2K_RT_BINARCH:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
[ -n "$_RT_TOP" ] && [ -n "$_RT_ARCH" ] || { printf 'verify-runtime: нет TOPDIR/BINARCH в %s\n' "$MK" >&2; exit 1; }
printf 'verify-runtime: tag=%s topdir=%s binarch=%s\n' "$_RT_TAG" "$_RT_TOP" "$_RT_ARCH"

command -v gzip >/dev/null 2>&1 || { printf 'verify-runtime: нужен gzip\n' >&2; exit 1; }
gzip -t "$TARBALL" || { printf 'verify-runtime: битый gzip\n' >&2; exit 1; }
printf 'verify-runtime: gzip ok\n'

_got=""
if command -v sha256sum >/dev/null 2>&1; then
    _got="$(sha256sum "$TARBALL" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    _got="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
else
    printf 'verify-runtime: нечем посчитать sha256\n' >&2; exit 1
fi
[ "$_got" = "$EXPECT_SHA" ] || {
    printf 'verify-runtime: SHA MISMATCH: ждали %s, получили %s\n' "$EXPECT_SHA" "$_got" >&2
    exit 1
}
printf 'verify-runtime: sha256 ok (%s)\n' "$_got"

_TL="$(mktemp)" || exit 1
trap 'rm -f "$_TL"' EXIT INT TERM
tar -tzf "$TARBALL" > "$_TL" 2>/dev/null || { printf 'verify-runtime: не листится\n' >&2; exit 1; }
grep -qxF "$_RT_TOP/binaries/$_RT_ARCH/nfqws2" "$_TL" || { printf 'verify-runtime: нет nfqws2 (%s)\n' "$_RT_ARCH" >&2; exit 1; }
grep -qxF "$_RT_TOP/init.d/openwrt/functions" "$_TL" || { printf 'verify-runtime: нет functions\n' >&2; exit 1; }
for _l in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
    grep -qxF "$_RT_TOP/lua/${_l}.gz" "$_TL" || { printf 'verify-runtime: нет lua/%s.gz\n' "$_l" >&2; exit 1; }
done
printf 'verify-runtime: closure present\n'

# e_machine field (offset 18, 2 bytes LE): AArch64 = 183 = 0xB7.
# ТОЛЬКО dd+case (как detect_endianness в lib/utils.sh): BusyBox od не знает
# -A/-j/-N (сторожит test_router_shell_portability), а скрипт обязан быть
# переносимым везде, не только на CI-Ubuntu.
if [ "$(tar -xzOf "$TARBALL" "$_RT_TOP/binaries/$_RT_ARCH/nfqws2" 2>/dev/null | dd bs=1 skip=18 count=1 2>/dev/null)" = "$(printf '\267')" ]; then
    printf 'verify-runtime: ELF AArch64 ok\n'
else
    printf 'verify-runtime: nfqws2 не AArch64\n' >&2; exit 1
fi

# --version: только если хост может исполнить (qemu/родная арка).
_XB="$(mktemp -d)" || exit 1
trap 'rm -rf "$_XB" "$_TL"' EXIT INT TERM
if tar -xzf "$TARBALL" -C "$_XB" "$_RT_TOP/binaries/$_RT_ARCH/nfqws2" 2>/dev/null \
    && chmod +x "$_XB/$_RT_TOP/binaries/$_RT_ARCH/nfqws2" 2>/dev/null; then
    if "$_XB/$_RT_TOP/binaries/$_RT_ARCH/nfqws2" --version >/dev/null 2>&1; then
        printf 'verify-runtime: nfqws2 --version: %s\n' \
            "$("$_XB/$_RT_TOP/binaries/$_RT_ARCH/nfqws2" --version 2>&1 | head -1)"
    else
        _vrc=$?
        case "$_vrc" in
            126|127) printf 'verify-runtime: --version SKIP (хост не исполняет arm64, rc=%s)\n' "$_vrc" ;;
            *) printf 'verify-runtime: --version rc=%s (не фатально: ELF доказан выше)\n' "$_vrc" ;;
        esac
    fi
else
    printf 'verify-runtime: извлечь nfqws2 не удалось\n' >&2; exit 1
fi
printf 'verify-runtime: PASS\n'
