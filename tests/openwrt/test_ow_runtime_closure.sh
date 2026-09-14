#!/bin/sh
# tests/openwrt/test_ow_runtime_closure.sh - runtime closure zapret2 без дрейфа.
#
# Канон: package/z2k-runtime/runtime-closure.txt (dest-пути под /opt/zapret2).
# Проверки:
#   1. code-refs ⊆ closure (firewall.sh, optbase.sh, def.sh/ipset-пути);
#   2. closure ⊆ recipe Makefile (каждый путь ставится явно);
#   3. ownership: /opt/zapret2/* class package;
#   4. tarball layout (только с Z2K_RT_TARBALL: настоящий релиз; без него —
#      громкий SKIP, как lua-less; локально tarball может отсутствовать).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-runtime-closure"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLOSURE="$REPO/package/z2k-runtime/runtime-closure.txt"
MK="$REPO/package/z2k-runtime/Makefile"
MAP="$REPO/package/openwrt/ownership.map"

assert_file "closure существует" "$CLOSURE"
assert_file "runtime Makefile существует" "$MK"

# --- 1. code-refs: firewall.sh требует functions; optbase.sh — 3 fork-lua ---
if grep -q 'init\.d/openwrt/functions' "$REPO/platform/openwrt/firewall.sh" 2>/dev/null; then
    if grep -qxF 'init.d/openwrt/functions' "$CLOSURE" 2>/dev/null; then _t_ok
    else _t_bad "closure: нет init.d/openwrt/functions (требует firewall.sh)"; fi
else
    _t_bad "code-ref: firewall.sh не упоминает functions"
fi
for _lua in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
    if grep -q "$_lua" "$REPO/platform/openwrt/optbase.sh" 2>/dev/null; then
        if grep -qxF "lua/$_lua" "$CLOSURE" 2>/dev/null; then _t_ok
        else _t_bad "closure: нет lua/$_lua (требует optbase.sh)"; fi
    else
        _t_bad "code-ref: optbase.sh не упоминает $_lua"
    fi
done
# common-ядро: functions сорсит ровно 9 файлов (имена — из upstream-файла;
# эталон зафиксирован здесь же, дрейф upstream/layout ловит секция tarball).
for _c in base.sh fwtype.sh linux_iphelper.sh ipt.sh nft.sh linux_fw.sh \
         linux_daemons.sh list.sh custom.sh; do
    if grep -qxF "common/$_c" "$CLOSURE" 2>/dev/null; then _t_ok
    else _t_bad "closure: нет common/$_c"; fi
done
# ipset-путь: IPSET_CR в upstream functions (def.sh тянется им же).
for _i in ipset/create_ipset.sh ipset/def.sh; do
    if grep -qxF "$_i" "$CLOSURE" 2>/dev/null; then _t_ok
    else _t_bad "closure: нет $_i"; fi
done
# бинарники: procd-cmdline (init) + def.sh (ip2net/mdig).
for _b in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
    if grep -qxF "$_b" "$CLOSURE" 2>/dev/null; then _t_ok
    else _t_bad "closure: нет $_b"; fi
done

# --- 2. closure ⊆ recipe: каждая строка ставится Makefile явно ---
_RC="$(sed -n '/^define Package\/z2k-zapret2-runtime\/install$/,/^endef$/p' "$MK" 2>/dev/null)"
[ -n "$_RC" ] || _t_bad "recipe z2k-zapret2-runtime/install не найден"
while IFS= read -r _e; do
    case "$_e" in ''|'#'*) continue ;; esac
    if printf '%s\n' "$_RC" | grep -qF -- "/opt/zapret2/$_e"; then _t_ok
    else _t_bad "recipe не ставит closure-путь: $_e"; fi
done < "$CLOSURE"

# --- 3. ownership: /opt/zapret2/* class package (apk-owned, updater не пишет) ---
if grep -qxF '/opt/zapret2/* package' "$MAP" 2>/dev/null; then _t_ok
else _t_bad "ownership.map: нет '/opt/zapret2/* package'"; fi

# --- 4. tarball layout: настоящий релиз содержит closure (с маппингами:
# .lua <- .lua.gz, бинарники <- binaries/<arch>/). Без tarball — SKIP. ---
if [ -n "${Z2K_RT_TARBALL:-}" ] && [ -f "$Z2K_RT_TARBALL" ]; then
    _tl="$(mktemp)" || exit 1
    if tar -tzf "$Z2K_RT_TARBALL" > "$_tl" 2>/dev/null; then
        _top="$(sed -n 's|^\([^/]*\)/$|\1|p' "$_tl" | head -1)"
        [ -n "$_top" ] || _t_bad "tarball: нет topdir"
        while IFS= read -r _e; do
            case "$_e" in ''|'#'*) continue ;; esac
            case "$_e" in
                lua/*.lua)
                    _tp="$_top/lua/$(basename "$_e" .lua).lua.gz" ;;
                nfq2/*|ip2net/*|mdig/*)
                    _tp="$_top/binaries/linux-arm64/$(basename "$_e")" ;;
                *) _tp="$_top/$_e" ;;
            esac
            if grep -qxF "$_tp" "$_tl" 2>/dev/null; then _t_ok
            else _t_bad "tarball: нет $_tp (closure: $_e)"; fi
        done < "$CLOSURE"
        # arm64 ELF proof прямо на tarball-бинарнике.
        _nfq="$_top/binaries/linux-arm64/nfqws2"
        if tar -xzOf "$Z2K_RT_TARBALL" "$_nfq" 2>/dev/null | od -An -tx1 -j18 -N1 2>/dev/null | grep -q 'b7'; then _t_ok
        else _t_bad "tarball: nfqws2 не AArch64 (e_machine!=0xb7)"; fi
    else
        _t_bad "tarball не читается: $Z2K_RT_TARBALL"
    fi
    rm -f "$_tl"
else
    echo "SKIP[ow-runtime-closure]: нет Z2K_RT_TARBALL (релизный tarball; в CI подкладывается)"
    echo "SUITE-SECTION[ow-runtime-closure-tarball]: skipped"
fi

_t_done
