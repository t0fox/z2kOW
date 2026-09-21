#!/bin/sh
# tests/openwrt/test_ow_warp_static.sh - Stage 5 Layer A: статика WARP glue.
# Никаких iptables/ipset/PPE/0x989/OUTPUT-mark/supervisor; opt-in;
# канонические фильтры и константы совпадают с upstream.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-static"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WARP="$REPO/platform/openwrt/warp.sh"
WARPP="$REPO/platform/openwrt/warp-proc.sh"
WARPC="$REPO/platform/openwrt/warp-check.sh"
INIT="$REPO/package/openwrt/files/etc/init.d/z2k"
HOTPLUG="$REPO/package/openwrt/files/etc/hotplug.d/iface/90-z2k"
SCHED="$REPO/platform/openwrt/schedule.sh"
UNINST="$REPO/platform/openwrt/uninstall.sh"
MK="$REPO/package/openwrt/Makefile"
MAP="$REPO/package/openwrt/ownership.map"
AU="$REPO/lib/auto_update.sh"
S96="$REPO/files/z2k-warp.sh"
FW4="$REPO/package/openwrt/files/etc/nftables.d/chain-pre/forward/90-z2k-warp.nft"

assert_file "warp.sh существует" "$WARP"
assert_file "warp-proc.sh существует" "$WARPP"
assert_file "warp-check.sh существует" "$WARPC"
assert_file "fw4 WARP chain-pre include существует" "$FW4"
assert_contains "fw4 WARP include is mark-scoped" "$FW4" \
    'meta mark & 0x80000000 == 0x80000000 oifname "z2ktun*" accept'

# Tripwire класса heredoc-backtick: dash ПАРСИТ backquotes внутри unquoted
# heredoc (и выполняет их при сборке моков) — однажды это молча роняло весь
# lifecycle-сьют. Все скрипты слоя, ВКЛЮЧАЯ сами тесты, проходят dash -n.
for _f in "$WARP" "$WARPP" "$WARPC" \
    "$REPO/tests/openwrt/test_ow_warp_static.sh" \
    "$REPO/tests/openwrt/test_ow_warp_functional.sh" \
    "$REPO/tests/openwrt/test_ow_warp_lifecycle.sh"; do
    if sh -n "$_f" 2>/dev/null; then _t_ok; else _t_bad "dash -n: $(basename "$_f")"; fi
done

# Код без комментариев для запретов.
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-ws.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
_WCODE="$T/warp.code"; _WPCODE="$T/warpp.code"; _WCCODE="$T/warpc.code"
sed 's/#.*$//' "$WARP" > "$_WCODE"
sed 's/#.*$//' "$WARPP" > "$_WPCODE"
sed 's/#.*$//' "$WARPC" > "$_WCCODE"

# --- нет Keenetic-стека в glue (литералы разорваны: гард forbidden
# сканирует и этот файл, исключая только себя) ---
for _f in "$_WCODE" "$_WPCODE" "$_WCCODE"; do
    assert_not_contains "glue: нет iptables" "$_f" 'iptables'
    # Узкое исключение Stage 6: верб `ipset` (имя требует контракт панели,
    # как keenetic files/z2k-warp.sh) + его определение + usage-строки;
    # реализация — тот же atomic sets_load, инструмента ipset в коде нет.
    if grep -v 'warp_ipset\|ipset[)|]' "$_f" | grep -q 'ipset'; then
        _t_bad "glue: ipset вне ipset-верба в $(basename "$_f")"
    else
        _t_ok
    fi
    assert_not_contains "glue: нет PPE" "$_f" 'PPE'
    assert_not_contains "glue: нет /opt" "$_f" '/opt'
done
# Defect 2: live sets обновляются ТОЛЬКО одной nft-транзакцией — отдельного
# `nft flush set` (потеря контента при mid-failure) в коде быть не может.
# Batch helper пишет "flush set" через echo в `nft -f -`, это не матчится.
assert_not_contains "sets: нет отдельного live flush" "$_WCODE" 'nft flush set'
assert_contains "sets: atomic batch через nft -f -" "$WARP" 'nft -f -'
# Defect 2: service state — только через procd/init, НЕ pidof конкретного
# демона (мёртвый nfqws2 при живом сервисе врал бы "остановлен").
assert_not_contains "warp: нет pidof-детектива сервиса" "$_WCODE" 'pidof nfqws2'
# Defect 8: flock не гарантирован на target — лок обязан быть mkdir-based.
assert_not_contains "warp: нет flock-зависимости" "$_WCODE" 'flock'
assert_contains "warp: mutation lock helper" "$WARP" '_z2k_ow_warp_lock()'
assert_contains "warp: service-state helper" "$WARP" '_z2k_ow_service_running()'
# Defect 4: каждый `ip rule del` обязан нести pref (exact owned delete).
# Комментарии режем (атрибуция упоминает del без pref в тексте).
if sed 's/#.*$//' "$WARP" 2>/dev/null | grep 'ip rule del' | grep -qv 'pref'; then
    _t_bad "warp.sh: ip rule del без pref"
else
    _t_ok
fi

# --- нет shell-supervisor'а ---
for _pat in 'while :' '(^|[^_A-Za-z0-9])PIDFILE=' 'sleep \$backoff'; do
    assert_not_contains "warp.sh: нет supervisor-признака ($_pat)" "$_WCODE" "$_pat"
done
assert_contains "warp.sh: respawn bounded exact" "$WARP" 'procd_set_param respawn 3600 5 5'
if grep -qE 'procd_set_param respawn[[:space:]]*$' "$WARP"; then
    _t_bad "warp.sh: голый respawn без explicit параметров"
else
    _t_ok
fi
assert_contains "warp.sh: GODEBUG (mips-guard как S51)" "$WARP" 'GODEBUG=asyncpreemptoff=1'

# --- один procd instance z2k-warp, второго сервиса нет ---
assert_contains "warp.sh: instance z2k-warp" "$WARP" 'procd_open_instance "z2k-warp"'
assert_eq "procd_open_instance в коде один" "1" "$(grep -c 'procd_open_instance "z2k-warp"' "$_WCODE")"
if [ -f "$REPO/package/openwrt/files/etc/init.d/z2k-warp" ]; then
    _t_bad "второй init-сервис z2k-warp существует"
else
    _t_ok
fi

# --- mark/mask/table/pref: НЕ keenetic, disjoint по аудиту ---
assert_contains "warp.sh: mark бит31" "$WARP" 'WARP_MARK="${WARP_MARK:-0x80000000}"'
assert_contains "warp.sh: mask бит31" "$WARP" 'WARP_MASK="${WARP_MASK:-0x80000000}"'
if grep -q '0x989' "$_WCODE"; then
    _t_bad "warp.sh: keenetic-mark 0x989 в коде"
else
    _t_ok
fi
assert_contains "warp.sh: table 989" "$WARP" 'WARP_TABLE="${WARP_TABLE:-989}"'
assert_contains "warp.sh: pref 500" "$WARP" 'WARP_RULE_PREF="${WARP_RULE_PREF:-500}"'
# masked op, не blind set-mark:
assert_contains "warp.sh: masked mark op" "$WARP" "meta mark set mark '&' 0x7fffffff '^' 0x80000000"
assert_contains "warp.sh: verifies final fw4 forward policy" "$WARP" '_warp_fw4_forward_verify'
assert_contains "warp.sh: runtime fw4 fallback is exact" "$WARP" 'nft insert rule "$WARP_FW4_FAMILY"'
if grep -qE 'meta mark set 0x' "$_WCODE"; then
    _t_bad "warp.sh: blind mark-assign (чужие биты не выживут)"
else
    _t_ok
fi

# --- NO OUTPUT mark (upstream инвариант после удаления) ---
if grep -E 'hook output' "$_WCODE" | grep -q 'mark set'; then
    _t_bad "warp.sh: mark в OUTPUT"
else
    _t_ok
fi
# ...но OUTPUT-хук для v6-reject-подобных? нет: наши chains — prerouting/
# forward/postrouting только. Проверяем отсутствие output-mark строго:
assert_not_contains "warp.sh: нет mark в output-цепочках" "$_WCODE" 'hook output.*mark set'

# --- opt-in: seed/пакет не ставят бинарь и флаг ---
assert_not_contains "seed: нет warpd" "$REPO/package/openwrt/make-seed.sh" 'warpd'
assert_contains "генератор: флаг дефолт 0" "$REPO/lib/config_official.sh" 'saved_GAME_WARP_ENABLED="0"'

# --- канонические фильтры байт-в-байт (маркеры сами пропускаем: счётчик
# копий в них устаревает, тело обязано совпадать; upstream-тройка сверяется
# своим тестом целиком) ---
_addr_of() { awk '/^# --- z2k warp address filter/,/^# --- end z2k warp address filter/' "$1" | grep -v '^# ---' | sed 's/^[[:space:]]*//'; }
_src_of() { awk '/^# --- z2k warp SOURCE filter/,/^# --- end z2k warp SOURCE filter/' "$1" | grep -v '^# ---' | sed 's/^[[:space:]]*//'; }
_canon_addr="$(_addr_of "$S96")"
assert_eq "addr-фильтр непуст" "1" "$([ -n "$_canon_addr" ] && echo 1 || echo 0)"
assert_eq "addr-фильтр identical" "$_canon_addr" "$(_addr_of "$WARP")"
_canon_src="$(_src_of "$S96")"
assert_eq "source-фильтр identical" "$_canon_src" "$(_src_of "$WARP")"

# --- MSS coupling с Go-константой (как test_warp_mss_both_ways) ---
_MTU="$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$REPO/z2k-warpd/internal/engine/engine.go" | head -1)"
assert_eq "MTU читается" "1280" "$_MTU"
assert_eq "inbound MSS = MTU-40" "set 1240" "$(grep -o 'maxseg size set [0-9][0-9]*' "$WARP" | head -1 | sed 's/.*size //')"
assert_contains "outbound clamp-to-PMTU" "$WARP" 'maxseg size set rt mtu'
if grep -q 'iifname.*clamp-mss-to-pmtu\|maxseg size set rt mtu.*iifname' "$_WCODE"; then
    _t_bad "warp.sh: зеркальный PMTU-clamp на inbound (дал бы 1460)"
else
    _t_ok
fi

# --- VPS-proxy default равен трём копиям (S51, z2k-warp.sh, warp.sh) ---
# (закрывающие }} S96-формы отрезаем классом [^" }] — иначе мусор в сравнении)
_up1="$(grep -m1 -o 'http://z2kwarp:[^" }]*' "$S96")"
_up2="$(grep -m1 -o 'http://z2kwarp:[^" }]*' "$REPO/files/init.d/S51z2k-warp")"
_up3="$(grep -m1 -o 'http://z2kwarp:[^" }]*' "$WARP")"
assert_eq "proxy-default во всех копиях" "$_up1" "$_up2"
assert_eq "proxy-default в адаптере" "$_up1" "$_up3"
# секрет релея не печатается кодом (только --proxy аргумент и дефолт):
if grep -v '^WARP_VPS_PROXY_DEFAULT=' "$_WCODE" | grep -q 'z2kW4rpR3g2026'; then
    _t_bad "warp.sh: секрет релея вне дефолта"
else
    _t_ok
fi

# --- проводка: init / hotplug / schedule / uninstall ---
assert_contains "init: warp.sh подключён (source-only)" "$INIT" 'Z2K_WARP_SOURCE_ONLY=1'
assert_contains "init: boot зовёт warp 1" "$INIT" 'z2k_ow_warp 1'
assert_contains "init: стоп зовёт warp 0" "$INIT" 'z2k_ow_warp 0'
assert_contains "hotplug: WARP reconverge" "$HOTPLUG" 'z2k_ow_warp rules'
assert_contains "schedule: warp-health строка" "$SCHED" 'z2k-warp-health'
assert_contains "schedule: warp-check entrypoint" "$SCHED" 'warp-check.sh check'
assert_contains "schedule: install пара" "$SCHED" 'z2k_ow_warp_cron_install'
assert_contains "schedule: remove пара" "$SCHED" 'z2k_ow_warp_cron_remove'
assert_contains "uninstall: warp cleanup" "$UNINST" 'z2k_ow_warp cleanup'
assert_contains "uninstall: warp cron remove" "$UNINST" 'z2k_ow_warp_cron_remove'
assert_contains "ownership: warp.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/warp.sh package'
assert_contains "ownership: warp-proc.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/warp-proc.sh package'
assert_contains "ownership: warp-check.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/warp-check.sh package'
assert_contains "ownership: device daemon-state" "$MAP" '/etc/z2k/state/warp/device.json daemon-state'
assert_contains "ownership: fw4 include package" "$MAP" \
    '/etc/nftables.d/chain-pre/forward/90-z2k-warp.nft package'
assert_contains "Makefile: fw4 include install" "$MK" \
    'files/etc/nftables.d/chain-pre/forward/90-z2k-warp.nft'

# --- COMMON_HOOK в au_service_for_binary + Makefile BIN modes ---
assert_contains "au: warp openwrt-ветка" "$AU" 'warp-proc.sh'
assert_contains "au: keenetic S51 цел" "$AU" '/opt/etc/init.d/S51z2k-warp'
# Entrypoints — в INSTALL_BIN-блоке Makefile (исполняются напрямую:
# cron exec, updater [ -x ]); остальное может оставаться INSTALL_DATA.
# Пути — через $(Z2K_TREE) (рецепт работает из package/openwrt/).
_binblock="$(awk '/\$\(INSTALL_BIN\) .*platform\/openwrt\//,/usr\/lib\/z2k\/platform\/openwrt\/$/' "$MK")"
for _e in update.sh tg-check.sh rt-check.sh rt-proc.sh warp.sh warp-proc.sh warp-check.sh; do
    if printf '%s' "$_binblock" | grep -qF "$_e"; then _t_ok; else _t_bad "Makefile: $_e не в INSTALL_BIN"; fi
done
# Истина — в git-индексе (worktree-режимы на Windows/DrvFs врут):
for _e in update.sh tg-check.sh rt-check.sh rt-proc.sh warp.sh warp-proc.sh warp-check.sh; do
    if git -C "$REPO" ls-files -s "platform/openwrt/$_e" 2>/dev/null | grep -q '^100755'; then
        _t_ok
    else
        _t_bad "index: $_e не 755 (seed/пакет потеряют +x)"
    fi
done

_t_done
