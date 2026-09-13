#!/bin/sh
# platform/openwrt/rt.sh - RuTracker proxy glue (Stage 4).
#
# Upstream contract: docs/openwrt-rt-proxy-contract.md. Exact-5 DNS pins
# (UCI hostrecord) -> sentinel 10.171.171.171 -> nft REDIRECT :1445 ->
# z2k-rt-proxy под procd (instance "z2k-rt"). Без shell-supervisor,
# без Keenetic-специфики, без второй таблицы.
#
# Использование (требует выставленных paths/env):
#   z2k_ow_rt 1            - конвергенция: DNS + whitelist + nft + instance
#   z2k_ow_rt 0            - full stop: процесс (через procd) + nft + DNS
#   z2k_ow_rt rules        - hotplug: nft + whitelist converge (+DNS verify
#                            без commit), демон не трогаем
#   z2k_ow_rt proc-bounce  - ТОЛЬКО kill процесса (restart/refresh; DNS/rules целы)
#   z2k_ow_rt cleanup      - uninstall: всё снять (DNS ours + nft), never fail
#   z2k_ow_rt check        - health-cron: converge + teardown при стойкой смерти
#
# Разделение stop_proxy/stop (upstream S96): proc-bounce vs 0. Рестарт демона
# НИКОГДА не снимает DNS (иначе клиент кеширует реальный IP).
# Mutation log (§31 спеки): строки DNS_CREATED:/NFT_CREATED:/... на stdout
# (тихо при Z2K_RT_QUIET=1 — cron-тики); диагностика — в stderr.

# --- константы upstream (S96: DOMAINS/DOMAINS_LEGACY/SENTINEL/PORT) ---
Z2K_RT_PORT="${Z2K_RT_PORT:-1445}"
Z2K_RT_TIMEOUT="${Z2K_RT_TIMEOUT:-15m}"
Z2K_RT_SENTINEL="${Z2K_RT_SENTINEL:-10.171.171.171}"
# IPv6 sentinel (dual-stack exact hostrecord, см. §5 contract):
# 2001:db8::/32 — RFC 3849 documentation (гарантированно не реален);
# НЕ ULA (OpenWrt LAN живёт в случайном fd00::/8 — коллизия), НЕ ::1
# (бил бы в localhost КЛИЕНТА), НЕ discard 100::/64 (чужая silent-drop
# семантика — наш механизм это nft reject ниже). Суффикс :1:1445 привязывает
# адрес к feature-порту. Пакеты сюда при converged-правилах роутер не
# покидают (их режет reject); без правил — см. live-риск в contract.
Z2K_RT_SENTINEL6="${Z2K_RT_SENTINEL6:-2001:db8::1:1445}"
# Полное содержимое option ip наших секций (dnsmasq --host-record=name,v4,v6;
# generator UCI (dhcp_hostrecord_add) склеивает space-список name+ip
# в одну запись — проверено чтением dnsmasq.init, не предположением).
Z2K_RT_SECTION_IP="${Z2K_RT_SECTION_IP:-$Z2K_RT_SENTINEL $Z2K_RT_SENTINEL6}"
Z2K_RT_DOMAINS="${Z2K_RT_DOMAINS:-rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc}"
Z2K_RT_DOMAINS_LEGACY="${Z2K_RT_DOMAINS_LEGACY:-www.rutracker.org rutracker.cc}"

# --- nft (свои chains в ЧУЖОЙ runtime-таблице; таблицу не создаём) ---
# Дефолт таблицы — как у TG (см. tg.sh): дефолт pinned runtime.
Z2K_RT_NFT_FAMILY="${Z2K_RT_NFT_FAMILY:-inet}"
Z2K_RT_NFT_TABLE="${Z2K_RT_NFT_TABLE:-zapret2}"
Z2K_RT_CHAIN_PRE="${Z2K_RT_CHAIN_PRE:-z2k_rt_dst_pre}"
Z2K_RT_CHAIN_OUT="${Z2K_RT_CHAIN_OUT:-z2k_rt_dst_out}"
Z2K_RT_CHAIN_IN="${Z2K_RT_CHAIN_IN:-z2k_rt_flt_in}"
# IPv6 fast-reject sentinel (A-only hostrecord НЕ подавляет AAAA-forwarding
# в dnsmasq 2.93 — доказанный баг; dual-record + reject вместо timeout).
Z2K_RT_CHAIN_FWD6="${Z2K_RT_CHAIN_FWD6:-z2k_rt_flt6_fwd}"
Z2K_RT_CHAIN_OUT6="${Z2K_RT_CHAIN_OUT6:-z2k_rt_flt6_out}"

Z2K_RT_BIN="${Z2K_RT_BIN:-${Z2K_BIN:-/usr/lib/z2k/bin}/z2k-rt-proxy}"
Z2K_RT_PIDFILE="${Z2K_RT_PIDFILE:-${Z2K_RUN:-/tmp/z2k/runtime}/rt-proxy.pid}"
Z2K_RT_HEALTH_DIR="${Z2K_RT_HEALTH_DIR:-${Z2K_TMP:-/tmp/z2k}/rt-health}"
Z2K_RT_HALT_LATCH="${Z2K_RT_HALT_LATCH:-${Z2K_TMP:-/tmp/z2k}/rt-health/halted}"
Z2K_PROC_ROOT="${Z2K_PROC_ROOT:-/proc}"
Z2K_DNSMASQ_INIT="${Z2K_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"

# Чтение флага из $Z2K_CONFIG без сорсинга. $1 key, $2 default.
z2k_ow_rt_cfg() {
    local _v=""
    [ -f "${Z2K_CONFIG:-/etc/z2k/config}" ] && \
        _v=$(awk -F= -v k="$1" '$1==k {v=$2; gsub(/[" ]/,"",v)} END {print v}' \
            "${Z2K_CONFIG:-/etc/z2k/config}" 2>/dev/null)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

# wanted: бинарник +x и global ENABLED=1. Отдельного user-флага нет
# (upstream: autostart-компонент). Нет бинарника -> нет DNS/правил.
z2k_ow_rt_wanted() {
    [ -x "$Z2K_RT_BIN" ] || return 1
    [ "$(z2k_ow_rt_cfg ENABLED 1)" = "1" ] || return 1
    return 0
}

_z2k_ow_rt_mut() { [ -n "$Z2K_RT_QUIET" ] || printf '%s\n' "$1"; }

# Убийство — через helper (тестам — переопределить; procd поднимает сам).
_z2k_ow_rt_kill() { kill "$@" 2>/dev/null || true; }

# Собрать argv и выполнить $1 как команду (ровно одно слово-колбэк).
z2k_ow_rt_with_argv() {
    local _cb="$1"
    shift
    set -- "$Z2K_RT_BIN" "--listen=:$Z2K_RT_PORT" "--timeout=$Z2K_RT_TIMEOUT"
    "$_cb" "$@"
}
_z2k_ow_rt_procd_command() { procd_set_param command "$@"; }

# PIDs нашего процесса (матч по --listen=:1445 — бинарник уникален для RT).
z2k_ow_rt_pids() {
    local _p _cl
    for _p in $(pidof z2k-rt-proxy 2>/dev/null); do
        [ -r "$Z2K_PROC_ROOT/$_p/cmdline" ] || continue
        _cl=$(tr '\0' ' ' < "$Z2K_PROC_ROOT/$_p/cmdline" 2>/dev/null)
        case "$_cl" in
            *"--listen=:$Z2K_RT_PORT"*) printf '%s\n' "$_p" ;;
        esac
    done
    return 0
}

z2k_ow_rt_running() { [ -n "$(z2k_ow_rt_pids)" ]; }

# --- DNS (UCI hostrecord) ---

# Домен -> суффикс OUR-секции: api.rutracker.cc -> api_rutracker_cc.
_z2k_ow_rt_sec() {
    printf 'z2k_rt_%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_')"
}

# Число dnsmasq-инстансов в dhcp (должна быть ровно 1, иначе явный отказ).
_z2k_ow_rt_dns_instances() {
    uci show dhcp 2>/dev/null | grep -oE '^dhcp\.@dnsmasq\[[0-9]+\]=dnsmasq$' \
        | sort -u | wc -l | tr -d ' '
}

# Дамп hostrecord-секций: "section|name|ip" (имя lower, без кавычек).
# Только show+get (минимум UCI-поверхности для моков): секции перечисляем
# по `=hostrecord$`, значения читаем точечно.
_z2k_ow_rt_dns_dump() {
    local _s _n _i
    for _s in $(uci show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([A-Za-z0-9_][A-Za-z0-9_]*\)=hostrecord$/\1/p'); do
        _n=$(uci -q get "dhcp.$_s.name" 2>/dev/null || printf '')
        _i=$(uci -q get "dhcp.$_s.ip" 2>/dev/null || printf '')
        printf '%s|%s|%s\n' "$_s" "$(printf '%s' "$_n" | tr 'A-Z' 'a-z')" "$_i"
    done
    return 0
}

_z2k_ow_rt_dns_reload() {
    [ -x "$Z2K_DNSMASQ_INIT" ] || {
        echo "z2k-openwrt: rt: нет $Z2K_DNSMASQ_INIT" >&2; return 1
    }
    "$Z2K_DNSMASQ_INIT" reload >/dev/null 2>&1 || return 1
    return 0
}

_z2k_ow_rt_dns_verify() {
    # UCI-readback (авторитетно для intent) + best-effort живой DNS.
    # Проверяем ОБА family: A-only hostrecord в dnsmasq 2.93 НЕ подавляет
    # AAAA-forwarding upstream (доказанный баг) — молчание здесь = bypass.
    local _d _sec _dump _ok=1 _out
    _dump="$(_z2k_ow_rt_dns_dump)"
    for _d in $Z2K_RT_DOMAINS; do
        _sec="$(_z2k_ow_rt_sec "$_d")"
        printf '%s\n' "$_dump" | grep -qxF "$_sec|$_d|$Z2K_RT_SECTION_IP" || _ok=0
    done
    [ "$_ok" = "1" ] || return 1
    if command -v nslookup >/dev/null 2>&1; then
        for _d in $Z2K_RT_DOMAINS; do
            _out=$(nslookup "$_d" 127.0.0.1 2>/dev/null) || {
                echo "z2k-openwrt: rt: DNS не отвечает для $_d" >&2
                return 1
            }
            printf '%s\n' "$_out" | grep -qF "$Z2K_RT_SENTINEL" || {
                echo "z2k-openwrt: rt: DNS не отдаёт v4-sentinel для $_d" >&2
                return 1
            }
            printf '%s\n' "$_out" | grep -qF "$Z2K_RT_SENTINEL6" || {
                echo "z2k-openwrt: rt: DNS не отдаёт v6-sentinel для $_d (AAAA ушёл upstream?)" >&2
                return 1
            }
        done
    fi
    return 0
}

# Применить DNS-пины транзакцией. Возврат 0 = все 5 стоят и проверены.
z2k_ow_rt_dns_apply() {
    local _n _d _sec _dump _stage=0 _ls _ln _li
    _n="$(_z2k_ow_rt_dns_instances)"
    [ "$_n" = "1" ] || {
        echo "z2k-openwrt: rt: dnsmasq-инстансов в dhcp: $_n (нужен ровно 1)" >&2
        return 1
    }
    _dump="$(_z2k_ow_rt_dns_dump)"
    # Конфликты: ЧУЖАЯ секция с тем же именем — fail loudly, СРАЗУ ОБА
    # family (чужой A-only pin + наш dual = неопределённый микс).
    # Своя секция с неверным содержимым (pre-dual эпоха) — НЕ конфликт,
    # лечится stage-fix ниже. Проверяем КАЖДУЮ строку: foreign-дубликат
    # рядом с корректной ours не должен проскакивать.
    for _d in $Z2K_RT_DOMAINS; do
        _sec="$(_z2k_ow_rt_sec "$_d")"
        while IFS='|' read -r _ls _ln _li; do
            [ -n "$_ls" ] || continue
            [ "$(printf '%s' "$_ln" | tr 'A-Z' 'a-z')" = "$_d" ] || continue
            if [ "$_ls" = "$_sec" ]; then
                [ "$_ln|$_li" = "$_d|$Z2K_RT_SECTION_IP" ] && \
                    _z2k_ow_rt_mut "DNS_PRESERVED: $_d"
            else
                echo "z2k-openwrt: rt: конфликт DNS: $_ls|$_ln|$_li (наша секция $_sec) — уберите чужую запись, не перезаписываю" >&2
                return 1
            fi
        done <<EOF_DUMP
$_dump
EOF_DUMP
    done
    # Stage наших отсутствующих/устаревших (v4-only эпохи): пишем dual целиком.
    for _d in $Z2K_RT_DOMAINS; do
        _sec="$(_z2k_ow_rt_sec "$_d")"
        if printf '%s\n' "$_dump" | grep -qxF "$_sec|$_d|$Z2K_RT_SECTION_IP"; then
            continue
        fi
        uci set "dhcp.$_sec=hostrecord" >/dev/null 2>&1 || return 1
        uci set "dhcp.$_sec.name=$_d" >/dev/null 2>&1 || return 1
        uci set "dhcp.$_sec.ip=$Z2K_RT_SECTION_IP" >/dev/null 2>&1 || return 1
        _stage=1
        _z2k_ow_rt_mut "DNS_CREATED: $_d"
    done
    # Legacy + будущие ours вне active: удалить (только z2k_rt_* namespace).
    for _sec in $(printf '%s\n' "$_dump" | awk -F'|' '$1 ~ /^z2k_rt_/ {print $1}' | sort -u); do
        _sec_domain=""
        for _d in $Z2K_RT_DOMAINS; do
            [ "$_sec" = "$(_z2k_ow_rt_sec "$_d")" ] && _sec_domain="$_d"
        done
        [ -n "$_sec_domain" ] && continue
        uci delete "dhcp.$_sec" >/dev/null 2>&1 || return 1
        _stage=1
        _z2k_ow_rt_mut "DNS_REMOVED: $_sec (legacy/stale)"
    done
    if [ "$_stage" = "0" ]; then
        return 0
    fi
    uci commit dhcp >/dev/null 2>&1 || {
        echo "z2k-openwrt: rt: uci commit dhcp провален" >&2; return 1
    }
    # reload недостаточен или упал — один restart, затем re-verify.
    # (Достаточность reload доказывается runtime, не догмой: verify —
    # ground truth, restart — эскалация.)
    if _z2k_ow_rt_dns_reload 2>/dev/null; then
        _z2k_ow_rt_dns_verify && return 0
    else
        echo "z2k-openwrt: rt: dnsmasq reload провален, пробую restart" >&2
    fi
    "$Z2K_DNSMASQ_INIT" restart >/dev/null 2>&1 || {
        echo "z2k-openwrt: rt: dnsmasq restart провален" >&2; return 1
    }
    _z2k_ow_rt_dns_verify || {
        echo "z2k-openwrt: rt: DNS не сошёлся даже после restart" >&2
        return 1
    }
    return 0
}

# Снять ТОЛЬКО наши секции (active+legacy+stale ours). Чужие — никогда.
z2k_ow_rt_dns_remove() {
    local _dump _sec _n=0
    _dump="$(_z2k_ow_rt_dns_dump)"
    for _sec in $(printf '%s\n' "$_dump" | awk -F'|' '$1 ~ /^z2k_rt_/ {print $1}' | sort -u); do
        uci delete "dhcp.$_sec" >/dev/null 2>&1 || return 1
        _n=$((_n + 1))
        _z2k_ow_rt_mut "DNS_REMOVED: $_sec"
    done
    [ "$_n" = "0" ] && return 0
    uci commit dhcp >/dev/null 2>&1 || return 1
    _z2k_ow_rt_dns_reload || return 1
    return 0
}

# --- desync-exclusion (RT20): effective whitelist ensure ---

# whitelist.txt читает генератор (wl_excl -> $Z2K_LISTS_DIR/whitelist.txt).
# RKN-лист updater-owned (править нельзя — сломаем converge); geosite-subtract
# на OpenWrt не бегает. Поэтому ensure exact-5 здесь: append недостающих,
# чужие строки/порядок не трогаем, ничего не удаляем. Провал -> RT не ready.
z2k_ow_rt_desync_exclude() {
    local _wl="${Z2K_LISTS_DIR:-/usr/lib/z2k/lists}/whitelist.txt" _d
    mkdir -p "$(dirname "$_wl")" 2>/dev/null || return 1
    [ -e "$_wl" ] || : > "$_wl" 2>/dev/null || return 1
    for _d in $Z2K_RT_DOMAINS; do
        grep -qxF "$_d" "$_wl" 2>/dev/null || {
            printf '%s\n' "$_d" >> "$_wl" 2>/dev/null || return 1
        }
    done
    return 0
}

# --- nft ---

_z2k_ow_rt_table_ok() {
    nft list table "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" >/dev/null 2>&1
}

# Конвергенция redirect + guard. Идемпотентна (flush+add).
z2k_ow_rt_nft_apply() {
    _z2k_ow_rt_table_ok || {
        echo "z2k-openwrt: rt: нет таблицы $Z2K_RT_NFT_FAMILY $Z2K_RT_NFT_TABLE (сначала fw_apply)" >&2
        return 1
    }
    nft add chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_PRE" \
        '{ type nat hook prerouting priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT" \
        '{ type nat hook output priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_IN" \
        '{ type filter hook input priority -1; }' 2>/dev/null || true
    nft add chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_FWD6" \
        '{ type filter hook forward priority -1; }' 2>/dev/null || true
    nft add chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT6" \
        '{ type filter hook output priority -1; }' 2>/dev/null || true
    nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_PRE" 2>/dev/null || true
    nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT" 2>/dev/null || true
    nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_IN" 2>/dev/null || true
    nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_FWD6" 2>/dev/null || true
    nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT6" 2>/dev/null || true
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_PRE" \
        tcp dport 443 ip daddr "$Z2K_RT_SENTINEL" redirect to ":$Z2K_RT_PORT" || return 1
    _z2k_ow_rt_mut "NFT_CREATED: $Z2K_RT_CHAIN_PRE redirect :$Z2K_RT_PORT"
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT" \
        tcp dport 443 ip daddr "$Z2K_RT_SENTINEL" redirect to ":$Z2K_RT_PORT" || return 1
    _z2k_ow_rt_mut "NFT_CREATED: $Z2K_RT_CHAIN_OUT redirect :$Z2K_RT_PORT"
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_IN" \
        tcp dport "$Z2K_RT_PORT" ct status dnat accept || return 1
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_IN" \
        tcp dport "$Z2K_RT_PORT" drop || return 1
    _z2k_ow_rt_mut "NFT_CREATED: $Z2K_RT_CHAIN_IN guard :$Z2K_RT_PORT"
    # IPv6 sentinel fast-reject (FORWARD для LAN, OUTPUT для router-local):
    # TCP RST вместо timeout -> клиент сразу fallback'ится на tunneled IPv4.
    # Scope строго sentinel (никакого generic v6 reject — Cloudflare/shared).
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_FWD6" \
        tcp ip6 daddr "$Z2K_RT_SENTINEL6" reject with tcp reset || return 1
    _z2k_ow_rt_mut "NFT_CREATED: $Z2K_RT_CHAIN_FWD6 reject $Z2K_RT_SENTINEL6"
    nft add rule "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$Z2K_RT_CHAIN_OUT6" \
        tcp ip6 daddr "$Z2K_RT_SENTINEL6" reject with tcp reset || return 1
    _z2k_ow_rt_mut "NFT_CREATED: $Z2K_RT_CHAIN_OUT6 reject $Z2K_RT_SENTINEL6"
    return 0
}

z2k_ow_rt_nft_remove() {
    local _c
    _z2k_ow_rt_table_ok || return 0
    for _c in "$Z2K_RT_CHAIN_PRE" "$Z2K_RT_CHAIN_OUT" "$Z2K_RT_CHAIN_IN" "$Z2K_RT_CHAIN_FWD6" "$Z2K_RT_CHAIN_OUT6"; do
        nft flush chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$_c" 2>/dev/null || true
        nft delete chain "$Z2K_RT_NFT_FAMILY" "$Z2K_RT_NFT_TABLE" "$_c" 2>/dev/null || true
        _z2k_ow_rt_mut "NFT_REMOVED: $_c"
    done
    return 0
}

# --- procd ---

z2k_ow_rt_start_instance() {
    command -v procd_open_instance >/dev/null 2>&1 || {
        echo "z2k-openwrt: rt: нет procd-контекста (только из start_service)" >&2
        return 1
    }
    procd_open_instance "z2k-rt"
    z2k_ow_rt_with_argv _z2k_ow_rt_procd_command
    procd_set_param env GODEBUG=asyncpreemptoff=1
    procd_set_param pidfile "$Z2K_RT_PIDFILE"
    # Bounded respawn как TG (доказательство: procd/service/instance.c):
    # threshold 3600 / timeout 5 / retry 5; crash-loop halt'ится, не штормит.
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    _z2k_ow_rt_mut "PROCESS_ACTION: instance z2k-rt opened"
    return 0
}

# --- топология ---

# Halt-teardown (§15 contract): демон мёртв N тиков подряд (procd-рестарт —
# секунды, живого там быть не может) -> согласованно снимаем redirect+DNS,
# ставим latch (флапать DNS запрещено). Latch снимают: рестарт сервиса
# (ветка 1 чистит), живой процесс, смена бинарника.
_z2k_ow_rt_halt_teardown() {
    z2k_ow_rt_nft_remove >/dev/null 2>&1 || true
    z2k_ow_rt_dns_remove >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$Z2K_RT_HALT_LATCH")" 2>/dev/null
    : > "$Z2K_RT_HALT_LATCH" 2>/dev/null
    logger -t z2k-rt "daemon dead persistently, feature torn down (DNS+redirect removed), latched until service restart" 2>/dev/null || true
    return 0
}

z2k_ow_rt() {
    case "${1:-}" in
        1)
            z2k_ow_rt_wanted || return 0
            rm -f "$Z2K_RT_HALT_LATCH" 2>/dev/null
            z2k_ow_rt_dns_apply || return 1
            z2k_ow_rt_desync_exclude || return 1
            z2k_ow_rt_nft_apply || return 1
            z2k_ow_rt_start_instance || return 1
            ;;
        0)
            # Full stop: процесс — через procd (сервис останавливается);
            # здесь снимаем nft + DNS. Порядок: сначала redirect (трафик
            # перестаёт идти в локальный порт), затем DNS.
            z2k_ow_rt_nft_remove
            z2k_ow_rt_dns_remove
            ;;
        rules)
            # hotplug/firewall-reload: converge без трогания демона.
            # !wanted -> converge-to-stop (правила+DNS снять), процесс не kill'им
            # (владелец — procd; следующий stop/restart доведёт).
            if z2k_ow_rt_wanted; then
                z2k_ow_rt_desync_exclude || return 1
                z2k_ow_rt_nft_apply || return 1
            else
                z2k_ow_rt_nft_remove
                z2k_ow_rt_dns_remove >/dev/null 2>&1 || true
            fi
            ;;
        proc-bounce)
            # Daemon-only restart (init restart / binary refresh): ТОЛЬКО kill,
            # procd поднимает заново; DNS/rules/exclusion НЕ трогаем (gap запрещён).
            if z2k_ow_rt_running; then
                for _p in $(z2k_ow_rt_pids); do _z2k_ow_rt_kill "$_p"; done
                _z2k_ow_rt_mut "PROCESS_ACTION: bounced (DNS/rules kept)"
            fi
            ;;
        cleanup)
            # uninstall: всё снять, никогда не валить удаление.
            z2k_ow_rt_nft_remove >/dev/null 2>&1 || true
            z2k_ow_rt_dns_remove >/dev/null 2>&1 || true
            rm -f "$Z2K_RT_HALT_LATCH" 2>/dev/null
            return 0
            ;;
        check)
            z2k_ow_rt_check
            ;;
        *)
            echo "usage: z2k_ow_rt {1|0|rules|proc-bounce|cleanup|check}" >&2
            return 1
            ;;
    esac
    return 0
}

# --- health check (cron) ---

z2k_ow_rt_check() {
    local _dead_f="$Z2K_RT_HEALTH_DIR/dead" _dead=0
    mkdir -p "$Z2K_RT_HEALTH_DIR" 2>/dev/null || return 0
    if ! z2k_ow_rt_wanted; then
        # Disabled: конвергенция к стоп (процесс добить, правила+DNS снять).
        if z2k_ow_rt_running; then
            for _p in $(z2k_ow_rt_pids); do _z2k_ow_rt_kill "$_p"; done
        fi
        z2k_ow_rt_nft_remove >/dev/null 2>&1 || true
        z2k_ow_rt_dns_remove >/dev/null 2>&1 || true
        rm -f "$_dead_f" "$Z2K_RT_HALT_LATCH" 2>/dev/null
        return 0
    fi
    if [ -f "$Z2K_RT_HALT_LATCH" ]; then
        # Latched teardown: не flap'аем. Живой процесс = оператор поднял
        # вручную -> снять latch, сконвергировать заново.
        if z2k_ow_rt_running; then
            rm -f "$Z2K_RT_HALT_LATCH" "$_dead_f" 2>/dev/null
        else
            return 0
        fi
    fi
    # Converge (только добавляет/проверяет — removals здесь нет).
    z2k_ow_rt_dns_apply >/dev/null 2>&1 || return 0
    z2k_ow_rt_desync_exclude >/dev/null 2>&1 || return 0
    z2k_ow_rt_nft_apply >/dev/null 2>&1 || return 0
    if z2k_ow_rt_running; then
        rm -f "$_dead_f" 2>/dev/null
        return 0
    fi
    # Мёртв: procd поднимет за секунды. Считаем тики; ≥3 подряд (~15 мин) ->
    # это halt, а не transient: согласованный teardown + latch.
    [ -f "$_dead_f" ] && _dead=$(head -1 "$_dead_f" 2>/dev/null)
    case "$_dead" in ''|*[!0-9]*) _dead=0 ;; esac
    _dead=$((_dead + 1))
    printf '%s\n' "$_dead" > "$_dead_f" 2>/dev/null
    [ "$_dead" -lt 3 ] && return 0
    _z2k_ow_rt_halt_teardown
    return 0
}
