#!/bin/sh
# tests/openwrt/test_ow_tg_static.sh - Stage 3 Layer A: статика TG glue.
# Никаких /opt, iptables/ipset/NDM, shell-supervisor'а, второго сервиса;
# один процесс на оба порта; ownership disjoint; секреты не печатаются.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-static"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TG="$REPO/platform/openwrt/tg.sh"
TGC="$REPO/platform/openwrt/tg-check.sh"
INIT="$REPO/package/openwrt/files/etc/init.d/z2k"
HOTPLUG="$REPO/package/openwrt/files/etc/hotplug.d/iface/90-z2k"
SCHED="$REPO/platform/openwrt/schedule.sh"
UNINST="$REPO/platform/openwrt/uninstall.sh"
MK="$REPO/package/openwrt/Makefile"
MAP="$REPO/package/openwrt/ownership.map"
AU="$REPO/lib/auto_update.sh"

assert_file "tg.sh существует" "$TG"
assert_file "tg-check.sh существует" "$TGC"

# Запреты проверяем по коду БЕЗ комментариев (в rationale можно упоминать
# iptables/set -x словами; исполнять — нельзя).
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgs.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
_TGCODE="$T/tg.code"; _TGCCODE="$T/tgc.code"
sed 's/#.*$//' "$TG" > "$_TGCODE"
sed 's/#.*$//' "$TGC" > "$_TGCCODE"

# --- нет keenetic-путей и чужого firewall-стека в glue ---
for _f in "$_TGCODE" "$_TGCCODE"; do
    _b="glue"
    assert_not_contains "$_b: нет /opt" "$_f" '/opt'
    assert_not_contains "$_b: нет iptables" "$_f" 'iptables'
    assert_not_contains "$_b: нет ipset" "$_f" 'ipset'
    assert_not_contains "$_b: нет NDM" "$_f" 'NDM|ndm'
done
# conntrack только целевой -D -d (никакого flush всего): каждая кодовая
# строка, ВЫЗЫВАЮЩАЯ бинарник (не имя функции), обязана содержать "-D -d".
_tg_ct_calls="$(grep -E '(^|[;|& ]+)conntrack ' "$_TGCODE" || true)"
if [ -n "$_tg_ct_calls" ] && [ -z "$(printf '%s\n' "$_tg_ct_calls" | grep -vF -- '-D -d' || true)" ]; then
    _t_ok
else
    _t_bad "tg.sh: conntrack-вызов не целевой (-D -d): [$_tg_ct_calls]"
fi

# --- нет shell-supervisor'а (это делает procd) ---
# (Z2K_TG_PIDFILE — procd pidfile-параметр, не supervisor-PIDFILE: требуем
# отсутствие ГОЛОГО PIDFILE=/GENFILE= присваивания)
for _pat in 'while :' '(^|[^_A-Za-z0-9])PIDFILE=' '(^|[^_A-Za-z0-9])GENFILE=' 'sleep \$backoff'; do
    assert_not_contains "tg.sh: нет supervisor-признака ($_pat)" "$_TGCODE" "$_pat"
done
assert_contains "tg.sh: respawn через procd" "$TG" 'procd_set_param respawn 3600 5 5'
# голого respawn (неявные дефолты) и retry=0 (бесконечный шторм) быть не должно
if grep -qE 'procd_set_param respawn[[:space:]]*$' "$TG"; then
    _t_bad "tg.sh: голый respawn без explicit параметров"
else
    _t_ok
fi
if grep -qE 'procd_set_param respawn [0-9]+ [0-9]+ 0([^0-9]|$)' "$TG"; then
    _t_bad "tg.sh: retry=0 (бесконечный crash-loop)"
else
    _t_ok
fi
# приоритеты — plain integers (арифметика dstnat/filter - N зависит от парсера)
for _bad in 'priority dstnat -' 'priority dstnat +' 'priority filter -' 'priority filter +'; do
    assert_not_contains "tg.sh: нет арифметики приоритетов ($_bad)" "$_TGCODE" "$_bad"
done

# --- один процесс на оба порта ---
assert_contains "tg.sh: argv строит оба listen" "$TG" '"--listen=:$Z2K_TG_PORT" "--listen=:$Z2K_TG_CDN_PORT"'
assert_contains "tg.sh: timeout 15m" "$TG" '"--timeout=$Z2K_TG_TIMEOUT"'
assert_contains "tg.sh: GODEBUG" "$TG" 'GODEBUG=asyncpreemptoff=1'
# второго сервиса нет
if [ -f "$REPO/package/openwrt/files/etc/init.d/z2k-tg" ]; then
    _t_bad "второй init-сервис z2k-tg существует (должен быть один owner)"
else
    _t_ok
fi
assert_not_contains "init: нет второго open_instance" "$INIT" 'procd_open_instance "z2k-tg-second"'

# --- nft: своя chains/sets, чужой таблицы не создаём ---
assert_not_contains "tg.sh: нет add table" "$_TGCODE" 'add table|create table'
assert_not_contains "tg.sh: нет второй таблицы z2k" "$_TGCODE" 'table inet z2k'
assert_contains "tg.sh: таблица runtime" "$TG" 'Z2K_TG_NFT_TABLE'
assert_contains "tg.sh: проверка таблицы до записей" "$TG" '_z2k_ow_tg_table_ok'
# ни одного ACCEPT/input-открытия: `accept` в коде — ТОЛЬКО scoped
# dnat-accept guard'а (уже проверен выше построчно); -j ACCEPT и голых
# accept-вердиктов вне guard'а быть не должно.
assert_not_contains "tg.sh: нет -j ACCEPT" "$_TGCODE" '\-j ACCEPT'
_tg_accepts="$(grep -n 'accept' "$_TGCODE" | grep -v 'ct status dnat accept' || true)"
if [ -z "$_tg_accepts" ]; then
    _t_ok
else
    _t_bad "tg.sh: accept вне scoped guard: [$_tg_accepts]"
fi
# v6 — reject, не redirect и не drop
assert_contains "tg.sh: v6 reject" "$TG" 'reject with tcp reset'
assert_not_contains "tg.sh: v6 не redirect" "$_TGCODE" 'ip6 daddr.*redirect'
# INPUT-guard: scoped accept (порты + dnat) строго до drop; blanket
# `ct status dnat accept` без портов обошёл бы fw4-input для чужого DNAT.
assert_contains "tg.sh: input chain" "$TG" 'type filter hook input priority -1'
assert_contains "tg.sh: guard accept scoped" "$TG" 'tcp dport "{ $Z2K_TG_PORT, $Z2K_TG_CDN_PORT }" ct status dnat accept'
assert_contains "tg.sh: guard drop" "$TG" 'tcp dport "{ $Z2K_TG_PORT, $Z2K_TG_CDN_PORT }" drop'
if grep -E 'add rule .* ct status dnat accept' "$_TGCODE" | grep -v 'tcp dport' >/dev/null 2>&1; then
    _t_bad "tg.sh: blanket ct-status accept без портов"
else
    _t_ok
fi

# --- секреты не печатаются ---
assert_not_contains "tg.sh: нет set -x" "$_TGCODE" 'set -x'
assert_not_contains "tg.sh: secret не в echo" "$_TGCODE" 'echo.*SECRET|echo.*tunnel-secret'
assert_not_contains "tg.sh: secret не в logger" "$_TGCODE" 'logger.*SECRET|logger.*secret='

# --- проводка: init / hotplug / schedule / uninstall / Makefile ---
assert_contains "init: tg.sh подключён" "$INIT" 'platform/openwrt/tg.sh'
assert_contains "init: старт зовёт tg 1" "$INIT" 'z2k_ow_tg 1'
assert_contains "init: стоп зовёт tg 0" "$INIT" 'z2k_ow_tg 0'
assert_contains "hotplug: TG reconverge" "$HOTPLUG" 'z2k_ow_tg rules'
assert_contains "schedule: tg-health строка" "$SCHED" 'z2k-tg-health'
assert_contains "schedule: tg-check entrypoint" "$SCHED" 'tg-check.sh check'
assert_contains "schedule: install/remove пара" "$SCHED" 'z2k_ow_tg_cron_install'
assert_contains "schedule: remove пара" "$SCHED" 'z2k_ow_tg_cron_remove'
assert_contains "uninstall: tg cleanup" "$UNINST" 'z2k_ow_tg cleanup'
assert_contains "uninstall: tg cron remove" "$UNINST" 'z2k_ow_tg_cron_remove'
assert_contains "Makefile: conntrack dep" "$MK" '+conntrack'
if grep -q 'iptables' "$MK"; then
    _t_bad "Makefile тянет iptables"
else
    _t_ok
fi
assert_contains "Makefile: postinst tg cron" "$MK" 'z2k_ow_tg_cron_install'
assert_contains "ownership: tg.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/tg.sh package'
assert_contains "ownership: tg-check.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/tg-check.sh package'

# --- COMMON_HOOK в au_service_for_binary ---
assert_contains "au: openwrt-ветка" "$AU" 'Z2K_PLATFORM:-keenetic}" = "openwrt"'
assert_contains "au: keenetic-ветка цела" "$AU" '/opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97z2k-http-tunnel'

_t_done
