#!/bin/sh
# Единая политика прозрачного Telegram TCP для адаптера OpenWrt.
# Это bootstrap-список портов, а не обнаружение адресов Telegram.
# После help.getConfig nft получает только точные пары IP+порт из Rust-манифеста.
# Параметр TG_TCP_PORTS в OpenWrt-конфиге может заменить этот список.
# Обычный HTTP порт не включён; добавлять его можно только после отдельной
# проверки MTProto TCP/HTTP и конфликтов с обычным HTTP/CDN.
Z2K_TG_TCP_PORTS_DEFAULT="443 5222"
Z2K_TG_DC_MAP_PATH_DEFAULT="${Z2K_TG_DC_MAP_PATH_DEFAULT:-$Z2K_TG_DC_MAP_PATH}"
Z2K_TG_DC_MAP_REFRESH_SECS_DEFAULT="21600"
Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT="${Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT:-$Z2K_TG_DC_MAP_ENDPOINTS_PATH}"

# В трёх локальных WSL-прогонах на 17 потоках очередь исчезла при 32;
# 48/64 не дали устойчивого выигрыша по TTFB. Это не замеры роутера.
# Manual ограничен runtime-бюджетом и не может превышать 128.
Z2K_TG_CONNECTION_AUTO_CAP_DEFAULT="32"
Z2K_TG_CONNECTION_HARD_CAP="128"
Z2K_TG_CONNECTION_FD_PERCENT="80"
Z2K_TG_CONNECTION_FD_RESERVE="32"
Z2K_TG_CONNECTION_FD_PER_SLOT="5"
Z2K_TG_CONNECTION_MEM_PER_SLOT_KIB="1024"
Z2K_TG_CONNECTION_MEM_TOTAL_RESERVE_PERCENT="20"
Z2K_TG_CONNECTION_MEM_BASELINE_RESERVE_PERCENT="50"

z2k_ow_tg_policy_uint() {
    local _value="${1:-}"
    case "$_value" in ''|*[!0-9]*) return 1 ;; esac
    _value=$(printf '%s' "$_value" | sed 's/^0*//')
    [ -n "$_value" ] || _value=0
    case "$_value" in ???????????*) return 1 ;; esac
    printf '%s' "$_value"
}

# effective = min(FD budget, measured-memory budget, policy cap).
# Synthetic-прогон измерял proxy, клиент и mock вместе на WSL-хосте, а не
# роутерный расход на сессию. Пока 1 MiB/слот используется как запас политики;
# он требует отдельной калибровки на OpenWrt/QEMU перед аппаратной приёмкой.
# FD-резерв также является политикой, а Auto дополнительно ограничен cap=32.
z2k_ow_tg_connection_budget() {
    local _mode="${1:-auto}" _requested="${2:-32}"
    local _fd_soft="${3:-}" _mem_total="${4:-}" _mem_available="${5:-}"
    local _mem_baseline="${6:-${5:-}}" _policy_cap _fd_usable _fd_budget
    local _mem_reserve_total _mem_reserve_baseline _mem_reserve _mem_budget _effective

    _fd_soft=$(z2k_ow_tg_policy_uint "$_fd_soft") || { printf '0'; return 0; }
    _mem_total=$(z2k_ow_tg_policy_uint "$_mem_total") || { printf '0'; return 0; }
    _mem_available=$(z2k_ow_tg_policy_uint "$_mem_available") || { printf '0'; return 0; }
    _mem_baseline=$(z2k_ow_tg_policy_uint "$_mem_baseline") || { printf '0'; return 0; }
    [ "$_mem_total" -gt 0 ] || { printf '0'; return 0; }

    _policy_cap="$Z2K_TG_CONNECTION_AUTO_CAP_DEFAULT"
    case "$_mode" in
        auto) ;;
        manual)
            _requested=$(z2k_ow_tg_policy_uint "$_requested") || _requested=0
            if [ "$_requested" -ge 1 ] && [ "$_requested" -le "$Z2K_TG_CONNECTION_HARD_CAP" ]; then
                _policy_cap="$_requested"
            fi
            ;;
        *) _mode=auto ;;
    esac

    _fd_usable=$((_fd_soft * Z2K_TG_CONNECTION_FD_PERCENT / 100 - Z2K_TG_CONNECTION_FD_RESERVE))
    if [ "$_fd_usable" -gt 0 ]; then
        _fd_budget=$((_fd_usable / Z2K_TG_CONNECTION_FD_PER_SLOT))
    else
        _fd_budget=0
    fi

    _mem_reserve_total=$((_mem_total * Z2K_TG_CONNECTION_MEM_TOTAL_RESERVE_PERCENT / 100))
    _mem_reserve_baseline=$((_mem_baseline * Z2K_TG_CONNECTION_MEM_BASELINE_RESERVE_PERCENT / 100))
    if [ "$_mem_reserve_total" -gt "$_mem_reserve_baseline" ]; then
        _mem_reserve="$_mem_reserve_total"
    else
        _mem_reserve="$_mem_reserve_baseline"
    fi
    if [ "$_mem_available" -gt "$_mem_reserve" ]; then
        _mem_budget=$((($_mem_available - _mem_reserve) / Z2K_TG_CONNECTION_MEM_PER_SLOT_KIB))
    else
        _mem_budget=0
    fi

    _effective="$_policy_cap"
    [ "$_fd_budget" -ge "$_effective" ] || _effective="$_fd_budget"
    [ "$_mem_budget" -ge "$_effective" ] || _effective="$_mem_budget"
    printf '%s' "$_effective"
}

# Встроенная проверенная копия диапазонов DC для работы без обновления сети.
# Официальный help.getConfig публикует адреса DC, а не CIDR; обновление CIDR
# из неофициальных списков здесь намеренно не выполняется.
Z2K_TG_CIDRS_DEFAULT="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
Z2K_TG_CIDRS6_DEFAULT="2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280:203::/48"
