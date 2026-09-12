#!/bin/sh
# tests/openwrt/test_ow_rt_static.sh - Stage 4 Layer A: статика RT glue.
# Никакого Keenetic-стека, shell-supervisor'а, второй таблицы;
# ровно 5 active + 2 legacy; один procd instance; ownership disjoint.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-rt-static"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$REPO/platform/openwrt/rt.sh"
RTP="$REPO/platform/openwrt/rt-proc.sh"
RTC="$REPO/platform/openwrt/rt-check.sh"
INIT="$REPO/package/openwrt/files/etc/init.d/z2k"
HOTPLUG="$REPO/package/openwrt/files/etc/hotplug.d/iface/90-z2k"
SCHED="$REPO/platform/openwrt/schedule.sh"
UNINST="$REPO/platform/openwrt/uninstall.sh"
MAP="$REPO/package/openwrt/ownership.map"
AU="$REPO/lib/auto_update.sh"
S96="$REPO/files/init.d/S96z2k-rt-proxy"

assert_file "rt.sh существует" "$RT"
assert_file "rt-proc.sh существует" "$RTP"
assert_file "rt-check.sh существует" "$RTC"

# Код без комментариев для запретов.
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rts.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
_RTCODE="$T/rt.code"; _RTPCODE="$T/rtp.code"; _RTCCODE="$T/rtc.code"
sed 's/#.*$//' "$RT" > "$_RTCODE"
sed 's/#.*$//' "$RTP" > "$_RTPCODE"
sed 's/#.*$//' "$RTC" > "$_RTCCODE"

# --- нет Keenetic-стека в glue (литерал разорван: сам гард forbidden
# сканирует и этот файл, исключая только себя) ---
for _f in "$_RTCODE" "$_RTPCODE" "$_RTCCODE"; do
    assert_not_contains "glue: нет keenetic-dns" "$_f" 'n'"dmc"
    assert_not_contains "glue: нет iptables" "$_f" 'iptables'
    assert_not_contains "glue: нет ipset" "$_f" 'ipset'
    assert_not_contains "glue: нет hw-offload-target" "$_f" 'PP'"E"
    assert_not_contains "glue: нет /opt" "$_f" '/opt'
done

# --- нет shell-supervisor'а ---
for _pat in 'while :' '(^|[^_A-Za-z0-9])PIDFILE=' 'sleep \$backoff'; do
    assert_not_contains "rt.sh: нет supervisor-признака ($_pat)" "$_RTCODE" "$_pat"
done
assert_contains "rt.sh: respawn bounded exact" "$RT" 'procd_set_param respawn 3600 5 5'
if grep -qE 'procd_set_param respawn[[:space:]]*$' "$RT"; then
    _t_bad "rt.sh: голый respawn без explicit параметров"
else
    _t_ok
fi
assert_contains "rt.sh: GODEBUG" "$RT" 'GODEBUG=asyncpreemptoff=1'

# --- один procd instance z2k-rt, второго сервиса нет ---
assert_contains "rt.sh: instance z2k-rt" "$RT" 'procd_open_instance "z2k-rt"'
assert_eq "procd_open_instance в коде один" "1" "$(grep -c 'procd_open_instance "z2k-rt"' "$_RTCODE")"
if [ -f "$REPO/package/openwrt/files/etc/init.d/z2k-rt" ]; then
    _t_bad "второй init-сервис z2k-rt существует"
else
    _t_ok
fi

# --- домены: ровно 5 active + 2 legacy, совпадают с S96 ---
# (значения в ${VAR:-...} форме — режем по :-, не по кавычкам)
_up_active="$(sed -n 's/^DOMAINS="\([^"]*\)".*/\1/p' "$S96" | head -1 | tr ' ' '\n' | sort | tr '\n' ' ')"
_rt_active="$(sed -n 's/^Z2K_RT_DOMAINS="[^"]*:-\(.*\)}"$/\1/p' "$RT" | head -1 | tr ' ' '\n' | sort | tr '\n' ' ')"
_up_legacy="$(sed -n 's/^DOMAINS_LEGACY="\([^"]*\)".*/\1/p' "$S96" | head -1 | tr ' ' '\n' | sort | tr '\n' ' ')"
_rt_legacy="$(sed -n 's/^Z2K_RT_DOMAINS_LEGACY="[^"]*:-\(.*\)}"$/\1/p' "$RT" | head -1 | tr ' ' '\n' | sort | tr '\n' ' ')"
assert_eq "active == S96 five" "$_up_active" "$_rt_active"
assert_eq "legacy == S96 two" "$_up_legacy" "$_rt_legacy"
assert_eq "active ровно 5" "5" "$(printf '%s' "$_rt_active" | wc -w | tr -d ' ')"
# legacy не в active
for _d in $_rt_legacy; do
    case " $_rt_active" in
        *" $_d "*) _t_bad "legacy $_d в active" ;;
        *) _t_ok ;;
    esac
done
assert_contains "rt.sh: sentinel" "$RT" 'Z2K_RT_SENTINEL="${Z2K_RT_SENTINEL:-10.171.171.171}"'
# IPv6 sentinel: documentation prefix (не ULA/loopback/discard), rationale рядом
assert_contains "rt.sh: v6 sentinel" "$RT" 'Z2K_RT_SENTINEL6="${Z2K_RT_SENTINEL6:-2001:db8::1:1445}"'
assert_contains "rt.sh: v6 rationale (RFC 3849)" "$RT" 'RFC 3849'
assert_contains "rt.sh: dual option ip" "$RT" 'Z2K_RT_SECTION_IP'
# A-only assumption запрещена: verify обязан проверять ОБА family
assert_contains "rt.sh: verify v6-sentinel" "$RT" 'Z2K_RT_SENTINEL6'
if grep -q 'AAAA ушёл upstream' "$RT"; then _t_ok; else _t_bad "rt.sh: нет AAAA-leak диагностики"; fi

# --- argv: точная команда upstream, без дублирования дефолтов ---
assert_contains "rt.sh: argv listen+timeout" "$RT" '"$Z2K_RT_BIN" "--listen=:$Z2K_RT_PORT" "--timeout=$Z2K_RT_TIMEOUT"'
assert_not_contains "rt.sh: нет proxy-host в shell" "$_RTCODE" 'proxy-host|blockme'
assert_not_contains "rt.sh: нет resolver в shell" "$_RTCODE" 'resolver.*1\.1\.1\.1'

# --- nft: свои chains, чужой таблицы не создаём, нет flowtable ---
assert_not_contains "rt.sh: нет add table" "$_RTCODE" 'add table|create table'
assert_not_contains "rt.sh: нет flowtable" "$_RTCODE" 'flowtable|flow add|FLOWOFFLOAD'
assert_contains "rt.sh: таблица runtime" "$RT" 'Z2K_RT_NFT_TABLE'
assert_contains "rt.sh: проверка таблицы" "$RT" '_z2k_ow_rt_table_ok'
assert_contains "rt.sh: redirect pre" "$RT" 'redirect to ":$Z2K_RT_PORT"'
assert_not_contains "rt.sh: нет ACCEPT" "$_RTCODE" '\-j ACCEPT'
_tg_accepts="$(grep -n 'accept' "$_RTCODE" | grep -v 'ct status dnat accept' || true)"
[ -z "$_tg_accepts" ] && _t_ok || _t_bad "rt.sh: accept вне scoped guard: [$_tg_accepts]"
# stop_proxy/stop разделение: proc-bounce не трогает DNS/nft
assert_not_contains "proc-bounce: нет dns_remove" \
    "$(sed -n '/^z2k_ow_rt()/,/^}/p' "$RT" | sed -n '/proc-bounce/,/;;/p')" 'dns_remove|nft_remove'

# --- проводка: init / hotplug / schedule / uninstall ---
assert_contains "init: rt.sh подключён" "$INIT" 'platform/openwrt/rt.sh'
assert_contains "init: старт зовёт rt 1" "$INIT" 'z2k_ow_rt 1'
assert_contains "init: стоп зовёт rt 0" "$INIT" 'z2k_ow_rt 0'
assert_contains "hotplug: RT reconverge" "$HOTPLUG" 'z2k_ow_rt rules'
assert_contains "schedule: rt-health строка" "$SCHED" 'z2k-rt-health'
assert_contains "schedule: rt-check entrypoint" "$SCHED" 'rt-check.sh check'
assert_contains "schedule: install пара" "$SCHED" 'z2k_ow_rt_cron_install'
assert_contains "schedule: remove пара" "$SCHED" 'z2k_ow_rt_cron_remove'
assert_contains "uninstall: rt cleanup" "$UNINST" 'z2k_ow_rt cleanup'
assert_contains "uninstall: rt cron remove" "$UNINST" 'z2k_ow_rt_cron_remove'
assert_contains "ownership: rt.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/rt.sh package'
assert_contains "ownership: rt-proc.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/rt-proc.sh package'
assert_contains "ownership: rt-check.sh package" "$MAP" '/usr/lib/z2k/platform/openwrt/rt-check.sh package'

# --- COMMON_HOOK в au_service_for_binary ---
assert_contains "au: rt openwrt-ветка" "$AU" 'rt-proc.sh'
assert_contains "au: keenetic S96 цел" "$AU" '/opt/etc/init.d/S96z2k-rt-proxy'

# --- desync-исключение читает генератор штатно (wl_excl) ---
assert_contains "generator: wl_excl" "$REPO/lib/config_official.sh" 'hostlist-exclude=${lists_dir}/whitelist.txt'

# --- env.sh: platform identity (Stage 4 root-cause fix) ---
assert_contains "env: Z2K_PLATFORM" "$REPO/platform/openwrt/env.sh" 'Z2K_PLATFORM="${Z2K_PLATFORM:-openwrt}"'

_t_done
