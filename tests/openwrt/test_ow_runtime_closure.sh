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
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtclosure.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

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
        # arm64 ELF proof прямо на tarball-бинарнике: e_machine (offset 18,
        # 2 байта LE), AArch64 = 183 = 0xB7. ТОЛЬКО dd+case (как detect_endianness
        # в lib/utils.sh): BusyBox od не знает -A/-j/-N (сторожит
        # test_router_shell_portability, issue #43), -c единственный
        # разрешённый флаг — а нам нужен БАЙТ, не символ.
        _nfq="$_top/binaries/linux-arm64/nfqws2"
        _em="$(tar -xzOf "$Z2K_RT_TARBALL" "$_nfq" 2>/dev/null | dd bs=1 skip=18 count=1 2>/dev/null)"
        case "$_em" in
            "$(printf '\267')") _t_ok ;;
            *) _t_bad "tarball: nfqws2 не AArch64 (e_machine low byte не 0xB7)" ;;
        esac
    else
        _t_bad "tarball не читается: $Z2K_RT_TARBALL"
    fi
    rm -f "$_tl"
else
    echo "SKIP[ow-runtime-closure]: нет Z2K_RT_TARBALL (релизный tarball; в CI подкладывается)"
    echo "SUITE-SECTION[ow-runtime-closure-tarball]: skipped"
fi

# --- 5. recipe исполняется (тот же текст, не эмуляция): извлекаем install-
# рецепт из Makefile, подменяем make-функции shell-эквивалентами и гоняем
# на настоящем tarball. Ловит опечатки путей/gunzip, которые grep-гейты
# выше не видят. Только с Z2K_RT_TARBALL (как секция 4). ---
if [ -n "${Z2K_RT_TARBALL:-}" ] && [ -f "$Z2K_RT_TARBALL" ]; then
    _rx="$(mktemp -d "$T/rtx.XXXXXX")" || exit 1
    tar -xzf "$Z2K_RT_TARBALL" -C "$_rx" || { echo "FAIL[ow-runtime-closure]: recipe extract" >&2; exit 1; }
    _rdest="$T/recipe-dest"
    mkdir -p "$_rdest" || exit 1
    sed -n '/^define Package\/z2k-zapret2-runtime\/install$/,/^endef$/p' "$MK" \
        | grep -v '^define ' | grep -v '^endef$' > "$T/recipe.sh"
    # ARCH-guard: симулируем целевой env (сам guard проверен статикой выше);
    # make-функции -> shell: INSTALL_DIR=mkdir, INSTALL_BIN/DATA=install.
    ( ARCH=aarch64
      export ARCH
      _1="$_rdest"
      _PBD="$_rx"
      _TOP="$(sed -n 's/^Z2K_RT_TOPDIR:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
      _BA="linux-arm64"
      [ -n "$_TOP" ] || exit 1
      sed -e 's/\$(INSTALL_DIR)/mkdir -p/g' -e 's/\$(INSTALL_BIN)/install -m0755/g' \
          -e 's/\$(INSTALL_DATA)/install -m0644/g' -e "s|\$(1)|$_1|g" \
          -e "s|\$(PKG_BUILD_DIR)|$_PBD|g" -e "s|\$(Z2K_RT_TOPDIR)|$_TOP|g" \
          -e "s|\$(Z2K_RT_BINARCH)|$_BA|g" -e 's/\$(ARCH)/$ARCH/g' \
          "$T/recipe.sh" > "$T/recipe-run.sh"
      sh -n "$T/recipe-run.sh" || exit 1
      sh "$T/recipe-run.sh" || exit 1
    ) || _t_bad "recipe не исполнился на настоящем tarball"
    _rc_n=0
    while IFS= read -r _e; do
        case "$_e" in ''|'#'*) continue ;; esac
        if [ -f "$_rdest/opt/zapret2/$_e" ]; then _t_ok
        else _t_bad "recipe: нет результата $_e"; fi
        _rc_n=$((_rc_n + 1))
    done < "$CLOSURE"
    _cl_n="$(grep -vcE '^#|^$' "$CLOSURE")"
    assert_eq "recipe: файлов как в closure" "$_cl_n" "$_rc_n"
    for _x in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
        if [ -x "$_rdest/opt/zapret2/$_x" ]; then _t_ok
        else _t_bad "recipe: $_x не +x"; fi
    done
    # lua распакован (первые байты — не gzip-магия 1f8b).
    if [ "$(head -c 2 "$_rdest/opt/zapret2/lua/zapret-lib.lua" 2>/dev/null)" = "$(printf '\037\213')" ]; then
        _t_bad "recipe: lua не распаковался (gzip внутри)"
    else
        _t_ok
    fi
else
    echo "SKIP[ow-runtime-closure]: recipe-exec без Z2K_RT_TARBALL"
fi

_t_done
