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

# Загрузить единый источник постоянных путей, если вызывающий код ещё этого не сделал.
_z2k_tg_paths="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/paths.sh"
if [ -r "$_z2k_tg_paths" ]; then
    . "$_z2k_tg_paths" || return 1
fi

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
_z2k_tg_max_connections_override="${Z2K_TG_MAX_CONNECTIONS:-}"

# --- nft-имена (свои sets/chains в ЧУЖОЙ runtime-таблице; таблицу не создаём) ---
# Дефолт таблицы = дефолт pinned zapret2 runtime (ZAPRET_NFT_TABLE=zapret2):
# свои chains в чужой таблице, второго фреймворка нет (Stage 8 live-дефект:
# дефолт zapret не совпадал с рантаймом — TG/RT/WARP валились fail-closed).
Z2K_TG_NFT_FAMILY="${Z2K_TG_NFT_FAMILY:-inet}"
Z2K_TG_NFT_TABLE="${Z2K_TG_NFT_TABLE:-zapret2}"
Z2K_TG_SET4="${Z2K_TG_SET4:-z2k_tg_dc4}"
Z2K_TG_SET6="${Z2K_TG_SET6:-z2k_tg_dc6}"
Z2K_TG_PAIR4="${Z2K_TG_PAIR4:-z2k_tg_pair4}"
Z2K_TG_PAIR6="${Z2K_TG_PAIR6:-z2k_tg_pair6}"
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

# Чтение без сорсинга: сохраняем внутренние пробелы и знаки равенства.
# $1 key, $2 default.
z2k_ow_tg_cfg() {
    local _v="" _file _rc _found=0
    for _file in "${Z2K_TG_POLICY_CONFIG:-${Z2K_ETC:-/etc/z2k}/tg-policy.conf}" "${Z2K_CONFIG:-/etc/z2k/config}"; do
        [ -f "$_file" ] || continue
        _v=$(awk -v k="$1" '
            function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
            {
                p = index($0, "="); if (!p) next
                name = trim(substr($0, 1, p - 1)); if (name != k) next
                value = trim(substr($0, p + 1))
                if (length(value) >= 2 && ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") || (substr(value,1,1) == "\047" && substr(value,length(value),1) == "\047"))) value = substr(value,2,length(value)-2)
                found = value
                found_line = 1
            }
            END { if (found_line) printf "%s", found; else exit 3 }
        ' "$_file" 2>/dev/null)
        _rc=$?
        if [ "$_rc" = 0 ]; then _found=1; break; fi
    done
    if [ "$_found" = 1 ]; then printf '%s' "$_v"; else printf '%s' "$2"; fi
}

# Нормализовать адрес так же, как Rust CLI: схема и путь URL отбрасываются,
# но порт, IP-литерал и некорректные DNS-метки отклоняются.
z2k_ow_tg_worker_normalize() {
    local _domain _label _valid=1 _was_noglob=0
    _domain=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$_domain" in
        https://*) _domain=${_domain#https://} ;;
        http://*) _domain=${_domain#http://} ;;
    esac
    _domain=${_domain%%/*}
    _domain=${_domain%.}
    [ -n "$_domain" ] && [ "${#_domain}" -le 253 ] || return 1
    case "$_domain" in *.*) ;; *) return 1 ;; esac
    case "$_domain" in .*|*.|*..*|*[!a-z0-9.-]*|*-.*|*.-*) return 1 ;; esac
    case "$_domain" in *[!0-9.]* ) ;; *) return 1 ;; esac
    case "$_domain" in *:*) return 1 ;; esac
    local _old_ifs="$IFS"
    IFS=.
    case $- in *f*) _was_noglob=1 ;; *) set -f ;; esac
    set -- $_domain
    IFS="$_old_ifs"
    for _label in "$@"; do
        if [ -z "$_label" ] || [ "${#_label}" -gt 63 ]; then _valid=0; break; fi
        case "$_label" in -*|*-) _valid=0; break ;; esac
    done
    [ "$_was_noglob" = 1 ] || set +f
    [ "$_valid" = 1 ] || return 1
    printf '%s' "$_domain"
}

z2k_ow_tg_worker_domains() {
    local _configured _domain _normalized _seen="" _was_noglob=0
    _configured=$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS "")
    _configured=$(printf '%s' "$_configured" | tr ',' ' ')
    case $- in *f*) _was_noglob=1 ;; *) set -f ;; esac
    for _domain in $_configured; do
        _normalized=$(z2k_ow_tg_worker_normalize "$_domain") || continue
        case " $_seen " in *" $_normalized "*) continue ;; esac
        _seen="$_seen $_normalized"
        printf '%s\n' "$_normalized"
    done
    [ "$_was_noglob" = 1 ] || set +f
}

_z2k_ow_tg_worker_apply() {
    local _action="$1" _domain="$2" _config="${Z2K_TG_POLICY_CONFIG:-${Z2K_ETC:-/etc/z2k}/tg-policy.conf}"
    local _tmp="${Z2K_TMP:-/tmp/z2k}/tg-workers.$$" _lock="${Z2K_TMP:-/tmp/z2k}/locks/tg-workers.lock"
    local _entry _domains="" _count=0 _found=0 _updated _was_noglob=0
    _domain=$(z2k_ow_tg_worker_normalize "$_domain") || {
        echo 'неверный домен Cloudflare Worker' >&2
        return 1
    }
    mkdir -p "$(dirname "$_config")" "$(dirname "$_lock")" "$(dirname "$_tmp")" || return 1
    mkdir "$_lock" 2>/dev/null || {
        echo 'изменение списка Worker уже выполняется' >&2
        return 1
    }
    _updated=$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS "")
    _updated=$(printf '%s' "$_updated" | tr ',' ' ')
    case $- in *f*) _was_noglob=1 ;; *) set -f ;; esac
    for _entry in $_updated; do
        _entry=$(z2k_ow_tg_worker_normalize "$_entry") || {
            rmdir "$_lock" 2>/dev/null || true
            echo 'в сохранённом списке есть неверный домен Worker' >&2
            [ "$_was_noglob" = 1 ] || set +f
            return 1
        }
        case " $_domains " in *" $_entry "*) continue ;; esac
        if [ "$_entry" = "$_domain" ]; then _found=1; fi
        if [ "$_action" != remove ] || [ "$_entry" != "$_domain" ]; then
            _domains="$_domains $_entry"
            _count=$((_count + 1))
        fi
    done
    [ "$_was_noglob" = 1 ] || set +f
    if [ "$_action" = add ]; then
        if [ "$_found" = 0 ]; then
            [ "$_count" -lt 8 ] || {
                rmdir "$_lock" 2>/dev/null || true
                echo 'можно настроить не более восьми Worker' >&2
                return 1
            }
            _domains="$_domains $_domain"
        fi
    elif [ "$_action" != remove ]; then
        rmdir "$_lock" 2>/dev/null || true
        return 1
    fi
    _domains=$(printf '%s' "$_domains" | awk '{$1=$1; gsub(/[[:space:]]+/, ","); print}')
    (
        umask 077
        if [ -r "$_config" ]; then
            awk -F= '$1 != "TG_CF_WORKER_DOMAINS" { print }' "$_config" > "$_tmp" || exit 1
        else
            : > "$_tmp" || exit 1
        fi
        printf 'TG_CF_WORKER_DOMAINS=%s\n' "$_domains" >> "$_tmp" || exit 1
        chmod 600 "$_tmp" 2>/dev/null || exit 1
        mv -f "$_tmp" "$_config"
    ) || {
        rm -f "$_tmp"; rmdir "$_lock" 2>/dev/null || true; return 1;
    }
    rmdir "$_lock" 2>/dev/null || true
    printf 'Список Worker сохранён. Применяю настройки через z2k/procd…\n'
    "${Z2K_INIT:-/etc/init.d/z2k}" reload
}

z2k_ow_tg_worker_add() { _z2k_ow_tg_worker_apply add "$1"; }
z2k_ow_tg_worker_remove() { _z2k_ow_tg_worker_apply remove "$1"; }

_z2k_ow_tg_stats_exec() { "$@" --stats; }
z2k_ow_tg_stats_json() { z2k_ow_tg_with_argv _z2k_ow_tg_stats_exec; }

_z2k_ow_tg_check_exec() {
    local _tmp="$1" _diagnostic_status
    shift
    "$@" --check > "$_tmp" 2>/dev/null
    _diagnostic_status=$?
    case "$_diagnostic_status" in
        0|2) grep -q '^{.*}' "$_tmp" || return 1; return 0 ;;
        *) return 1 ;;
    esac
}

_z2k_ow_tg_check_cleanup() {
    [ -z "${_z2k_tg_check_tmp:-}" ] || rm -f "$_z2k_tg_check_tmp"
    [ -z "${_z2k_tg_check_lock:-}" ] || rmdir "$_z2k_tg_check_lock" 2>/dev/null || true
}

z2k_ow_tg_check_action() {
    local _dir="${Z2K_TMP:-/tmp/z2k}/tg-diagnostics" _report
    _z2k_tg_check_lock="$_dir/lock"
    _report="$_dir/report.json"
    mkdir -p "$_dir" || return 1
    mkdir "$_z2k_tg_check_lock" 2>/dev/null || { echo 'диагностика Telegram уже выполняется' >&2; return 1; }
    _z2k_tg_check_tmp="$_dir/report.$$"
    trap '_z2k_ow_tg_check_cleanup' EXIT
    trap 'exit 1' HUP INT TERM
    printf '{"state":"running"}\n' > "$_z2k_tg_check_tmp" && mv -f "$_z2k_tg_check_tmp" "$_report" || return 1
    _z2k_tg_check_tmp="$_dir/result.$$"
    if ! z2k_ow_tg_with_argv _z2k_ow_tg_check_exec "$_z2k_tg_check_tmp"; then
        rm -f "$_z2k_tg_check_tmp"
        printf '{"state":"error","message":"не удалось выполнить диагностику Telegram"}\n' > "$_dir/error.$$"
        mv -f "$_dir/error.$$" "$_report"
        return 1
    fi
    mv -f "$_z2k_tg_check_tmp" "$_report"
}

z2k_ow_tg_check_json() {
    local _report="${Z2K_TMP:-/tmp/z2k}/tg-diagnostics/report.json"
    if [ -r "$_report" ]; then cat "$_report"; else printf '{"state":"not_checked"}\n'; fi
}

# API-обработчики Telegram остаются в OpenWrt-адаптере, общий CGI только
# вызывает платформенный интерфейс.
panel_tg_stats_get() {
    command -v z2k_ow_tg_stats_json >/dev/null 2>&1 \
        || json_fail "503 Service Unavailable" "статистика Telegram доступна только на OpenWrt"
    local tunnel_stats
    tunnel_stats=$(z2k_ow_tg_stats_json 2>/dev/null) \
        || json_fail "503 Service Unavailable" "процесс Telegram не вернул статистику"
    case "$tunnel_stats" in \{*\}) ;; *) json_fail "503 Service Unavailable" "ответ статистики повреждён" ;; esac
    json_header
    printf '%s\n' "$tunnel_stats"
}

panel_tg_check_get() {
    command -v z2k_ow_tg_check_json >/dev/null 2>&1 \
        || json_fail "404 Not Found" "диагностика Telegram доступна только на OpenWrt"
    json_header
    z2k_ow_tg_check_json
}

panel_tg_check_post() {
    command -v z2k_ow_tg_check_action >/dev/null 2>&1 \
        || json_fail "404 Not Found" "диагностика Telegram доступна только на OpenWrt"
    local job_id
    job_id=$(svc_action_async "Проверка маршрутов Telegram" "z2k_ow_tg_check_action") \
        || json_fail "500 Internal Server Error" "не удалось запустить диагностику Telegram"
    json_header
    printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
}

panel_tg_workers_post() {
    command -v z2k_ow_tg_worker_normalize >/dev/null 2>&1 \
        || json_fail "404 Not Found" "управление Worker доступно только на OpenWrt"
    local body worker_domain job_id
    body=$(read_body)
    worker_domain=$(form_value "$body" "domain")
    worker_domain=$(z2k_ow_tg_worker_normalize "$worker_domain") \
        || json_fail "400 Bad Request" "укажите корректный DNS-домен Worker"
    if [ "$PATH_INFO" = /tunnel/workers/add ]; then
        job_id=$(svc_action_async "Добавление Telegram Worker" "z2k_ow_tg_worker_add $worker_domain")
    else
        job_id=$(svc_action_async "Удаление Telegram Worker" "z2k_ow_tg_worker_remove $worker_domain")
    fi
    [ -n "$job_id" ] || json_fail "500 Internal Server Error" "не удалось обновить список Worker"
    json_header
    printf '{"ok":true,"job":'; json_string "$job_id"; printf '}\n'
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
        [ "$_port" -ne 80 ] || continue
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
Z2K_TG_DC_MAP_ENDPOINTS_PATH="${Z2K_TG_DC_MAP_ENDPOINTS_PATH:-$(z2k_ow_tg_cfg TG_DC_MAP_ENDPOINTS_PATH "${Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT:-$Z2K_TG_DC_MAP_ENDPOINTS_PATH}")}"
Z2K_TG_CONNECTION_MODE="${Z2K_TG_CONNECTION_MODE:-$(z2k_ow_tg_cfg TG_CONNECTION_MODE auto)}"
Z2K_TG_CONNECTION_LIMIT="${Z2K_TG_CONNECTION_LIMIT:-$(z2k_ow_tg_cfg TG_CONNECTION_LIMIT 32)}"
if [ -n "$_z2k_tg_max_connections_override" ]; then
    Z2K_TG_CONNECTION_MODE=manual
    Z2K_TG_CONNECTION_LIMIT="$_z2k_tg_max_connections_override"
fi
_z2k_tg_fd_soft="$(ulimit -n 2>/dev/null)"
_z2k_tg_mem_total="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
_z2k_tg_mem_available="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
Z2K_TG_MAX_CONNECTIONS="$(z2k_ow_tg_connection_budget \
    "$Z2K_TG_CONNECTION_MODE" "$Z2K_TG_CONNECTION_LIMIT" \
    "$_z2k_tg_fd_soft" "$_z2k_tg_mem_total" \
    "$_z2k_tg_mem_available" "$_z2k_tg_mem_available")"
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
    printf ',"workers":['
    local _sep=
    while IFS= read -r _worker; do
        [ -n "$_worker" ] || continue
        printf '%s"%s"' "$_sep" "$_worker"
        _sep=,
    done <<EOF
$(z2k_ow_tg_worker_domains)
EOF
    printf ']}'
}

z2k_ow_tg_wanted() {
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || return 1
    case "${Z2K_TG_MAX_CONNECTIONS:-0}" in ''|*[!0-9]*|0) return 1 ;; esac
    z2k_ow_tg_arch_supported || return 1
    [ -x "$Z2K_TG_RUST_BIN" ] || return 1
    [ "$(z2k_ow_tg_cfg ENABLED 1)" = "1" ] || return 1
    [ "$(z2k_ow_tg_cfg TG_PROXY_USER_DISABLED 0)" = "1" ] && return 1
    return 0
}

# Собрать аргументы единственного режима демона и передать их команде $1.
# Аргументы передаются без печати.
# Использование: z2k_ow_tg_with_argv _cb (одно слово — см. ниже).
z2k_ow_tg_with_argv() {
    local _cb="$1" _worker_domains _callback_arg="${2:-}"
    local _dc_map_path="${Z2K_TG_DC_MAP_PATH_DEFAULT:-${Z2K_TG_DC_MAP_PATH:-/tmp/z2k/telegram-dc-map.json}}"
    local _dc_map_refresh="${Z2K_TG_DC_MAP_REFRESH_SECS_DEFAULT:-21600}"
    local _dc_endpoints_path="${Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT:-${Z2K_TG_DC_MAP_ENDPOINTS_PATH:-/tmp/z2k/telegram-dc-endpoints.tsv}}"
    shift
    set -- "$Z2K_TG_RUST_BIN" "--port=$Z2K_TG_PORT" --host=:: \
        "--max-connections=$Z2K_TG_MAX_CONNECTIONS" \
        "--transparent-ports=$(z2k_ow_tg_ports_csv)" \
        "--transparent-cidrs=$(z2k_ow_tg_cidrs_csv "$Z2K_TG_CIDRS $Z2K_TG_CIDRS6")" \
        "--dc-map-path=$(z2k_ow_tg_cfg TG_DC_MAP_PATH "$_dc_map_path")" \
        "--dc-map-refresh-secs=$(z2k_ow_tg_cfg TG_DC_MAP_REFRESH_SECS "$_dc_map_refresh")" \
        "--dc-map-endpoints-path=$(z2k_ow_tg_cfg TG_DC_MAP_ENDPOINTS_PATH "$_dc_endpoints_path")" \
        --default-domains
    _worker_domains=$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS "")
    _worker_domains=$(printf '%s\n' "$_worker_domains" | tr ',' ' ' | awk '{$1=$1; gsub(/[[:space:]]+/, ","); print}')
    if [ -n "$_worker_domains" ]; then
        set -- "$@" "--cf-worker-domain=$_worker_domains"
    fi
    if [ -n "$_callback_arg" ]; then
        "$_cb" "$_callback_arg" "$@"
    else
        "$_cb" "$@"
    fi
}

# Обёртка procd: вызов из двух слов нельзя передать как один обратный вызов,
# поэтому используется функция адаптера (тесты подменяют procd_set_param).
_z2k_ow_tg_procd_command() { procd_set_param command "$@"; }

# Остановка демона выполняется через помощник, который тесты могут подменить;
# procd самостоятельно запустит процесс заново. Встроенную команду kill
# невозможно перехватить подменой PATH.
_z2k_ow_tg_kill() { kill "$@" 2>/dev/null || true; }

# Проверить, что PID принадлежит именно бинарнику, запущенному экземпляром procd.
# PID-файл может остаться после сбоя; сверка /proc/<pid>/exe исключает повторно
# использованный PID и посторонние процессы с похожим именем.
z2k_ow_tg_pids() {
    local _p _expected _actual
    [ -r "$Z2K_TG_PIDFILE" ] || return 0
    IFS= read -r _p < "$Z2K_TG_PIDFILE" || return 0
    case "$_p" in ''|*[!0-9]*) return 0 ;; esac
    _expected=$(readlink -f "$Z2K_TG_RUST_BIN" 2>/dev/null) || return 0
    _actual=$(readlink -f "$Z2K_PROC_ROOT/$_p/exe" 2>/dev/null) || return 0
    [ "$_actual" = "$_expected" ] && printf '%s\n' "$_p"
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

# p-86.17 требует старое имя при проверке архива, хотя новый runtime его не
# использует. Удаляем только созданную нами ссылку после остановки прежнего
# процесса; чужой файл или ссылку с другой целью не трогаем.
z2k_ow_tg_remove_transition_alias() {
    local _arch _alias _target _arch_file
    _arch_file="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/arch.sh"
    [ -r "$_arch_file" ] || return 0
    . "$_arch_file" || return 1
    _arch="${Z2K_OW_ARCH:-$(z2k_ow_detect_arch)}"
    _alias="$(z2k_ow_arch_bin_path "${Z2K_BIN:-/usr/lib/z2k/bin}" tg-mtproxy-client "$_arch")" || return 0
    [ -L "$_alias" ] || return 0
    _target="$(readlink "$_alias" 2>/dev/null)" || return 1
    [ "$_target" = z2k-rt-proxy ] || return 0
    rm -f "$_alias"
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

# Манифест Rust содержит только пары из проверенной карты, а не секреты.
# Отсутствующий файл означает offline bootstrap; повреждённый файл — отказ без
# изменения текущих nft-наборов. IP/порт ограничены безопасными символами.
z2k_ow_tg_manifest_mode() {
    local _file="$Z2K_TG_DC_MAP_ENDPOINTS_PATH"
    [ -e "$_file" ] || { printf '%s' bootstrap; return 0; }
    [ -f "$_file" ] || return 1
    awk -v allowed="$(z2k_ow_tg_ports_csv)" '
        BEGIN {
            count = split(allowed, ports, ",")
            for (i=1; i<=count; i++) allowed_port[ports[i]]=1
        }
        NR == 1 {
            if (NF != 3 || $1 != "z2k-tg-dc-options-v1" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $2 < 1 || $3 < 1) exit 1
            header=1; next
        }
        {
            if (NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 65535) { invalid=1; exit 1 }
            if (index($1, ":") > 0) {
                if ($1 !~ /^[[:xdigit:]:]+$/ || $1 ~ /:::/) { invalid=1; exit 1 }
            } else {
                if ($1 !~ /^[0-9.]+$/ || split($1, octets, ".") != 4) { invalid=1; exit 1 }
                for (i=1; i<=4; i++) if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) { invalid=1; exit 1 }
            }
            if ($2 == 80) next
            if (!($2 in allowed_port)) { invalid=1; exit 1 }
            pairs++
        }
        END { if (!invalid && header && pairs > 0) print "dynamic"; else exit 1 }
    ' "$_file" 2>/dev/null
}

_z2k_ow_tg_manifest_pairs() {
    local _family="$1"
    awk -v family="$_family" 'NR > 1 && $2 != 80 && ((family == 4 && index($1, ":") == 0) || (family == 6 && index($1, ":") > 0)) { print $1 " . " $2 }' \
        "$Z2K_TG_DC_MAP_ENDPOINTS_PATH"
}

_z2k_ow_tg_manifest_csv() {
    local _family="$1"
    awk -v family="$_family" '
        NR > 1 && $2 != 80 && ((family == 4 && index($1, ":") == 0) || (family == 6 && index($1, ":") > 0)) {
            if (found++) printf ", "
            printf "%s . %s", $1, $2
        }
        END { if (found) printf "\n" }
    ' "$Z2K_TG_DC_MAP_ENDPOINTS_PATH"
}

_z2k_ow_tg_pair_set_matches() {
    local _family="$1" _set="$2" _out _expected _actual
    _out=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" 2>/dev/null) || return 1
    [ -n "$_out" ] || return 1
    _expected=$(_z2k_ow_tg_manifest_pairs "$_family" | sort)
    _actual=$(printf '%s\n' "$_out" | awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /elements[[:space:]]*=/ { reading=1; sub(/^.*[{]/, "") }
        reading {
            line=$0
            if (line ~ /[}]/) { sub(/[}].*/, "", line); reading=0 }
            count=split(line, entries, ",")
            for (i=1; i<=count; i++) {
                entry=trim(entries[i])
                if (entry != "") { gsub(/[[:space:]]+[.][[:space:]]+/, " . ", entry); print entry }
            }
        }
    ' | sort)
    [ "$_expected" = "$_actual" ]
}

_z2k_ow_tg_cidr_set_matches() {
    local _set="$1" _need="$2" _out _expected _actual
    _out=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_set" 2>/dev/null) || return 1
    [ -n "$_out" ] || return 1
    _expected=$(for _v in $_need; do printf '%s\n' "$_v"; done | sort)
    _actual=$(printf '%s\n' "$_out" | awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /elements[[:space:]]*=/ { reading=1; sub(/^.*[{]/, "") }
        reading {
            line=$0
            if (line ~ /[}]/) { sub(/[}].*/, "", line); reading=0 }
            count=split(line, entries, ",")
            for (i=1; i<=count; i++) {
                entry=trim(entries[i])
                if (entry != "") print entry
            }
        }
    ' | sort)
    [ "$_expected" = "$_actual" ]
}

_z2k_ow_tg_nft_pairs_commit() {
    local _pair4 _pair6 _dc4 _dc6 _lock _rc
    mkdir -p "$Z2K_TG_HEALTH_DIR" 2>/dev/null || return 1
    _lock="$Z2K_TG_HEALTH_DIR/nft-pairs.lock"
    lock "$_lock" || return 1
    _pair4="$(_z2k_ow_tg_manifest_csv 4)"
    _pair6="$(_z2k_ow_tg_manifest_csv 6)"
    _dc4="$(_z2k_ow_tg_csv "$Z2K_TG_CIDRS")"
    _dc6="$(_z2k_ow_tg_csv "$Z2K_TG_CIDRS6")"
    {
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4"
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6"
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR4"
        printf 'flush set %s %s %s\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR6"
        printf 'add element %s %s %s { %s }\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET4" "$_dc4"
        printf 'add element %s %s %s { %s }\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_SET6" "$_dc6"
        [ -z "$_pair4" ] || printf 'add element %s %s %s { %s }\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR4" "$_pair4"
        [ -z "$_pair6" ] || printf 'add element %s %s %s { %s }\n' "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR6" "$_pair6"
    } | nft -f -
    _rc=$?
    lock -u "$_lock" || true
    return "$_rc"
}

# Синхронизировать только точные пары после обновления Rust-манифеста.
# Один nft batch обновляет обе семьи; существующие conntrack-записи не трогаются.
z2k_ow_tg_dc_map_sync() {
    local _mode
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || {
        echo "z2k-openwrt: tg: политика Telegram TCP не загружена или некорректна" >&2
        return 1
    }
    z2k_ow_tg_wanted || {
        echo "z2k-openwrt: tg: синхронизация DC-карты пропущена, Telegram proxy выключен" >&2
        return 1
    }
    _mode=$(z2k_ow_tg_manifest_mode) || {
        echo "z2k-openwrt: tg: манифест dcOption повреждён; активные nft-пары сохранены" >&2
        return 1
    }
    [ "$_mode" = dynamic ] || {
        echo "z2k-openwrt: tg: нет динамического манифеста dcOption для nft" >&2
        return 1
    }
    _z2k_ow_tg_table_ok || {
        echo "z2k-openwrt: tg: нет таблицы $Z2K_TG_NFT_FAMILY $Z2K_TG_NFT_TABLE" >&2
        return 1
    }
    _z2k_ow_tg_nft_pairs_commit || {
        echo "z2k-openwrt: tg: nft не принял атомарное обновление пар dcOption; прежние пары сохранены" >&2
        return 1
    }
    _z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" \
        && _z2k_ow_tg_pair_set_matches 6 "$Z2K_TG_PAIR6" || {
            echo "z2k-openwrt: tg: nft не подтвердил новые пары dcOption" >&2
            return 1
        }
    return 0
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
    local _port _ports _manifest_mode
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || {
        echo "z2k-openwrt: tg: политика Telegram TCP не загружена или некорректна" >&2
        return 1
    }
    _manifest_mode=$(z2k_ow_tg_manifest_mode) || {
        echo "z2k-openwrt: tg: манифест dcOption повреждён; текущая nft-политика сохранена" >&2
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
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR4" \
        '{ type ipv4_addr . inet_service; }' 2>/dev/null || true
    nft add set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_PAIR6" \
        '{ type ipv6_addr . inet_service; }' 2>/dev/null || true
    if [ "$_manifest_mode" = dynamic ]; then
        _z2k_ow_tg_nft_pairs_commit || {
            echo "z2k-openwrt: tg: nft отклонил атомарный набор dcOption; предыдущие пары сохранены" >&2
            return 1
        }
    else
        _z2k_ow_tg_nft_sets_commit || {
            echo "z2k-openwrt: tg: не удалось атомарно обновить bootstrap-наборы CIDR Telegram" >&2
            return 1
        }
    fi
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
# Точные пары применяются первыми; CIDR fallback ловит новые DC в доверенных
# сетях Telegram, которых ещё нет в карте. Оба пути принимают только TCP-порты
# из локальной политики.
    # Счётчик стоит перед terminal redirect и доступен для диагностики на роутере.
    if [ "$_manifest_mode" = dynamic ]; then
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
            ip daddr . tcp dport "@$Z2K_TG_PAIR4" counter redirect to ":$Z2K_TG_PORT" || return 1
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_PRE" \
            ip6 daddr . tcp dport "@$Z2K_TG_PAIR6" counter redirect to ":$Z2K_TG_PORT" || return 1
    fi
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
    if [ "$_manifest_mode" = dynamic ]; then
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
            ip daddr . tcp dport "@$Z2K_TG_PAIR4" counter redirect to ":$Z2K_TG_PORT" || return 1
        nft add rule "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$Z2K_TG_CHAIN_OUT" \
            ip6 daddr . tcp dport "@$Z2K_TG_PAIR6" counter redirect to ":$Z2K_TG_PORT" || return 1
    fi
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
        for _s in "$Z2K_TG_SET4" "$Z2K_TG_SET6" "$Z2K_TG_PAIR4" "$Z2K_TG_PAIR6" "$Z2K_TG_SETCDN"; do
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
    procd_set_param env "Z2K_TG_DC_MAP_SYNC=$Z2K_ROOT/platform/openwrt/tg-check.sh"
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
            z2k_ow_tg_remove_transition_alias || return 1
            z2k_ow_tg_wanted || {
                if command -v z2k_ow_tg_cron_remove >/dev/null 2>&1; then
                    z2k_ow_tg_cron_remove || echo "z2k-openwrt: не удалось удалить проверку TG из cron" >&2
                fi
                z2k_ow_tg_nft_remove
                return 0
            }
            z2k_ow_tg_nft_apply || return 1
            z2k_ow_tg_conntrack_flush
            z2k_ow_tg_start_instance || return 1
            if command -v z2k_ow_tg_cron_install >/dev/null 2>&1; then
                z2k_ow_tg_cron_install || echo "z2k-openwrt: не удалось установить проверку TG в cron" >&2
            fi
            ;;
        0)
            if command -v z2k_ow_tg_cron_remove >/dev/null 2>&1; then
                z2k_ow_tg_cron_remove || echo "z2k-openwrt: не удалось удалить проверку TG из cron" >&2
            fi
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
    local _s _c _out _need _port _match _ports _manifest_mode _name
    Z2K_TG_NFT_DRIFT_REDIRECT=0
    [ "${Z2K_TG_POLICY_LOADED:-0}" = 1 ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    _z2k_ow_tg_table_ok || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    _manifest_mode=$(z2k_ow_tg_manifest_mode) || { Z2K_TG_NFT_DRIFT_REDIRECT=0; return 1; }
    if [ "$_manifest_mode" = dynamic ]; then
        _z2k_ow_tg_pair_set_matches 4 "$Z2K_TG_PAIR4" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        _z2k_ow_tg_pair_set_matches 6 "$Z2K_TG_PAIR6" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        for _s in "$Z2K_TG_SET4:$Z2K_TG_CIDRS" "$Z2K_TG_SET6:$Z2K_TG_CIDRS6"; do
            _name=${_s%%:*}; _need=${_s#*:}
            _z2k_ow_tg_cidr_set_matches "$_name" "$_need" || {
                Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        done
    else
        for _s in "$Z2K_TG_SET4:$Z2K_TG_CIDRS" \
                  "$Z2K_TG_SET6:$Z2K_TG_CIDRS6"; do
            _name=${_s%%:*}; _need=${_s#*:}
            _out=$(nft list set "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_name" 2>/dev/null) || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            for _v in $_need; do
                printf '%s\n' "$_out" | grep -qF "${_v%/32}" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            done
        done
    fi
    for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT" "$Z2K_TG_CHAIN_IN"; do
        _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null) || {
            Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
        [ -n "$_out" ] || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
    done
    if [ "$_manifest_mode" = dynamic ]; then
        for _c in "$Z2K_TG_CHAIN_PRE" "$Z2K_TG_CHAIN_OUT"; do
            _out=$(nft list chain "$Z2K_TG_NFT_FAMILY" "$Z2K_TG_NFT_TABLE" "$_c" 2>/dev/null)
            for _match in "ip daddr . tcp dport @$Z2K_TG_PAIR4" "ip6 daddr . tcp dport @$Z2K_TG_PAIR6"; do
                printf '%s\n' "$_out" | tr -s ' ' | grep -qF "$_match counter" || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            done
            _ports=$(z2k_ow_tg_ports) || { Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
            for _port in $_ports; do
                for _match in "tcp dport $_port ip daddr @$Z2K_TG_SET4" \
                              "tcp dport $_port ip6 daddr @$Z2K_TG_SET6"; do
                    printf '%s\n' "$_out" | tr -s ' ' | grep -Eq "$_match counter( packets [0-9]+ bytes [0-9]+)? redirect to :$Z2K_TG_PORT" || {
                        Z2K_TG_NFT_DRIFT_REDIRECT=1; return 1; }
                done
            done
        done
    else
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
    fi
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
