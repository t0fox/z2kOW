#!/bin/sh
# platform/openwrt/tg.sh - Telegram/CDN tunnel glue (Stage 3).
#
# Upstream contract: docs/openwrt-telegram-contract.md. Один процесс
# tg-mtproxy-client владеет :1443 (Telegram) + :1444 (cdnbase); lifecycle —
# procd instance "z2k-tg" внутри сервиса z2k (второго init-сервиса нет);
# firewall — свои chains/sets в runtime-таблице (второй таблицы нет).
#
# Использование (требует выставленных paths/env):
#   z2k_ow_tg 1        - конвергенция: rules/sets + procd instance (если wanted)
#   z2k_ow_tg 0        - снять chains (sets оставить для быстрого рестарта)
#   z2k_ow_tg cleanup  - uninstall: снять chains И sets (не litter'ить таблицу)
#   z2k_ow_tg rules    - только rules/sets converge (hotplug, без демона)
#   z2k_ow_tg check    - health-check тик (cron): converge + probe + kill-only
#
# Секреты: argv собирается в позиционных параметрах, никогда не печатается
# (set -x и echo argv здесь запрещены — см. test_ow_tg_static.sh).

# --- константы upstream (single source of truth — files/z2k-tg-redirect.sh) ---
Z2K_TG_PORT="${Z2K_TG_PORT:-1443}"
Z2K_TG_CDN_PORT="${Z2K_TG_CDN_PORT:-1444}"
Z2K_TG_TIMEOUT="${Z2K_TG_TIMEOUT:-15m}"
Z2K_TG_CIDRS="${Z2K_TG_CIDRS:-149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24}"
Z2K_TG_CIDRS6="${Z2K_TG_CIDRS6:-2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280:203::/48}"
# p-85.8 UDP transport covers the complete announced 2a0a:f280::/32. Keep
# dedicated sets/routes so this UDP expansion does not change the existing
# TCP IPv6 reject set above.
Z2K_TG_UDP_CIDRS="${Z2K_TG_UDP_CIDRS:-$Z2K_TG_CIDRS}"
Z2K_TG_UDP_CIDRS6="${Z2K_TG_UDP_CIDRS6:-2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280::/32}"
Z2K_TG_CDN_CIDRS="${Z2K_TG_CDN_CIDRS:-168.119.95.238/32}"
Z2K_TG_PROBE_URL="${Z2K_TG_PROBE_URL:-https://core.telegram.org/}"
Z2K_TG_PROBE_RESOLVE_IP="${Z2K_TG_PROBE_RESOLVE_IP:-149.154.167.99}"

# --- nft-имена (свои sets/chains в ЧУЖОЙ runtime-таблице; таблицу не создаём) ---
# Дефолт таблицы = дефолт pinned zapret2 runtime (ZAPRET_NFT_TABLE=zapret2):
# свои chains в чужой таблице, второго фреймворка нет (Stage 8 live-дефект:
# дефолт zapret не совпадал с рантаймом — TG/RT/WARP валились fail-closed).
Z2K_TG_NFT_FAMILY="${Z2K_TG_NFT_FAMILY:-inet}"
Z2K_TG_NFT_TABLE="${Z2K_TG_NFT_TABLE:-zapret2}"
Z2K_TG_SET4="${Z2K_TG_SET4:-z2k_tg_dc4}"
Z2K_TG_SET6="${Z2K_TG_SET6:-z2k_tg_dc6}"
Z2K_TG_SETCDN="${Z2K_TG_SETCDN:-z2k_tg_cdn4}"
Z2K_TG_UDP_SET4="${Z2K_TG_UDP_SET4:-z2k_tg_udp_dc4}"
Z2K_TG_UDP_SET6="${Z2K_TG_UDP_SET6:-z2k_tg_udp_dc6}"
Z2K_TG_CHAIN_PRE="${Z2K_TG_CHAIN_PRE:-z2k_tg_dst_pre}"
Z2K_TG_CHAIN_OUT="${Z2K_TG_CHAIN_OUT:-z2k_tg_dst_out}"
Z2K_TG_CHAIN_FWD="${Z2K_TG_CHAIN_FWD:-z2k_tg_flt_fwd}"
Z2K_TG_CHAIN_OUTF="${Z2K_TG_CHAIN_OUTF:-z2k_tg_flt_out}"
# INPUT-guard против прямого WAN-доступа к wildcard-портам (см. ниже).
Z2K_TG_CHAIN_IN="${Z2K_TG_CHAIN_IN:-z2k_tg_flt_in}"

Z2K_TG_BIN="${Z2K_TG_BIN:-${Z2K_BIN:-/usr/lib/z2k/bin}/tg-mtproxy-client}"
Z2K_TG_PIDFILE="${Z2K_TG_PIDFILE:-${Z2K_RUN:-/tmp/z2k/runtime}/tg-tunnel.pid}"
Z2K_TG_HEALTH_DIR="${Z2K_TG_HEALTH_DIR:-${Z2K_TMP:-/tmp/z2k}/tg-health}"
# Корень /proc (тестам — фикстура; прод всегда настоящий /proc).
Z2K_PROC_ROOT="${Z2K_PROC_ROOT:-/proc}"

# Telegram server UDP is a separate authenticated WSS/TUN transport.  The
# OpenWrt boundary owns only these nft/PBR hooks; the Go client owns the TUN
# and the ready/withdraw lifecycle.  The table/mark are deliberately separate
# from WARP (989/0x80000000) and are rejected if another owner occupies them.
Z2K_TG_UDP_IF="${Z2K_TG_UDP_IF:-z2ktg0}"
Z2K_TG_UDP_MARK="${Z2K_TG_UDP_MARK:-0x08000000}"
Z2K_TG_UDP_TABLE="${Z2K_TG_UDP_TABLE:-988}"
Z2K_TG_UDP_PREF="${Z2K_TG_UDP_PREF:-89}"
# p-85.8's shipped mtproxy-client binary owns this fixed readiness ABI.  The
# adapter and watchdog consume the same marker; do not pass private CLI flags
# which are not present in the released binary.
Z2K_TG_UDP_READY="${Z2K_TG_UDP_READY:-/tmp/z2k-log/tg-udp.ready}"
Z2K_TG_UDP_LEGACY_SHELL="${Z2K_TG_UDP_LEGACY_SHELL:-/opt/bin/sh}"
Z2K_TG_UDP_LEGACY_SOURCE="${Z2K_TG_UDP_LEGACY_SOURCE:-${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/tg-udp-legacy-shell}"

# Чтение флага из $Z2K_CONFIG без сорсинга (cron/hotplug-контексты).
# $1 key, $2 default.
z2k_ow_tg_cfg() {
    local _v=""
    [ -f "${Z2K_CONFIG:-/etc/z2k/config}" ] && \
        _v=$(awk -F= -v k="$1" '$1==k {v=$2; gsub(/[" ]/,"",v)} END {print v}' \
            "${Z2K_CONFIG:-/etc/z2k/config}" 2>/dev/null)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

# wanted: бинарник +x, global ENABLED=1, user-disable != 1.
z2k_ow_tg_wanted() {
    [ -x "$Z2K_TG_BIN" ] || return 1
    [ "$(z2k_ow_tg_cfg ENABLED 1)" = "1" ] || return 1
    [ "$(z2k_ow_tg_cfg TG_PROXY_USER_DISABLED 0)" = "1" ] && return 1
    return 0
}

z2k_ow_tg_udp_wanted() {
    z2k_ow_tg_wanted || return 1
    [ "$(z2k_ow_tg_cfg Z2K_TG_UDP_RELAY 1)" = "1" ]
}

# Собрать argv демона и выполнить $1 как команду с этим argv.
# Секрет из конфига (override) или скомпилированный дефолт бинарника.
# Использование: z2k_ow_tg_with_argv _cb (ровно одно слово — см. ниже).
z2k_ow_tg_with_argv() {
    local _cb="$1" _rs _ru
    shift
    _rs=$(z2k_ow_tg_cfg Z2K_RELAY_SECRET "")
    _ru=$(z2k_ow_tg_cfg Z2K_RELAY_URL "")
    set -- "$Z2K_TG_BIN" "--listen=:$Z2K_TG_PORT" "--listen=:$Z2K_TG_CDN_PORT" \
           "--timeout=$Z2K_TG_TIMEOUT"
    [ -n "$_rs" ] && set -- "$@" "--tunnel-secret=$_rs"
    [ -n "$_ru" ] && set -- "$@" "--tunnel-url=$_ru"
    if z2k_ow_tg_udp_wanted; then
        set -- "$@" "--telegram-udp"
    fi
    "$_cb" "$@"
}

# procd-обёртка: двухсловный вызов через пробел нельзя передать как один
# колбэк, поэтому адаптерная функция (тесты стабят procd_set_param).
_z2k_ow_tg_procd_command() { procd_set_param command "$@"; }

# Убийство демона — через helper (тестам — переопределить; procd поднимет
# процесс заново сам). Прямой kill здесь — shell builtin, PATH-стабом
# в тестах не перехватить.
_z2k_ow_tg_kill() { kill "$@" 2>/dev/null || true; }

# PIDs нашего процесса (матч по --listen=:1443 в cmdline — бинарник общий).
z2k_ow_tg_pids() {
    local _p _cl
    for _p in $(pidof tg-mtproxy-client 2>/dev/null); do
        [ -r "$Z2K_PROC_ROOT/$_p/cmdline" ] || continue
        _cl=$(tr '\0' ' ' < "$Z2K_PROC_ROOT/$_p/cmdline" 2>/dev/null)
        case "$_cl" in
            *"--listen=:$Z2K_TG_PORT"*) printf '%s\n' "$_p" ;;
        esac
    done
    return 0
}

z2k_ow_tg_socket_listening() {
    local _port="$(printf '%04X' "$1" 2>/dev/null)"
    [ -n "$_port" ] || return 1
    awk -v p="$_port" '$2 ~ (":" p "$") && $4 == "0A" {ok=1} END {exit !ok}' \
        "$Z2K_PROC_ROOT/net/tcp" "$Z2K_PROC_ROOT/net/tcp6" 2>/dev/null
}

z2k_ow_tg_listeners_ready() {
    z2k_ow_tg_socket_listening "$Z2K_TG_PORT" && \
        z2k_ow_tg_socket_listening "$Z2K_TG_CDN_PORT"
}

z2k_ow_tg_running() { [ -n "$(z2k_ow_tg_pids)" ]; }

# --- nft ---

# Таблица обязана существовать (её создаёт zapret2 runtime через fw_apply).
_z2k_ow_tg_table_ok() {
    nft list table "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" >/dev/null 2>&1
}

_z2k_ow_tg_csv() {
    # $1 — space-список CIDR → "a, b, c" для add element {...}
    local _o="" _c
    for _c in $1; do
        [ -n "$_o" ] && _o="$_o, "
        _o="$_o$_c"
    done
    printf '%s' "$_o"
}

# Конвергенция sets+chains+rules. Идемпотентна (flush+add — дублей нет).
z2k_ow_tg_nft_apply() {
    _z2k_ow_tg_table_ok || {
        echo "z2k-openwrt: tg: нет таблицы $Z2K_TG_NFT_FAMILY $Z2K_TG_NFT_TABLE (сначала fw_apply)" >&2
        return 1
    }
    # sets (создать если нет, затем детерминированно перезалить)
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" \
        '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" \
        '{ type ipv6_addr; flags interval; }' 2>/dev/null || true
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SETCDN" \
        '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    nft flush set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" 2>/dev/null || true
    nft flush set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" 2>/dev/null || true
    nft flush set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SETCDN" 2>/dev/null || true
    nft add element "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" \
        "{ $(_z2k_ow_tg_csv "$Z2K_TG_CIDRS") }" || return 1
    nft add element "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" \
        "{ $(_z2k_ow_tg_csv "$Z2K_TG_CIDRS6") }" || return 1
    nft add element "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SETCDN" \
        "{ $(_z2k_ow_tg_csv "$Z2K_TG_CDN_CIDRS") }" || return 1
    # chains (свои base chains в чужой таблице).
    # Приоритеты — PLAIN INTEGERS (арифметика вида `dstnat - 1` здесь не
    # используется осознанно: её поддержка зависит от парсера, числа — нет):
    #   -101 = перед dstnat(-100): эквивалент legacy PREROUTING/OUTPUT insert;
    #   -1   = перед filter(0): эквивалент -I FORWARD/OUTPUT/INPUT.
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
        '{ type nat hook prerouting priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
        '{ type nat hook output priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_FWD" \
        '{ type filter hook forward priority -1; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUTF" \
        '{ type filter hook output priority -1; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        '{ type filter hook input priority -1; }' 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_FWD" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUTF" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" 2>/dev/null || true
    # Telegram IPv4 TCP/443 -> :1443 (forwarded + router-local)
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
        tcp dport 443 ip daddr "@$Z2K_TG_SET4" redirect to ":$Z2K_TG_PORT" || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
        tcp dport 443 ip daddr "@$Z2K_TG_SET4" redirect to ":$Z2K_TG_PORT" || return 1
    # cdnbase TCP/80 -> :1444, тот же процесс
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
        tcp dport 80 ip daddr "@$Z2K_TG_SETCDN" redirect to ":$Z2K_TG_CDN_PORT" || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
        tcp dport 80 ip daddr "@$Z2K_TG_SETCDN" redirect to ":$Z2K_TG_CDN_PORT" || return 1
    # Telegram IPv6: TCP обслуживаемых портов (80/443, как redirect'ы выше) ->
    # мгновенный icmpv6-reject, быстрый fallback клиента на tunneled IPv4.
    # НЕ redirect, НЕ drop. TCP RST невозможен для IPv6, bare `tcp` без портов
    # перед verdict парсер ядра тоже отвергает (Stage 8 live-дефект).
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_FWD" \
        ip6 daddr "@$Z2K_TG_SET6" tcp dport "{80, 443}" reject with icmpv6 type port-unreachable || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUTF" \
        ip6 daddr "@$Z2K_TG_SET6" tcp dport "{80, 443}" reject with icmpv6 type port-unreachable || return 1
    # INPUT-guard: демон слушает wildcard, прямой доступ с WAN к :1443/:1444
    # обязан не доходить до демона. REDIRECTнутые пакеты (LAN/router-local)
    # несут conntrack-статус dnat (ставится самим DNAT на весь conntrack) —
    # их пропускаем первыми; прямой трафик без статуса — drop. Порядок
    # КРИТИЧЕН (accept до drop). Scope строго наши порты: blanket
    # `ct status dnat accept` обошёл бы fw4-input для чужого DNAT-трафика.
    # LAN-direct на :1443 (self-dial) режется здесь же — defense in depth
    # к in-binary guard'у. Ни одного ACCEPT/input-открытия, только этот drop.
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        tcp dport "{ $Z2K_TG_PORT, $Z2K_TG_CDN_PORT }" ct status dnat accept || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        tcp dport "{ $Z2K_TG_PORT, $Z2K_TG_CDN_PORT }" drop || return 1
    return 0
}

# Снять chains (правила). Sets оставить (дешево, быстрый рестарт).
# $1: "full" — снять и sets (uninstall: не litter'ить чужую таблицу).
z2k_ow_tg_nft_remove() {
    local _full="${1:-}"
    _z2k_ow_tg_table_ok || return 0
    for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT" "$Z2K_TG_CHAIN_FWD" "$Z2K_TG_CHAIN_OUTF" "$Z2K_TG_CHAIN_IN"; do
        nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null || true
        nft delete chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null || true
    done
    if [ "$_full" = "full" ]; then
        for _s in "$Z2K_TG_SET4" "$Z2K_TG_SET6" "$Z2K_TG_SETCDN"; do
            nft delete set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_s" 2>/dev/null || true
        done
    fi
    return 0
}

# --- Telegram UDP-v1 OpenWrt boundary ---------------------------------------
#
# The upstream client writes an opaque IP packet to z2ktg0.  Only packets
# arriving from a configured LAN device, addressed to Telegram DC ranges and
# using UDP are marked into the private table.  Router-originated UDP, other
# destinations (including STUN/P2P/QUIC/game traffic), and packets with an
# existing policy mark retain their original routing owner.

z2k_ow_tg_udp_lan_ifaces() {
    local _raw _net _dev
    _raw="$(z2k_ow_tg_cfg Z2K_TG_LAN_IFACES "${OPENWRT_LAN:-lan}")"
    for _net in $_raw; do
        _dev="$_net"
        case "$_net" in
            br-*|eth*|wan*|wlan*|lan*) ;;
            *)
                if command -v uci >/dev/null 2>&1; then
                    _dev="$(uci -q get "network.$_net.device" 2>/dev/null)"
                fi
                [ -n "$_dev" ] || _dev="br-$_net"
                ;;
        esac
        printf '%s\n' "$_dev"
    done | awk 'NF && !seen[$0]++'
}

_z2k_ow_tg_udp_rule_exact() {
    local _fam="$1" _out
    _out="$(ip "$_fam" rule show 2>/dev/null | awk -v p="${Z2K_TG_UDP_PREF}:" -v m="$Z2K_TG_UDP_MARK" -v t="$Z2K_TG_UDP_TABLE" '
        $1 == p {
            fw=0; tab=0
            for (i=2; i<=NF; i++) {
                if ($i == "fwmark" && (($(i+1) == m) || ($(i+1) == m "/0xffffffff"))) fw=1
                if ($i == "lookup" && $(i+1) == t) tab=1
            }
            if (fw && tab) print
        }')"
    [ -n "$_out" ]
}

_z2k_ow_tg_udp_rule_conflict() {
    local _fam="$1" _out
    _out="$(ip "$_fam" rule show 2>/dev/null | awk -v p="${Z2K_TG_UDP_PREF}:" '$1 == p {print}')"
    [ -z "$_out" ] && return 1
    _z2k_ow_tg_udp_rule_exact "$_fam" && return 1
    printf '%s\n' "$_out"
    return 0
}

_z2k_ow_tg_udp_routes_up() {
    local _fam="$1" _cidrs _c _conflict
    _conflict="$(_z2k_ow_tg_udp_rule_conflict "$_fam")"
    [ -n "$_conflict" ] && {
        echo "z2k-openwrt: tg UDP PBR owner conflict at pref $Z2K_TG_UDP_PREF ($_conflict)" >&2
        return 1
    }
    case "$_fam" in
        -4) _cidrs="$Z2K_TG_UDP_CIDRS" ;;
        -6) _cidrs="$Z2K_TG_UDP_CIDRS6" ;;
        *) return 1 ;;
    esac
    # A throw default is mandatory: the table must not become a catch-all for
    # marks belonging to another service if a later rule is misconfigured.
    ip "$_fam" route replace throw default table "$Z2K_TG_UDP_TABLE" || return 1
    for _c in $_cidrs; do
        ip "$_fam" route replace "$_c" dev "$Z2K_TG_UDP_IF" table "$Z2K_TG_UDP_TABLE" || return 1
    done
    if ! _z2k_ow_tg_udp_rule_exact "$_fam"; then
        ip "$_fam" rule add pref "$Z2K_TG_UDP_PREF" fwmark "$Z2K_TG_UDP_MARK/0xffffffff" table "$Z2K_TG_UDP_TABLE" || return 1
    fi
    _z2k_ow_tg_udp_rule_exact "$_fam"
}

_z2k_ow_tg_udp_routes_down() {
    local _fam="$1" _cidrs _c
    case "$_fam" in
        -4) _cidrs="$Z2K_TG_UDP_CIDRS" ;;
        -6) _cidrs="$Z2K_TG_UDP_CIDRS6" ;;
        *) return 0 ;;
    esac
    while _z2k_ow_tg_udp_rule_exact "$_fam"; do
        ip "$_fam" rule del pref "$Z2K_TG_UDP_PREF" fwmark "$Z2K_TG_UDP_MARK/0xffffffff" table "$Z2K_TG_UDP_TABLE" 2>/dev/null || break
    done
    for _c in $_cidrs; do
        ip "$_fam" route del "$_c" dev "$Z2K_TG_UDP_IF" table "$Z2K_TG_UDP_TABLE" 2>/dev/null || true
    done
    ip "$_fam" route del throw default table "$Z2K_TG_UDP_TABLE" 2>/dev/null || true
}

z2k_ow_tg_udp_nft_remove() {
    local _failed=0 _spec _set _type _dump
    _z2k_ow_tg_table_ok || return 0
    _z2k_ow_tg_udp_nfqueue_remove
    for _c in z2k_tg_udp_mark z2k_tg_udp_fwd; do
        nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" >/dev/null 2>&1 || continue
        nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null || true
        nft delete chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null || true
    done
    while IFS='|' read -r _set _type; do
        [ -n "$_set" ] || continue
        _dump=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" 2>/dev/null) || continue
        if ! _z2k_ow_tg_udp_set_owned "$_dump" "$_type"; then
            echo "z2k-openwrt: tg UDP set owner conflict: $_set" >&2
            _failed=1
            continue
        fi
        nft delete set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" 2>/dev/null || _failed=1
    done <<EOF
$Z2K_TG_UDP_SET4|ipv4_addr
$Z2K_TG_UDP_SET6|ipv6_addr
EOF
    return "$_failed"
}

_z2k_ow_tg_udp_set_owned() {
    local _dump="$1" _type="$2"
    printf '%s\n' "$_dump" | grep -qF "type $_type" && \
        printf '%s\n' "$_dump" | grep -qF 'comment "z2k-openwrt: Telegram UDP"'
}

_z2k_ow_tg_udp_set_elements() {
    awk '
        /elements[[:space:]]*=/ {
            inside = 1
            sub(/^.*elements[[:space:]]*=[[:space:]]*[{]/, "")
        }
        inside {
            line = $0
            if (sub(/[}].*/, "", line)) { print line; exit }
            print line
        }
    ' | tr ', ' '\n\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' | LC_ALL=C sort -u
}

_z2k_ow_tg_udp_set_sync() {
    local _set="$1" _type="$2" _cidrs="$3" _dump _actual _expected _item _exists=0
    if _dump=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" 2>/dev/null); then
        _exists=1
        _z2k_ow_tg_udp_set_owned "$_dump" "$_type" || {
            echo "z2k-openwrt: tg UDP set owner conflict: $_set" >&2
            return 1
        }
    else
        nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" \
            "{ type $_type; flags interval; auto-merge; comment \"z2k-openwrt: Telegram UDP\"; }" || return 1
        _dump=""
    fi
    _actual=$(printf '%s\n' "$_dump" | _z2k_ow_tg_udp_set_elements)
    _expected=$(printf '%s\n' "$_cidrs" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
    [ "$_actual" = "$_expected" ] && return 0
    if [ "$_exists" = 1 ]; then
        nft flush set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" || return 1
    fi
    for _item in $_cidrs; do
        nft add element "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" "{ $_item }" || return 1
    done
    return 0
}

# zapret2's normal NFQUEUE hooks are runtime-owned chains. The OpenWrt
# adapter does not replace them; it installs exact return rules in those
# existing hooks while the authenticated UDP worker is ready. Only UDP to
# Telegram DC ranges (and replies from those ranges) skips NFQUEUE. Other UDP
# traffic, including STUN, QUIC, Discord and games, remains zapret2-owned.
_z2k_ow_tg_udp_nfqueue_rules() {
    printf '%s\n' \
        "postnat|ip daddr @$Z2K_TG_UDP_SET4 meta l4proto udp return" \
        "postnat|ip6 daddr @$Z2K_TG_UDP_SET6 meta l4proto udp return" \
        "prenat|ip saddr @$Z2K_TG_UDP_SET4 meta l4proto udp return" \
        "prenat|ip6 saddr @$Z2K_TG_UDP_SET6 meta l4proto udp return"
}

_z2k_ow_tg_udp_nfqueue_apply() {
    local _row _chain _rule _existing
    _z2k_ow_tg_table_ok || return 1
    while IFS='|' read -r _chain _rule; do
        [ -n "$_chain" ] || continue
        nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_chain" >/dev/null 2>&1 || return 1
        _existing=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_chain" 2>/dev/null || true)
        printf '%s\n' "$_existing" | tr -s ' ' | grep -qF "$_rule" && continue
        # Insert before the existing jump to zapret2's NFQUEUE chain; do not
        # replace that chain or alter its queue number.
        nft insert rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_chain" $_rule || return 1
    done <<EOF
$(_z2k_ow_tg_udp_nfqueue_rules)
EOF
    return 0
}

_z2k_ow_tg_udp_nfqueue_remove() {
    local _chain _rule _dump _handle
    _z2k_ow_tg_table_ok || return 0
    while IFS='|' read -r _chain _rule; do
        [ -n "$_chain" ] || continue
        _handle=present
        while [ -n "$_handle" ]; do
            _dump=$(nft -a list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_chain" 2>/dev/null || true)
            _handle=$(printf '%s\n' "$_dump" | tr -s ' ' | sed -n "s/.*$_rule.*# handle \\([0-9][0-9]*\\).*/\\1/p" | head -1)
            [ -n "$_handle" ] || break
            nft delete rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_chain" handle "$_handle" 2>/dev/null || break
        done
    done <<EOF
$(_z2k_ow_tg_udp_nfqueue_rules)
EOF
    return 0
}

z2k_ow_tg_udp_nft_apply() {
    local _if _lan _ifs _out
    _z2k_ow_tg_table_ok || return 1
    _ifs="$(z2k_ow_tg_udp_lan_ifaces)"
    [ -n "$_ifs" ] || { echo "z2k-openwrt: tg UDP: no LAN devices" >&2; return 1; }
    _z2k_ow_tg_udp_set_sync "$Z2K_TG_UDP_SET4" ipv4_addr "$Z2K_TG_UDP_CIDRS" || return 1
    _z2k_ow_tg_udp_set_sync "$Z2K_TG_UDP_SET6" ipv6_addr "$Z2K_TG_UDP_CIDRS6" || return 1
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_mark \
        '{ type filter hook prerouting priority -150; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd \
        '{ type filter hook forward priority -2; }' 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_mark || return 1
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd || return 1
    for _if in $_ifs; do
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_mark \
            iifname "$_if" meta l4proto udp ip daddr "@$Z2K_TG_UDP_SET4" meta mark == 0 meta mark set "$Z2K_TG_UDP_MARK" || return 1
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_mark \
            iifname "$_if" meta l4proto udp ip6 daddr "@$Z2K_TG_UDP_SET6" meta mark == 0 meta mark set "$Z2K_TG_UDP_MARK" || return 1
    done
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd \
        oifname "$Z2K_TG_UDP_IF" meta l4proto udp ip daddr "@$Z2K_TG_UDP_SET4" accept || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd \
        iifname "$Z2K_TG_UDP_IF" meta l4proto udp ip saddr "@$Z2K_TG_UDP_SET4" accept || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd \
        oifname "$Z2K_TG_UDP_IF" meta l4proto udp ip6 daddr "@$Z2K_TG_UDP_SET6" accept || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd \
        iifname "$Z2K_TG_UDP_IF" meta l4proto udp ip6 saddr "@$Z2K_TG_UDP_SET6" accept || return 1
    _z2k_ow_tg_udp_nfqueue_apply || return 1
    return 0
}

z2k_ow_tg_udp_up() {
    z2k_ow_tg_udp_wanted || { z2k_ow_tg_udp_down; return 0; }
    [ -f "$Z2K_TG_UDP_READY" ] || return 0
    ip link show "$Z2K_TG_UDP_IF" >/dev/null 2>&1 || return 1
    ip link set "$Z2K_TG_UDP_IF" mtu 1500 up || return 1
    [ ! -e "/proc/sys/net/ipv4/conf/$Z2K_TG_UDP_IF/rp_filter" ] || \
        echo 0 > "/proc/sys/net/ipv4/conf/$Z2K_TG_UDP_IF/rp_filter"
    _z2k_ow_tg_udp_routes_up -4 && _z2k_ow_tg_udp_routes_up -6 && \
        z2k_ow_tg_udp_nft_apply && return 0
    z2k_ow_tg_udp_down
    return 1
}

z2k_ow_tg_udp_down() {
    z2k_ow_tg_udp_nft_remove || true
    _z2k_ow_tg_udp_routes_down -4
    _z2k_ow_tg_udp_routes_down -6
    rm -f "$Z2K_TG_UDP_READY" 2>/dev/null || true
    return 0
}

z2k_ow_tg_udp_ready() {
    [ -f "$Z2K_TG_UDP_READY" ] || return 1
    _z2k_ow_tg_udp_rule_exact -4 && _z2k_ow_tg_udp_rule_exact -6 || return 1
    nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_mark >/dev/null 2>&1 || return 1
    nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" z2k_tg_udp_fwd >/dev/null 2>&1 || return 1
    _z2k_ow_tg_udp_nfqueue_apply
}

# Human/API state for the UDP leg. "ready" means that the authenticated
# worker published its marker and the adapter observed both PBR rules and both
# nft chains. It is deliberately not a traffic proof: counters and an actual
# Telegram call are a separate acceptance gate.
z2k_ow_tg_udp_state() {
    if [ "$(z2k_ow_tg_cfg Z2K_TG_UDP_RELAY 1)" != "1" ]; then
        printf 'disabled'
    elif z2k_ow_tg_udp_ready; then
        printf 'ready'
    elif [ -f "$Z2K_TG_UDP_READY" ]; then
        printf 'degraded'
    else
        printf 'starting'
    fi
}

# p-85.8 ships a secret-bearing client binary whose UDP route fallback is
# hard-coded to /opt/bin/sh. Newer source supports Z2K_TG_UDP_ROUTE_HELPER,
# but the installed artifact may predate that seam. Materialize the narrow
# compatibility shell only when the binary lacks the env-override string;
# never overwrite an existing path and remove only byte-identical owned files.
z2k_ow_tg_legacy_abi_install() {
    local _source="$Z2K_TG_UDP_LEGACY_SOURCE" _target="$Z2K_TG_UDP_LEGACY_SHELL"
    local _parent="${Z2K_TG_UDP_LEGACY_SHELL%/*}" _marker _tmp _made_parent=0
    [ -x "$_source" ] || {
        echo "z2k-openwrt: Telegram UDP legacy helper is missing" >&2
        return 1
    }
    if [ -e "$_target" ] || [ -L "$_target" ]; then
        if [ -f "$_target" ] && [ ! -L "$_target" ] && cmp -s "$_source" "$_target"; then
            return 0
        fi
        echo "z2k-openwrt: refusing to replace existing $_target" >&2
        return 1
    fi
    if [ -L "$_parent" ] || { [ -e "$_parent" ] && [ ! -d "$_parent" ]; }; then
        echo "z2k-openwrt: refusing non-directory Telegram legacy shell parent $_parent" >&2
        return 1
    fi
    if [ ! -d "$_parent" ]; then
        mkdir -p "$_parent" || return 1
        _made_parent=1
        _marker="$_parent/.z2k-tg-udp-legacy-shell-dir-owned"
        printf '%s\n' 'z2k-openwrt: created for Telegram UDP legacy ABI' > "$_marker" || {
            rmdir "$_parent" 2>/dev/null || true
            return 1
        }
    else
        _marker="$_parent/.z2k-tg-udp-legacy-shell-dir-owned"
    fi
    _tmp="$_parent/.z2k-tg-udp-legacy-shell.$$"
    # BusyBox on supported OpenWrt images does not necessarily include the
    # coreutils `install` applet. Copy to a private sibling, set its mode, then
    # publish with the no-clobber hard link below.
    if [ -e "$_tmp" ] || [ -L "$_tmp" ] || ! cp "$_source" "$_tmp" || ! chmod 0755 "$_tmp"; then
        rm -f "$_tmp"
        [ "$_made_parent" = 1 ] && { rm -f "$_marker"; rmdir "$_parent" 2>/dev/null || true; }
        return 1
    fi
    # Hard-link creation is atomic and fails rather than replacing a file that
    # appeared concurrently after the initial ownership check.
    if ln "$_tmp" "$_target" 2>/dev/null; then
        rm -f "$_tmp"
        return 0
    fi
    rm -f "$_tmp"
    if [ -f "$_target" ] && [ ! -L "$_target" ] && cmp -s "$_source" "$_target"; then
        return 0
    fi
    [ "$_made_parent" = 1 ] && { rm -f "$_marker"; rmdir "$_parent" 2>/dev/null || true; }
    echo "z2k-openwrt: Telegram legacy shell path was claimed concurrently" >&2
    return 1
}

z2k_ow_tg_legacy_abi_remove() {
    local _source="$Z2K_TG_UDP_LEGACY_SOURCE" _target="$Z2K_TG_UDP_LEGACY_SHELL"
    local _parent="${Z2K_TG_UDP_LEGACY_SHELL%/*}" _marker
    _marker="$_parent/.z2k-tg-udp-legacy-shell-dir-owned"
    if [ -e "$_target" ] || [ -L "$_target" ]; then
        if [ ! -f "$_target" ] || [ -L "$_target" ] || ! cmp -s "$_source" "$_target"; then
            echo "z2k-openwrt: preserving non-owned Telegram legacy shell $_target" >&2
            return 0
        fi
        rm -f "$_target" || return 1
    fi
    if [ -f "$_marker" ] && grep -Fxq 'z2k-openwrt: created for Telegram UDP legacy ABI' "$_marker"; then
        rm -f "$_marker"
        rmdir "$_parent" 2>/dev/null || true
    fi
    return 0
}

z2k_ow_tg_legacy_abi_prepare() {
    if grep -aFq 'Z2K_TG_UDP_ROUTE_HELPER' "$Z2K_TG_BIN" 2>/dev/null; then
        return 0
    fi
    z2k_ow_tg_legacy_abi_install
}

# Executed by the Go client's route helper. Keeping this as a separate
# executable seam makes the common UDP transport testable without a router and
# keeps all privileged OpenWrt operations in this adapter.
z2k_ow_tg_udp_route() {
    case "${1:-}" in
        ensure) z2k_ow_tg_udp_up ;;
        down) z2k_ow_tg_udp_down ;;
        *) echo "usage: tg udp-route {ensure|down}" >&2; return 2 ;;
    esac
}

# Только TG/CDN записи (CIDR целиком, как upstream). conntrack может
# отсутствовать — тогда best-effort пропуск (см. DEPENDS +conntrack).
z2k_ow_tg_conntrack_flush() {
    local _c
    for _c in $Z2K_TG_CIDRS $Z2K_TG_CDN_CIDRS; do
        conntrack -D -d "$_c" >/dev/null 2>&1 || true
    done
    return 0
}

# procd instance "z2k-tg". Вызывать ТОЛЬКО из start_service-контекста
# (procd_open_instance вне его — no-op/ошибка; guard ниже).
z2k_ow_tg_start_instance() {
    command -v procd_open_instance >/dev/null 2>&1 || {
        echo "z2k-openwrt: tg: нет procd-контекста (только из start_service)" >&2
        return 1
    }
    local _roots="${Z2K_TG_TLS_BUNDLE:-$Z2K_ROOT/etc/z2k-roots.pem}"
    local _ready_dir="${Z2K_TG_UDP_READY%/*}"
    [ "$_ready_dir" = "$Z2K_TG_UDP_READY" ] && _ready_dir=.
    mkdir -p "$_ready_dir" || {
        echo "z2k-openwrt: tg: не удалось создать каталог UDP readiness" >&2
        return 1
    }
    procd_open_instance "z2k-tg"
    z2k_ow_tg_with_argv _z2k_ow_tg_procd_command
    # procd serializes env as one JSON object; a subsequent env call replaces
    # that object rather than merging it. Build the complete environment once
    # so the OpenWrt route helper survives alongside TLS/runtime settings.
    set -- GODEBUG=asyncpreemptoff=1 \
        "Z2K_TG_UDP_ROUTE_HELPER=$Z2K_ROOT/platform/openwrt/tg-udp-route.sh"
    # TLS trust: наш bundle + системный store, каждый — только если существует.
    # SSL_CERT_FILE на отсутствующий файл опустошил бы пул Go (см. тест корней).
    [ -f "$_roots" ] && set -- "$@" "SSL_CERT_FILE=$_roots"
    [ -d /etc/ssl/certs ] && set -- "$@" SSL_CERT_DIR=/etc/ssl/certs
    procd_set_param env "$@"
    procd_set_param pidfile "$Z2K_TG_PIDFILE"
    # Respawn EXPLICIT bounded (НЕ голый `respawn` и НЕ retry=0):
    #   threshold 3600s — прожил дольше: счётчик сбрасывается, падения
    #     здорового демона рестартятся всегда (watchdog за process-dead
    #     НЕ конкурирует: мёртвый процесс — зона procd, см. check);
    #   timeout 5s — пауза перед рестартом;
    #   retry 5 — больше 5 падений подряд быстрее threshold: procd HALT'ит
    #     instance (instance.fail в logread, шторма нет) до ручного restart.
    #     Crash-loop = сломанный артефакт/конфиг (напр. нет секрета):
    #     вечный рестарт чинил бы ничего и churn'ил правила.
    #     Восстановление: /etc/init.d/z2k restart (или reboot/updater).
    # Доказательство: procd/service/instance.c (instance_exit: счётчик +
    # halt; instance_config_parse: дефолты C {3600,5,5} — мы фиксируем их
    # явно, чтобы контракт не зависел от дефолтов). Shell-supervisor запрещён.
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    return 0
}

# Топология start/stop (зовёт init.d/z2k; вне procd instance не открываем).
z2k_ow_tg() {
    case "${1:-}" in
        1)
            if ! z2k_ow_tg_wanted; then
                z2k_ow_tg_legacy_abi_remove || return 1
                return 0
            fi
            if z2k_ow_tg_udp_wanted; then
                z2k_ow_tg_legacy_abi_prepare || return 1
            else
                # The legacy entrypoint is needed only by the enabled UDP
                # client. A service restart after toggling UDP off removes
                # our exact runtime copy while preserving any foreign path.
                z2k_ow_tg_legacy_abi_remove || return 1
            fi
            z2k_ow_tg_nft_apply || return 1
            z2k_ow_tg_conntrack_flush
            z2k_ow_tg_start_instance || return 1
            ;;
        0)
            z2k_ow_tg_udp_down
            z2k_ow_tg_nft_remove
            ;;
        rules)
            # hotplug/firewall-reload: только правила, демон не трогаем.
            # Ready-gate (no resurrection после manual stop/failed start):
            # предикат из env.sh; при одиночном сорсинге в тестах его нет.
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            z2k_ow_tg_wanted || { z2k_ow_tg_udp_down; z2k_ow_tg_nft_remove; return 0; }
            z2k_ow_tg_nft_apply || return 1
            [ -f "$Z2K_TG_UDP_READY" ] && z2k_ow_tg_udp_up || true
            ;;
        cleanup)
            # uninstall: всё убрать, никогда не валить удаление.
            z2k_ow_tg_udp_down || true
            z2k_ow_tg_nft_remove full || true
            z2k_ow_tg_legacy_abi_remove || true
            return 0
            ;;
        check)
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            z2k_ow_tg_check
            ;;
        *)
            echo "usage: z2k_ow_tg {1|0|rules|cleanup|check}" >&2
            return 1
            ;;
    esac
    return 0
}

# z2k_ow_tg_verify — start-gate: wanted ⇒ процесс жив + ключевая chain на
# месте; не wanted (нет бинарника/выключено) ⇒ пропуск, а не провал.
z2k_ow_tg_verify() {
    z2k_ow_tg_wanted || return 0
    z2k_ow_tg_running || {
        echo "z2k-openwrt: tg_verify: демон не жив" >&2; return 1; }
    nft list chain "${Z2K_TG_NFT_FAMILY:-inet}" "${Z2K_TG_NFT_TABLE:-zapret2}" \
        "${Z2K_TG_CHAIN_PRE:-z2k_tg_dst_pre}" >/dev/null 2>&1 || {
        echo "z2k-openwrt: tg_verify: нет chain ${Z2K_TG_CHAIN_PRE:-z2k_tg_dst_pre}" >&2
        return 1; }
    return 0
}

# Read-only TG dataplane verifier.  It deliberately inspects the complete
# owned surface before deciding to repair it: a healthy tick must not call
# nft add/flush or conntrack at all.  The redirect flag is consumed by the
# caller so conntrack is flushed only when redirect/guard routing was actually
# repaired, never for a list-only drift.
z2k_ow_tg_nft_verify() {
    local _s _c _out _need
    Z2K_TG_NFT_DRIFT_REDIRECT=0
    _z2k_ow_tg_table_ok || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    for _s in "$Z2K_TG_SET4:$Z2K_TG_CIDRS" \
              "$Z2K_TG_SET6:$Z2K_TG_CIDRS6" \
              "$Z2K_TG_SETCDN:$Z2K_TG_CDN_CIDRS"; do
        _name=${_s%%:*}; _need=${_s#*:}
        _out=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_name" 2>/dev/null) || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        for _v in $_need; do
            printf '%s\n' "$_out" | grep -qF "${_v%/32}" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        done
    done
    for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT" \
              "$Z2K_TG_CHAIN_FWD" "$Z2K_TG_CHAIN_OUTF" "$Z2K_TG_CHAIN_IN"; do
        _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null) || {
            Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    done
    for _need in \
        "tcp dport 443 ip daddr @$Z2K_TG_SET4 redirect to :$Z2K_TG_PORT" \
        "tcp dport 80 ip daddr @$Z2K_TG_SETCDN redirect to :$Z2K_TG_CDN_PORT"; do
        for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT"; do
            _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null)
            printf '%s\n' "$_out" | tr -s ' ' | grep -qF "$_need" || {
                Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        done
    done
    for _c in "$Z2K_TG_CHAIN_FWD" "$Z2K_TG_CHAIN_OUTF"; do
        _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null)
        printf '%s\n' "$_out" | tr -s ' ' | grep -qF "ip6 daddr @$Z2K_TG_SET6 tcp dport" || {
            Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        printf '%s\n' "$_out" | grep -q 'reject with icmpv6.*port-unreachable' || {
            Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    done
    _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" 2>/dev/null)
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "tcp dport { $Z2K_TG_PORT, $Z2K_TG_CDN_PORT } ct status dnat accept" || {
        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "tcp dport { $Z2K_TG_PORT, $Z2K_TG_CDN_PORT } drop" || {
        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    return 0
}

# --- health check (cron, см. contract §8) ---

_z2k_ow_tg_probe() {
    if command -v curl >/dev/null 2>&1; then
        curl --connect-timeout 8 --max-time 15 -sf -o /dev/null \
            --resolve "core.telegram.org:443:$Z2K_TG_PROBE_RESOLVE_IP" \
            "$Z2K_TG_PROBE_URL" 2>/dev/null
        return $?
    fi
    # Деградация без curl: uclient-fetch без --resolve (DNS-зависимо).
    if command -v uclient-fetch >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 20 uclient-fetch -q -O /dev/null "$Z2K_TG_PROBE_URL" 2>/dev/null
        else
            uclient-fetch -q -O /dev/null "$Z2K_TG_PROBE_URL" 2>/dev/null
        fi
        return $?
    fi
    # Пробовать нечем — не считаем failure (converge выше всё равно идёт).
    return 0
}

# Backoff как у upstream: 1,2,4,8,16,30 мин. $1 restarts -> ожидание в минутах.
_z2k_ow_tg_backoff_min() {
    local _n="${1:-0}" _w=1 _i=1
    while [ "$_i" -lt "$_n" ] && [ "$_w" -lt 30 ]; do
        _w=$((_w * 2)); _i=$((_i + 1))
    done
    [ "$_w" -gt 30 ] && _w=30
    printf '%s' "$_w"
}

z2k_ow_tg_check() {
    local _fails_f="$Z2K_TG_HEALTH_DIR/fails" _kill_f="$Z2K_TG_HEALTH_DIR/kills"
    local _fails=0 _kills=0 _last=0 _now
    mkdir -p "$Z2K_TG_HEALTH_DIR" 2>/dev/null || return 0
    # disabled -> конвергенция к стоп, никогда не failure.
    if ! z2k_ow_tg_wanted; then
        z2k_ow_tg_nft_remove || true
        # Остатки процесса при выключенном флаге — добить (как watchdog).
        if z2k_ow_tg_running; then
            for _p in $(z2k_ow_tg_pids); do _z2k_ow_tg_kill "$_p"; done
        fi
        rm -f "$_fails_f" "$_kill_f" 2>/dev/null
        return 0
    fi
    # Сначала read-only probe.  Healthy state is a strict zero-mutation path.
    # Repair only owned TG state; conntrack is flushed only when redirect/
    # guard routing itself was missing and had to be rebuilt.
    if ! z2k_ow_tg_nft_verify 2>/dev/null; then
        if z2k_ow_tg_nft_apply 2>/dev/null && [ "${Z2K_TG_NFT_DRIFT_REDIRECT:-1}" = "1" ]; then
            z2k_ow_tg_conntrack_flush
        fi
        z2k_ow_tg_nft_verify >/dev/null 2>&1 || return 0
    fi
    # The UDP worker owns readiness; this is a bounded route/nft convergence
    # pass only. It never starts a process and never recreates a missing ready
    # marker, so a dead/disconnected worker cannot leave a live PBR route.
    if [ -f "$Z2K_TG_UDP_READY" ]; then
        z2k_ow_tg_udp_up || logger -t z2k-tg "UDP route convergence failed" 2>/dev/null || true
    else
        z2k_ow_tg_udp_down
    fi
    # procd поднимет упавший сам; убиваем только ЗАВИСШИЙ живой (probe).
    if ! z2k_ow_tg_running; then
        rm -f "$_fails_f" 2>/dev/null
        return 0
    fi
    if _z2k_ow_tg_probe; then
        rm -f "$_fails_f" "$_kill_f" 2>/dev/null
        return 0
    fi
    [ -f "$_fails_f" ] && _fails=$(head -1 "$_fails_f" 2>/dev/null)
    case "$_fails" in ''|*[!0-9]*) _fails=0 ;; esac
    _fails=$((_fails + 1))
    printf '%s\n' "$_fails" > "$_fails_f" 2>/dev/null
    [ "$_fails" -lt 3 ] && return 0
    [ -f "$_kill_f" ] && {
        _kills=$(awk 'NR==1{print $1+0}' "$_kill_f" 2>/dev/null)
        _last=$(awk 'NR==1{print $2+0}' "$_kill_f" 2>/dev/null)
    }
    case "$_kills" in ''|*[!0-9]*) _kills=0 ;; esac
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    _now=$(date +%s 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    if [ "$((_now - _last))" -lt "$(_z2k_ow_tg_backoff_min "$_kills" | awk '{print $1*60}')" ]; then
        return 0
    fi
    # Kill-only: procd respawn'ит; правила НЕ churn'им (дешевле upstream).
    for _p in $(z2k_ow_tg_pids); do _z2k_ow_tg_kill "$_p"; done
    _kills=$((_kills + 1))
    printf '%s %s\n' "$_kills" "$_now" > "$_kill_f" 2>/dev/null
    logger -t z2k-tg "health probe failed ${_fails}x, daemon killed (procd respawns, backoff #${_kills})" 2>/dev/null || true
    return 0
}
