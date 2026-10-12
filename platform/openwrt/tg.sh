#!/bin/sh
# platform/openwrt/tg.sh — адаптер прозрачного Telegram-прокси на Rust.
#
# Один экземпляр Rust слушает :1443 в существующем цикле procd z2k и
# перенаправляет настроенные TCP-порты Telegram в nft-таблице zapret2.
#
# Использование (требует выставленных paths/env):
#   z2k_ow_tg 1        — сверить правила/наборы и зарегистрировать procd, если запуск разрешён
#   z2k_ow_tg 0        — снять цепочки, оставив наборы для быстрого перезапуска
#   z2k_ow_tg cleanup  — при удалении снять цепочки и наборы, не затрагивая таблицу
#   z2k_ow_tg rules    — сверить только правила и наборы (hotplug, без демона)
#   z2k_ow_tg check    — периодическая проверка: правила, проверка порта, остановка при сбое
#
# Секреты: argv собирается в позиционных параметрах, никогда не печатается
# (set -x и echo argv здесь запрещены — см. test_ow_tg_static.sh).

# --- значения политики ---
_z2k_tg_policy="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/tg-policy.sh"
_z2k_tg_policy_present=0
Z2K_TG_POLICY_LOADED=0
if [ -r "$_z2k_tg_policy" ]; then
    . "$_z2k_tg_policy" || return 1
    _z2k_tg_policy_present=1
    Z2K_TG_POLICY_LOADED=1
fi
Z2K_TG_PORT="${Z2K_TG_PORT:-1443}"
Z2K_TG_MAX_CONNECTIONS="${Z2K_TG_MAX_CONNECTIONS:-8}"

# --- nft-имена (свои sets/chains в ЧУЖОЙ runtime-таблице; таблицу не создаём) ---
# Дефолт таблицы = дефолт pinned zapret2 runtime (ZAPRET_NFT_TABLE=zapret2):
# свои chains в чужой таблице, второго фреймворка нет (Stage 8 live-дефект:
# дефолт zapret не совпадал с рантаймом — TG/RT/WARP валились fail-closed).
Z2K_TG_NFT_FAMILY="${Z2K_TG_NFT_FAMILY:-inet}"
Z2K_TG_NFT_TABLE="${Z2K_TG_NFT_TABLE:-zapret2}"
Z2K_TG_SET4="${Z2K_TG_SET4:-z2k_tg_dc4}"
Z2K_TG_SET6="${Z2K_TG_SET6:-z2k_tg_dc6}"
Z2K_TG_SETCDN="${Z2K_TG_SETCDN:-z2k_tg_cdn4}"
Z2K_TG_CHAIN_PRE="${Z2K_TG_CHAIN_PRE:-z2k_tg_dst_pre}"
Z2K_TG_CHAIN_OUT="${Z2K_TG_CHAIN_OUT:-z2k_tg_dst_out}"
Z2K_TG_CHAIN_FWD="${Z2K_TG_CHAIN_FWD:-z2k_tg_flt_fwd}"
Z2K_TG_CHAIN_OUTF="${Z2K_TG_CHAIN_OUTF:-z2k_tg_flt_out}"
# INPUT-guard против прямого WAN-доступа к wildcard-портам (см. ниже).
Z2K_TG_CHAIN_IN="${Z2K_TG_CHAIN_IN:-z2k_tg_flt_in}"

if [ -z "${Z2K_TG_RUST_BIN:-}" ]; then
    _z2k_tg_adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    if [ -r "$_z2k_tg_adapter/arch.sh" ]; then
        . "$_z2k_tg_adapter/arch.sh"
        Z2K_TG_RUST_BIN="$(z2k_ow_tg_rust_bin_path "${Z2K_BIN:-/usr/lib/z2k/bin}" 2>/dev/null)" || Z2K_TG_RUST_BIN=""
    fi
    Z2K_TG_RUST_BIN="${Z2K_TG_RUST_BIN:-${Z2K_BIN:-/usr/lib/z2k/bin}/tg-ws-proxy}"
fi
Z2K_TG_PIDFILE="${Z2K_TG_PIDFILE:-${Z2K_RUN:-/tmp/z2k/runtime}/tg-tunnel.pid}"
Z2K_TG_HEALTH_DIR="${Z2K_TG_HEALTH_DIR:-${Z2K_TMP:-/tmp/z2k}/tg-health}"
# Корень /proc (тестам — фикстура; прод всегда настоящий /proc).
Z2K_PROC_ROOT="${Z2K_PROC_ROOT:-/proc}"

# Чтение флага из $Z2K_CONFIG без сорсинга (cron/hotplug-контексты).
# $1 key, $2 default.
z2k_ow_tg_cfg() {
    local _v=""
    [ -f "${Z2K_CONFIG:-/etc/z2k/config}" ] && \
        _v=$(awk -F= -v k="$1" '$1==k {v=$2; gsub(/[" ]/,"",v)} END {print v}' \
            "${Z2K_CONFIG:-/etc/z2k/config}" 2>/dev/null)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

# Настроенные порты и CIDR приводятся к спискам для shell/Rust/nft.
# $1 — список значений; запятые и пробелы допустимы.
_z2k_ow_tg_words() { printf '%s\n' "$1" | tr ',' ' '; }

z2k_ow_tg_ports() {
    local _input _port _seen="" _out=""
    _input="$(_z2k_ow_tg_words "$Z2K_TG_TCP_PORTS")"
    for _port in $_input; do
        case "$_port" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_port" -ge 1 ] 2>/dev/null && [ "$_port" -le 65535 ] 2>/dev/null || return 1
        case " $_seen " in *" $_port "*) return 1 ;; esac
        _seen="$_seen $_port"
        _out="$_out$_port\n"
    done
    [ -n "$_out" ] || return 1
    printf '%b' "$_out"
}

z2k_ow_tg_ports_csv() {
    local _port _csv="" _ports
    _ports=$(z2k_ow_tg_ports) || return 1
    for _port in $_ports; do
        [ -n "$_csv" ] && _csv="$_csv,"
        _csv="$_csv$_port"
    done
    printf '%s' "$_csv"
}

z2k_ow_tg_cidrs() {
    _z2k_ow_tg_words "$1" | awk '{$1=$1; if (NF) print}'
}

z2k_ow_tg_cidrs_csv() {
    z2k_ow_tg_cidrs "$1" | tr ' ' ',' | tr '\n' ',' | sed 's/,$//'
}

# Применить значения из пользовательского файла поверх встроенной политики.
Z2K_TG_TCP_PORTS="${Z2K_TG_TCP_PORTS:-$(z2k_ow_tg_cfg TG_TCP_PORTS "${Z2K_TG_TCP_PORTS_DEFAULT:-}")}"
Z2K_TG_CIDRS="${Z2K_TG_CIDRS:-$(z2k_ow_tg_cidrs "$(z2k_ow_tg_cfg TG_CIDRS4 "${Z2K_TG_CIDRS_DEFAULT:-}")")}"
Z2K_TG_CIDRS6="${Z2K_TG_CIDRS6:-$(z2k_ow_tg_cidrs "$(z2k_ow_tg_cfg TG_CIDRS6 "${Z2K_TG_CIDRS6_DEFAULT:-}")")}"
Z2K_TG_POLICY_LOADED=0
if [ "$_z2k_tg_policy_present" = 1 ] \
    && [ -n "$Z2K_TG_CIDRS" ] && [ -n "$Z2K_TG_CIDRS6" ] \
    && z2k_ow_tg_ports >/dev/null 2>&1; then
    Z2K_TG_POLICY_LOADED=1
fi

z2k_ow_tg_arch_supported() {
    local _arch_file="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/arch.sh"
    [ -r "$_arch_file" ] || return 1
    . "$_arch_file" || return 1
    z2k_ow_tg_rust_target "${Z2K_OW_ARCH:-$(z2k_ow_detect_arch)}" >/dev/null 2>&1
}

z2k_ow_tg_status() {
    if ! z2k_ow_tg_arch_supported; then
        printf '%s\n' 'Тип не поддерживается'
        return 2
    fi
    [ -x "$Z2K_TG_RUST_BIN" ] || { printf '%s\n' 'Rust TG WS Proxy не установлен'; return 1; }
    printf '%s\n' 'Rust TG WS Proxy'
}

# Условия запуска: исполняемый бинарник, ENABLED=1 и пользовательский запрет выключен.
z2k_ow_tg_panel_enable() {
    local _cfg="${CONFIG_FILE:-/etc/z2k/config}" _init="${Z2K_INIT:-/etc/init.d/z2k}"
    z2k_ow_tg_arch_supported || {
        echo "Тип не поддерживается: Rust TG WS Proxy недоступен для этой архитектуры" >&2
        return 1
    }
    [ -x "${Z2K_TG_RUST_BIN:-}" ] || {
        echo "Rust TG WS Proxy не установлен для этой архитектуры" >&2
        return 1
    }
    if grep -q '^TG_PROXY_USER_DISABLED=' "$_cfg" 2>/dev/null; then
        sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "$_cfg" 2>/dev/null
    fi
    echo "Применяю через z2k/procd..."
    [ -x "$_init" ] || { echo "нет $_init" >&2; return 1; }
    "$_init" reload 2>&1
}

z2k_ow_tg_status_json() {
    local _running="${1:-false}" _supported=true _installed=true
    local _status='Rust TG WS Proxy' _message='Прозрачный Telegram TCP через Rust TG WS Proxy на настроенных портах.'
    if ! z2k_ow_tg_arch_supported; then
        _supported=false
        _installed=false
        _status='Тип не поддерживается'
        _message='Rust TG WS Proxy недоступен для этой архитектуры.'
    elif [ ! -x "${Z2K_TG_RUST_BIN:-}" ]; then
        _installed=false
        _status='Не установлен'
        _message='В релизе отсутствует Rust TG WS Proxy для этой архитектуры.'
    fi
    printf '{"running":%s,"supported":%s,"installed":%s,"status":' \
        "$_running" "$_supported" "$_installed"
    json_string "$_status"
    printf ',"message":'
    json_string "$_message"
    printf '}'
}

z2k_ow_tg_wanted() {
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || return 1
    z2k_ow_tg_arch_supported || return 1
    [ -x "$Z2K_TG_RUST_BIN" ] || return 1
    [ "$(z2k_ow_tg_cfg ENABLED 1)" = "1" ] || return 1
    [ "$(z2k_ow_tg_cfg TG_PROXY_USER_DISABLED 0)" = "1" ] && return 1
    return 0
}

# Собрать аргументы демона и передать их команде $1.
# Прозрачный режим не использует секрет прокси; аргументы передаются без печати.
# Использование: z2k_ow_tg_with_argv _cb (одно слово — см. ниже).
z2k_ow_tg_with_argv() {
    local _cb="$1"
    shift
    set -- "$Z2K_TG_RUST_BIN" "--port=$Z2K_TG_PORT" --host=:: \
        --transparent --pool-size=0 "--max-connections=$Z2K_TG_MAX_CONNECTIONS" \
        "--transparent-ports=$(z2k_ow_tg_ports_csv)" \
        "--transparent-cidrs=$(z2k_ow_tg_cidrs_csv "$Z2K_TG_CIDRS $Z2K_TG_CIDRS6")" \
        "--dc-map-path=$(z2k_ow_tg_cfg TG_DC_MAP_PATH "$Z2K_TG_DC_MAP_PATH_DEFAULT")" \
        "--dc-map-refresh-secs=$(z2k_ow_tg_cfg TG_DC_MAP_REFRESH_SECS "$Z2K_TG_DC_MAP_REFRESH_SECS_DEFAULT")" \
        --default-domains --no-outbound-proxy
    "$_cb" "$@"
}

# Обёртка procd: вызов из двух слов нельзя передать как один обратный вызов,
# поэтому используется функция адаптера (тесты подменяют procd_set_param).
_z2k_ow_tg_procd_command() { procd_set_param command "$@"; }

# Остановка демона выполняется через помощник, который тесты могут подменить;
# procd самостоятельно запустит процесс заново. Встроенную команду kill
# невозможно перехватить подменой PATH.
_z2k_ow_tg_kill() { kill "$@" 2>/dev/null || true; }

# PID единственного прозрачного слушателя Rust.
z2k_ow_tg_pids() {
    local _p _cl
    for _p in $(pidof tg-ws-proxy 2>/dev/null); do
        [ -r "$Z2K_PROC_ROOT/$_p/cmdline" ] || continue
        _cl=$(tr '\0' ' ' < "$Z2K_PROC_ROOT/$_p/cmdline" 2>/dev/null)
        case " $_cl " in *" --transparent "*) ;; *) continue ;; esac
        case " $_cl " in *" --port=$Z2K_TG_PORT "*) printf '%s\n' "$_p" ;; esac
    done
    return 0
}

# Остановить старый процесс до регистрации экземпляра Rust. Настройки прежнего
# транспорта сохраняются только до подтверждённого перехода, чтобы откатиться
# на предыдущую подписанную версию; Rust их не читает.
z2k_ow_tg_stop_legacy() {
    local _p _try _found
    for _p in $(pidof tg-mtproxy-client 2>/dev/null); do
        kill -TERM "$_p" 2>/dev/null || true
        _try=0
        while kill -0 "$_p" 2>/dev/null && [ "$_try" -lt 20 ]; do
            sleep 0.1
            _try=$((_try + 1))
        done
        if kill -0 "$_p" 2>/dev/null; then kill -KILL "$_p" 2>/dev/null || true; fi
        kill -0 "$_p" 2>/dev/null && _found=1
    done
    [ "${_found:-0}" = 0 ]
}

z2k_ow_tg_socket_listening() {
    local _port="$(printf '%04X' "$1" 2>/dev/null)"
    [ -n "$_port" ] || return 1
    awk -v p="$_port" '$2 ~ (":" p "$") && $4 == "0A" {ok=1} END {exit !ok}' \
        "$Z2K_PROC_ROOT/net/tcp" "$Z2K_PROC_ROOT/net/tcp6" 2>/dev/null
}

z2k_ow_tg_listeners_ready() {
    z2k_ow_tg_socket_listening "$Z2K_TG_PORT"
}

z2k_ow_tg_running() { [ -n "$(z2k_ow_tg_pids)" ]; }

# --- nftables ---

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

# Атомарно заменить оба Telegram-набора одной nft-транзакцией.
# nft применяет batch целиком либо сохраняет прежнее содержимое наборов.
_z2k_ow_tg_nft_sets_commit() {
    local _dc4 _dc6
    _dc4="$(_z2k_ow_tg_csv "$Z2K_TG_CIDRS")"
    _dc6="$(_z2k_ow_tg_csv "$Z2K_TG_CIDRS6")"
    {
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4"
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6"
        printf 'add element %s %s %s { %s }\n' \
            "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" "$_dc4"
        printf 'add element %s %s %s { %s }\n' \
            "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" "$_dc6"
    } | nft -f - || return 1
    return 0
}

# Конвергенция sets+chains+rules. Идемпотентна; CIDR-наборы меняются атомарно.
z2k_ow_tg_nft_apply() {
    local _port _ports
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || {
        echo "z2k-openwrt: tg: политика Telegram TCP не загружена или некорректна" >&2
        return 1
    }
    _z2k_ow_tg_table_ok || {
        echo "z2k-openwrt: tg: нет таблицы $Z2K_TG_NFT_FAMILY $Z2K_TG_NFT_TABLE (сначала fw_apply)" >&2
        return 1
    }
    # Удалить оставшийся после старого CDN-туннеля набор с адресом relay.
    if nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SETCDN" >/dev/null 2>&1; then
        nft delete set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SETCDN" \
            || { echo "z2k-openwrt: tg: не удалось удалить старый набор CDN из nft" >&2; return 1; }
    fi
    # Создать наборы при отсутствии и затем детерминированно обновить их.
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" \
        '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" \
        '{ type ipv6_addr; flags interval; }' 2>/dev/null || true
    _z2k_ow_tg_nft_sets_commit || {
        echo "z2k-openwrt: tg: не удалось атомарно обновить наборы CIDR Telegram" >&2
        return 1
    }
    # В прежних сборках отдельные цепочки фильтра отклоняли IPv6. Удалить эти
    # принадлежащие z2k цепочки: IPv6 Telegram TCP идёт в Rust по общей политике.
    for _old_chain in "$Z2K_TG_CHAIN_FWD" "$Z2K_TG_CHAIN_OUTF"; do
        nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_old_chain" 2>/dev/null || true
        nft delete chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_old_chain" 2>/dev/null || true
    done
    # Цепочки base принадлежат z2k, таблица остаётся системной.
    # Приоритеты — целые числа (арифметика вида `dstnat - 1` здесь не
    # используется осознанно: её поддержка зависит от парсера, числа — нет):
    #   -101 = перед dstnat(-100): эквивалент вставки в PREROUTING/OUTPUT;
    #   -1   = перед filter(0): эквивалент вставки в FORWARD/OUTPUT/INPUT.
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
        '{ type nat hook prerouting priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
        '{ type nat hook output priority -101; }' 2>/dev/null || true
    nft add chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        '{ type filter hook input priority -1; }' 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" 2>/dev/null || true
    nft flush chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" 2>/dev/null || true
# Единая политика генерирует обе семьи адресов из одного списка портов.
    # Счётчик стоит перед terminal redirect и доступен для диагностики на роутере.
    _ports=$(z2k_ow_tg_ports) || return 1
    for _port in $_ports; do
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
            tcp dport "$_port" ip daddr "@$Z2K_TG_SET4" counter redirect to ":$Z2K_TG_PORT" || return 1
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
            tcp dport "$_port" ip6 daddr "@$Z2K_TG_SET6" counter redirect to ":$Z2K_TG_PORT" || return 1
    done
    # Исходящие WSS/CF/TCP-сокеты Rust помечены меткой z2k DESYNC, поэтому их
    # соединения обходят это перенаправление OUTPUT и путь NFQUEUE.
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
        meta mark 0x40000000 return || return 1
    _ports=$(z2k_ow_tg_ports) || return 1
    for _port in $_ports; do
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
            tcp dport "$_port" ip daddr "@$Z2K_TG_SET4" counter redirect to ":$Z2K_TG_PORT" || return 1
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
            tcp dport "$_port" ip6 daddr "@$Z2K_TG_SET6" counter redirect to ":$Z2K_TG_PORT" || return 1
    done
    # Защита INPUT: слушатель принимает соединения на всех адресах; прямой доступ к :1443
    # не должны доходить до демона. Перенаправленные пакеты (LAN/локальные)
    # несут conntrack-статус dnat (ставится DNAT на всё соединение) —
    # их пропускаем первыми; прямой трафик без этого статуса отбрасываем. Порядок
    # критичен (accept до drop). Проверяем только наши порты: общее правило
    # `ct status dnat accept` обошло бы fw4-input для чужого DNAT-трафика.
    # Прямое подключение LAN к :1443 блокируется здесь дополнительно к проверке
    # в Rust. Порт не открывается; добавляется только это правило блокировки.
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        tcp dport "$Z2K_TG_PORT" ct status dnat accept || return 1
    nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" \
        tcp dport "$Z2K_TG_PORT" drop || return 1
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

# Только записи Telegram. conntrack может
# отсутствовать — тогда best-effort пропуск (см. DEPENDS +conntrack).
z2k_ow_tg_conntrack_flush() {
    local _c
    for _c in $Z2K_TG_CIDRS; do
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
    procd_open_instance "z2k-tg"
    z2k_ow_tg_with_argv _z2k_ow_tg_procd_command
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
            z2k_ow_tg_stop_legacy || return 1
            z2k_ow_tg_wanted || { z2k_ow_tg_nft_remove; return 0; }
            z2k_ow_tg_nft_apply || return 1
            z2k_ow_tg_conntrack_flush
            z2k_ow_tg_start_instance || return 1
            ;;
        0)
            z2k_ow_tg_nft_remove
            ;;
        rules)
            # hotplug/firewall-reload: только правила, демон не трогаем.
            # Ready-gate (no resurrection после manual stop/failed start):
            # предикат из env.sh; при одиночном сорсинге в тестах его нет.
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            z2k_ow_tg_wanted || { z2k_ow_tg_nft_remove; return 0; }
            z2k_ow_tg_nft_apply || return 1
            ;;
        cleanup)
            # uninstall: всё убрать, никогда не валить удаление.
            z2k_ow_tg_nft_remove full || true
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
    local _s _c _out _need _port _match _ports
    Z2K_TG_NFT_DRIFT_REDIRECT=0
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    _z2k_ow_tg_table_ok || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    for _s in "$Z2K_TG_SET4:$Z2K_TG_CIDRS" \
              "$Z2K_TG_SET6:$Z2K_TG_CIDRS6"; do
        _name=${_s%%:*}; _need=${_s#*:}
        _out=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_name" 2>/dev/null) || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        for _v in $_need; do
            printf '%s\n' "$_out" | grep -qF "${_v%/32}" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        done
    done
    for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT" "$Z2K_TG_CHAIN_IN"; do
        _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null) || {
            Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    done
    _ports=$(z2k_ow_tg_ports) || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    for _port in $_ports; do
        for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT"; do
            _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null)
            for _match in "ip daddr @$Z2K_TG_SET4" "ip6 daddr @$Z2K_TG_SET6"; do
                printf '%s\n' "$_out" | tr -s ' ' | grep -Eq "tcp dport $_port $_match counter( packets [0-9]+ bytes [0-9]+)? redirect to :$Z2K_TG_PORT" || {
                    Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            done
        done
    done
    _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" 2>/dev/null)
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF 'meta mark 0x40000000 return' || {
        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_IN" 2>/dev/null)
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "tcp dport $Z2K_TG_PORT ct status dnat accept" || {
        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "tcp dport $Z2K_TG_PORT drop" || {
        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    return 0
}

# --- health check (cron, см. contract §8) ---

_z2k_ow_tg_probe() { z2k_ow_tg_running && z2k_ow_tg_listeners_ready; }

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
    logger -t z2k-tg "проверка состояния не прошла ${_fails} раз, демон остановлен (procd перезапустит, задержка №${_kills})" 2>/dev/null || true
    return 0
}
