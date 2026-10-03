#!/bin/sh
# OpenWrt diagnostics adapter.
# The common diagnostic calls this hook for OS-specific probes (procd/nft and
# the OpenWrt runtime paths). No WARP+ material or other secrets are printed.
# shellcheck disable=SC2154  # paths/env variables are supplied by env.sh.

_root=${Z2K_ROOT:-}
[ -n "$_root" ] || exit 2
if [ -f "$_root/platform/openwrt/paths.sh" ]; then
    . "$_root/platform/openwrt/paths.sh" 2>/dev/null || true
fi
if [ -f "$_root/platform/openwrt/env.sh" ]; then
    . "$_root/platform/openwrt/env.sh" 2>/dev/null || true
fi
if [ -f "$_root/platform/openwrt/tg.sh" ]; then
    . "$_root/platform/openwrt/tg.sh" 2>/dev/null || true
fi

_cfg=${Z2K_CONFIG:-}
_init=${Z2K_INIT:-/etc/init.d/z2k}
_run=${Z2K_RUN:-}
_bin=${Z2K_BIN:-}
_nfq=${Z2K_NFQWS2:-}
_warp_status=${Z2K_TMP:-}
_warp_status=$_warp_status/warp/status.json
_warp_device=${Z2K_STATE:-}
_warp_device=$_warp_device/warp/device.json
_warp_lists=${Z2K_USER_LISTS:-/etc/z2k/user-lists}/warp
_warp_domains="${Z2K_WARP_DOMAIN_RULES:-${Z2K_WARP_TMP:-/tmp/z2k-warp}/domains.v1}"

_count_process() {
    ps w 2>/dev/null | grep -E "$1" | grep -v grep | wc -l | tr -d ' '
}

_warp_enabled() {
    grep -m1 '^GAME_WARP_ENABLED=' "$_cfg" 2>/dev/null | cut -d= -f2 | tr -d '" '
}

_tg_disabled() {
    grep -m1 '^TG_PROXY_USER_DISABLED=' "$_cfg" 2>/dev/null \
        | cut -d= -f2 | tr -d '" ' | grep -qx '1'
}

_json_field() {
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$2" 2>/dev/null | head -1
}

tg_connect_queue_failures() {
    local _log="${Z2K_TG_LOG_FILE:-/tmp/z2k-log/tg-tunnel.log}"
    if [ -r "$_log" ]; then
        tail -n 200 "$_log" 2>/dev/null | awk '/CONNECT throttled \(timeout\)/ {n++} END {print n+0}'
    elif command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -E 'z2k-tg|tg-mtproxy-client' | tail -n 200 \
            | awk '/CONNECT throttled \(timeout\)/ {n++} END {print n+0}'
    else
        printf '0\n'
    fi
}

print_health() {
    local issues="" nfq rules warp_on tg_pid _tg_queue_failures
    _add() { issues="$issues  [!] $1
"; }
    _tg_queue_failures=$(tg_connect_queue_failures)
    case "$_tg_queue_failures" in ''|*[!0-9]*) _tg_queue_failures=0 ;; esac
    if [ "$_tg_queue_failures" -gt 0 ]; then
        _add "в последних 200 строках лога телеграм-туннеля $_tg_queue_failures отказов очереди CONNECT — соединения отброшены на роутере до отправки на VPS"
    fi
    if ! "$_init" running >/dev/null 2>&1; then
        _add "сервис z2k не запущен"
    fi
    z2k_ow_core_ready || _add "dataplane не готов: PID/NFQUEUE owner или procd не подтверждены"
    [ -x "$_nfq" ] || _add "nfqws2 binary missing at $_nfq"
    nfq=$(_count_process '[/]nfqws2')
    [ -n "$nfq" ] || nfq=0
    [ "$nfq" -eq 1 ] 2>/dev/null || _add "nfqws2: процессов $nfq, ожидается ровно 1"
    rules=$(nft list ruleset 2>/dev/null | grep -c 'queue flags bypass to 200' || true)
    [ -n "$rules" ] || rules=0
    [ "$rules" -eq 8 ] 2>/dev/null || _add "NFQUEUE: правил $rules, ожидается 8"
    tg_pid=$(_count_process 'tg-mtproxy-client.*--listen=:1443')
    [ -n "$tg_pid" ] || tg_pid=0
    if ! _tg_disabled && [ "$tg_pid" -lt 1 ] 2>/dev/null; then
        _add "Telegram tunnel: процесс :1443 не запущен"
    fi
    warp_on=$(_warp_enabled)
    if [ "$warp_on" = "1" ]; then
        _warp_adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
        if [ -r "$_warp_adapter/arch.sh" ]; then
            . "$_warp_adapter/arch.sh"
            _warp_bin="$(z2k_ow_warp_bin_path "$_warp_adapter")" || _warp_bin="$_warp_adapter/bin/linux-unsupported/z2k-warpd"
        else
            _warp_bin="$_warp_adapter/bin/linux-unsupported/z2k-warpd"
        fi
        if [ ! -x "$_warp_bin" ]; then
            _add "WARP: z2k-warpd отсутствует в $_warp_bin"
        elif [ ! -s "$_warp_device" ]; then
            _add "WARP: устройство не зарегистрировано"
        elif [ ! -f "$_warp_status" ] || ! grep -q '"ready":true' "$_warp_status" 2>/dev/null; then
            _add "WARP: туннель не готов (fail-open, трафик идёт напрямую)"
        fi
        _warp_n=$(nft list set inet zapret2 z2k_warp_dst4 2>/dev/null \
            | grep -cE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
        case "$_warp_n" in ''|*[!0-9]*) _warp_n=0 ;; esac
        if [ "$_warp_n" = 0 ] \
            && ! awk 'NR>1 { found=1; exit } END { exit !found }' "$_warp_domains" 2>/dev/null \
            && ! awk '{ sub(/^[ \t]+/, ""); if ($0 != "" && $0 !~ /^#/) found=1 } END { exit !found }' \
                "$_warp_lists/devices.txt" 2>/dev/null; then
            _add "WARP включён, но списки адресов и устройства не выбраны — в туннель не направляется трафик"
        fi
    fi
    _ow_autocircular_detect
    case "$OW_AUTOCIRCULAR_STATE" in
        broken)
            _add "autocircular включён, но procd не подтверждает активный circular"
            ;;
        active)
            if [ "$OW_AUTOCIRCULAR_STATE_STORAGE" = fallback ] \
                && [ "${OW_AUTOCIRCULAR_STATE_ROWS:-0}" -gt 0 ] 2>/dev/null; then
                if [ "$OW_AUTOCIRCULAR_PRIMARY_PATH" != "$OW_AUTOCIRCULAR_PERSISTENT_PATH" ]; then
                    _add "autocircular работает, но процесс не использует OpenWrt persistent path $OW_AUTOCIRCULAR_PERSISTENT_PATH; записи находятся в fallback $OW_AUTOCIRCULAR_STATE_FILE"
                else
                    _add "autocircular работает, но сохранённые выборы находятся только в fallback $OW_AUTOCIRCULAR_STATE_FILE"
                fi
            fi
            ;;
    esac
    printf '=== что не так ===\n'
    if [ -n "$issues" ]; then
        printf '%b' "$issues"
    else
        printf '  явных проблем не найдено — смотри детали ниже\n'
    fi
}

print_service() {
    local running=down ready=not-ready pid qnum
    "$_init" running >/dev/null 2>&1 && running=running
    pid=$(cat "${Z2K_RUN:-/tmp/z2k/runtime}/nfqws2.pid" 2>/dev/null)
    qnum=${QNUM:-200}
    z2k_ow_core_ready && ready=ready
    printf '\n=== service (OpenWrt) ===\n'
    printf 'procd service      : %s\n' "$running"
    printf 'dataplane          : %s\n' "$ready"
    printf 'nfqws2 PID         : %s\n' "${pid:-none}"
    if command -v ubus >/dev/null 2>&1; then
        printf 'ubus               : available\n'
    else
        printf 'ubus               : unavailable\n'
    fi
    if [ -x /etc/init.d/network ]; then printf 'netifd             : init script present\n'; else printf 'netifd             : init script unavailable\n'; fi
    if command -v uci >/dev/null 2>&1; then printf 'UCI                : available\n'; else printf 'UCI                : unavailable\n'; fi
    printf 'NFQUEUE owner      : %s\n' "$(awk -v q="$qnum" '$1==q {print $2; found=1} END {if (!found) print "absent"}' "${Z2K_NFQUEUE_PROC:-/proc/net/netfilter/nfnetlink_queue}" 2>/dev/null)"
}

print_firewall() {
    local rules qcons chains counters tg4 tg6 tgcdn persistence
    rules=$(nft list ruleset 2>/dev/null | grep -c 'queue flags bypass to 200' || true)
    qcons=$(grep -c ' 200 ' /proc/net/netfilter/nfnetlink_queue 2>/dev/null || true)
    chains=$(nft list ruleset 2>/dev/null | grep -cE 'z2k_(tg|rt|warp)_' || true)
    counters=$(nft -a list ruleset 2>/dev/null | awk '/counter packets [0-9]+ bytes [0-9]+/ {n++} END {print n+0}')
    tg4=missing; tg6=missing; tgcdn=missing
    nft list set inet "${Z2K_ZAPRET_NFT_TABLE:-zapret2}" "${Z2K_TG_SET4:-z2k_tg_dc4}" >/dev/null 2>&1 && tg4=present
    nft list set inet "${Z2K_ZAPRET_NFT_TABLE:-zapret2}" "${Z2K_TG_SET6:-z2k_tg_dc6}" >/dev/null 2>&1 && tg6=present
    nft list set inet "${Z2K_ZAPRET_NFT_TABLE:-zapret2}" "${Z2K_TG_SETCDN:-z2k_tg_cdn4}" >/dev/null 2>&1 && tgcdn=present
    persistence=missing
    if [ -x "$_init" ] && [ -r "${Z2K_HOTPLUG_IFACE_FILE:-/etc/hotplug.d/iface/90-z2k}" ]; then
        persistence=procd+netifd-hook
    elif [ -x "$_init" ]; then
        persistence=procd-only
    fi
    local fw4 tgsets
    nft list table inet fw4 >/dev/null 2>&1 && fw4=present || fw4=missing
    tgsets=$(nft list ruleset 2>/dev/null | grep -cE 'set z2k_tg_' || true)
    [ -n "$rules" ] || rules=0
    [ -n "$qcons" ] || qcons=0
    [ -n "$chains" ] || chains=0
    printf '\n=== firewall (nftables) ===\n'
    printf 'NFQUEUE queue rules: %s (expected 8)\n' "$rules"
    printf 'queue 200 consumers : %s\n' "$qcons"
    printf 'owned helper chains : %s\n' "$chains"
    printf 'fw4 table           : %s\n' "$fw4"
    printf 'Telegram sets       : total=%s dc4=%s dc6=%s cdn4=%s\n' "${tgsets:-0}" "$tg4" "$tg6" "$tgcdn"
    printf 'persistence         : %s\n' "$persistence"
    printf 'nft rule counters   : %s\n' "${counters:-0}"
    printf 'backend             : OpenWrt nftables\n'
}

print_tunnel() {
    local tg pid listeners
    tg="${Z2K_TG_BIN:-$_bin/tg-mtproxy-client}"
    printf '\n=== telegram tunnel ===\n'
    if [ -x "$tg" ]; then
        printf 'binary            : %s (%s bytes)\n' "$tg" "$(wc -c < "$tg" 2>/dev/null | tr -d ' ')"
    else
        printf 'binary            : (not installed: %s)\n' "$tg"
    fi
    pid=$(_count_process 'tg-mtproxy-client.*--listen=:1443')
    [ -n "$pid" ] || pid=0
    printf 'process :1443      : %s\n' "$pid"
    listeners=0
    z2k_ow_tg_socket_listening "$Z2K_TG_PORT" && listeners=$((listeners + 1))
    z2k_ow_tg_socket_listening "$Z2K_TG_CDN_PORT" && listeners=$((listeners + 1))
    [ -n "$listeners" ] || listeners=0
    printf 'listeners :1443/44  : %s\n' "$listeners"
    if _tg_disabled; then
        printf 'state              : disabled\n'
    elif [ "$pid" -gt 0 ] 2>/dev/null; then
        printf 'state              : ready\n'
    else
        printf 'state              : down\n'
    fi
}

print_warp() {
    local on bin transport endpoint ready err state _adapter
    _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    if [ -r "$_adapter/arch.sh" ]; then
        . "$_adapter/arch.sh"
        bin="$(z2k_ow_warp_bin_path "$_adapter")" \
            || bin="$_adapter/bin/linux-unsupported/z2k-warpd"
    else
        bin="$_adapter/bin/linux-unsupported/z2k-warpd"
    fi
    on=$(_warp_enabled)
    printf '\n=== warp ===\n'
    case "$on" in
        0)
            printf 'mode              : off\n'
            printf 'state             : disabled\n'
            ;;
        1)
            printf 'mode              : on\n'
            if [ ! -r "$_warp_status" ]; then
                state=unavailable
                ready=unavailable
            elif grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' "$_warp_status" 2>/dev/null; then
                state=active
                ready=true
            elif grep -Eq '"ready"[[:space:]]*:[[:space:]]*false' "$_warp_status" 2>/dev/null; then
                state=inactive
                ready=false
            else
                state=unknown
                ready=unknown
            fi
            transport=$(_json_field transport "$_warp_status")
            endpoint=$(_json_field endpoint "$_warp_status")
            err=$(_json_field error "$_warp_status")
            [ -n "$transport" ] || transport=unavailable
            [ -n "$endpoint" ] || endpoint=unavailable
            printf 'state             : %s\n' "$state"
            printf 'status            : ready=%s transport=%s endpoint=%s\n' "$ready" "$transport" "$endpoint"
            [ -n "$err" ] && printf 'error             : %s\n' "$err"
            ;;
        *)
            printf 'mode              : unknown\n'
            printf 'state             : unknown\n'
            ;;
    esac
    if [ -x "$bin" ]; then printf 'engine            : installed\n'; else printf 'engine            : missing\n'; fi
    if [ -s "$_warp_device" ]; then printf 'device            : registered\n'; else printf 'device            : missing\n'; fi
    printf 'status file       : %s\n' "$_warp_status"
}

print_platform() {
    local root free overlay swap_total swap_free release_file release target arch meminfo
    root=${Z2K_ROOT:-}
    free=$(df -h "$root" 2>/dev/null | awk 'NR==2 {printf "%s свободно из %s (занято %s)", $4, $2, $5}')
    [ -n "$free" ] || free=неизвестно
    printf '\n=== platform ===\n'
    printf 'platform           : OpenWrt\n'
    printf 'payload root       : %s\n' "$root"
    printf 'payload space      : %s\n' "$free"
    release_file=${Z2K_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}
    release=$(sed -n "s/^DISTRIB_RELEASE=['\"]\{0,1\}\(.*\)['\"]\{0,1\}$/\1/p" "$release_file" 2>/dev/null \
        | head -1 | sed "s/['\"]$//")
    target=$(sed -n "s/^DISTRIB_TARGET=['\"]\{0,1\}\(.*\)['\"]\{0,1\}$/\1/p" "$release_file" 2>/dev/null \
        | head -1 | sed "s/['\"]$//")
    arch=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" {p=($3~/^[0-9]+$/)?$3+0:0; if(p>=max){max=p; arch=$2}} END{print arch}')
    [ -n "$arch" ] || arch=$(uname -m 2>/dev/null)
    printf 'OpenWrt release   : %s\n' "${release:-unknown}"
    printf 'OpenWrt target    : %s\n' "${target:-unknown}"
    printf 'OpenWrt arch      : %s\n' "${arch:-unknown}"
    overlay=$(df -h "${Z2K_OVERLAY_MOUNT:-/overlay}" 2>/dev/null | awk 'NR==2 {printf "%s free / %s (%s used)", $4,$2,$5}')
    printf 'overlay           : %s\n' "${overlay:-unavailable}"
    meminfo=${Z2K_MEMINFO:-/proc/meminfo}
    if [ -r "$meminfo" ]; then
        printf 'memory             : %s\n' "$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END {printf "%d МБ свободно из %d", a/1024, t/1024}' "$meminfo" 2>/dev/null)"
    fi
    swap_total=$(awk '/^SwapTotal:/{print $2}' "$meminfo" 2>/dev/null)
    swap_free=$(awk '/^SwapFree:/{print $2}' "$meminfo" 2>/dev/null)
    case "$swap_total:$swap_free" in
        *[!0-9:]*|:*) printf 'swap              : unavailable\n' ;;
        0:0) printf 'swap              : disabled\n' ;;
        *) printf 'swap              : %s/%s kB used\n' "$((swap_total - swap_free))" "$swap_total" ;;
    esac
    printf 'loadavg            : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
}

_ow_autocircular_configured() {
    [ -r "$_cfg" ] || return 2
    local _master
    _master=$(sed -n 's/^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null \
        | tail -1 | tr -d "'\" \t\r")
    [ "$_master" = 0 ] && return 1
    awk '
        /^NFQWS2_OPT="/ { in_opt=1; next }
        in_opt && /^"[[:space:]]*$/ { in_opt=0; next }
        in_opt && /--lua-desync=circular([:[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$_cfg" 2>/dev/null
}

_ow_autocircular_procd_pid() {
    local _json _running _pid
    command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1 || return 2
    _json=$(ubus call service list '{"name":"z2k"}' 2>/dev/null) || return 2
    [ -n "$_json" ] || return 2
    _running=$(printf '%s\n' "$_json" | jsonfilter -e '@.z2k.instances.z2k.running' 2>/dev/null)
    case "$_running" in
        true) ;;
        false) return 1 ;;
        *)
            # A valid service-list response without this instance means the
            # configured service is not registered with procd.
            case "$_json" in \{*\}) return 1 ;; *) return 2 ;; esac
            ;;
    esac
    _pid=$(printf '%s\n' "$_json" | jsonfilter -e '@.z2k.instances.z2k.pid' 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 2 ;; esac
    printf '%s' "$_pid"
}

_ow_autocircular_live() {
    local _pid _rc _proc_root _cmdline _exe
    _pid=$(_ow_autocircular_procd_pid)
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
    OW_AUTOCIRCULAR_PID="$_pid"
    _proc_root=${Z2K_DIAG_PROC_ROOT:-/proc}
    [ -r "$_proc_root/$_pid/cmdline" ] || return 2
    _cmdline=$(tr '\000' '\n' < "$_proc_root/$_pid/cmdline" 2>/dev/null) || return 2
    [ -n "$_cmdline" ] || return 2
    _exe=$(printf '%s\n' "$_cmdline" | sed -n '1p')
    [ "${_exe##*/}" = nfqws2 ] || return 1
    OW_AUTOCIRCULAR_BINARY="$_exe"
    printf '%s\n' "$_cmdline" | grep -Eq '^--lua-desync=circular([:[:space:]]|$)'
}

_ow_autocircular_proc_env() {
    local _pid="$1" _key="$2" _file="${Z2K_DIAG_PROC_ROOT:-/proc}/$1/environ"
    [ -r "$_file" ] || return 1
    tr '\000' '\n' < "$_file" 2>/dev/null | sed -n "s/^${_key}=//p" | head -1
}

_ow_autocircular_state_paths() {
    local _primary_dir _fallback_dir
    _primary_dir=
    _fallback_dir=
    if [ -r "${Z2K_DIAG_PROC_ROOT:-/proc}/$OW_AUTOCIRCULAR_PID/environ" ]; then
        _primary_dir=$(_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_STATE_DIR_OVERRIDE)
        [ -n "$_primary_dir" ] || _primary_dir=$(_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_AUTOCIRCULAR_DIR_OVERRIDE)
        _fallback_dir=$(_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE)
    fi
    if [ -z "$_primary_dir" ]; then
        local _runtime_root
        _runtime_root=${OW_AUTOCIRCULAR_BINARY%/nfq2/nfqws2}
        if [ "$_runtime_root" != "$OW_AUTOCIRCULAR_BINARY" ]; then
            _primary_dir="$_runtime_root/extra_strats/cache/autocircular"
        else
            _primary_dir="${ZAPRET2_DIR:-${Z2K_ROOT:-/usr/lib/z2k}}/extra_strats/cache/autocircular"
        fi
    fi
    [ -n "$_fallback_dir" ] || _fallback_dir=${Z2K_DIAG_AUTOCIRCULAR_DEFAULT_FALLBACK_DIR:-/tmp}
    OW_AUTOCIRCULAR_PRIMARY_PATH="$_primary_dir/state.tsv"
    OW_AUTOCIRCULAR_FALLBACK_PATH="$_fallback_dir/z2k-autocircular-state.tsv"
    return 0
}

_ow_autocircular_rows() {
    [ -r "$1" ] || { printf '0'; return 0; }
    awk -F '\t' '$1 !~ /^#/ && $1 != "pool" && NF >= 3 {n++} END {print n+0}' "$1" 2>/dev/null
}

_ow_autocircular_detect() {
    local _configured_rc _live_rc _primary_rows _fallback_rows
    OW_AUTOCIRCULAR_STATE=unknown
    OW_AUTOCIRCULAR_PID=
    OW_AUTOCIRCULAR_BINARY=
    OW_AUTOCIRCULAR_PERSISTENT_PATH="${STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/state.tsv}"
    OW_AUTOCIRCULAR_PRIMARY_PATH=
    OW_AUTOCIRCULAR_FALLBACK_PATH=
    OW_AUTOCIRCULAR_STATE_FILE=
    OW_AUTOCIRCULAR_STATE_STORAGE=none
    OW_AUTOCIRCULAR_STATE_ROWS=0

    _ow_autocircular_configured
    _configured_rc=$?
    case "$_configured_rc" in
        1) OW_AUTOCIRCULAR_STATE=disabled; return 0 ;;
        2) OW_AUTOCIRCULAR_STATE=unknown; return 0 ;;
    esac
    _ow_autocircular_live
    _live_rc=$?
    case "$_live_rc" in
        1) OW_AUTOCIRCULAR_STATE=broken; return 0 ;;
        2) OW_AUTOCIRCULAR_STATE=unavailable; return 0 ;;
    esac
    _ow_autocircular_state_paths || { OW_AUTOCIRCULAR_STATE=unavailable; return 0; }

    _primary_rows=$(_ow_autocircular_rows "$OW_AUTOCIRCULAR_PRIMARY_PATH")
    _fallback_rows=$(_ow_autocircular_rows "$OW_AUTOCIRCULAR_FALLBACK_PATH")
    if [ "${_primary_rows:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_PRIMARY_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=persistent
        OW_AUTOCIRCULAR_STATE_ROWS="$_primary_rows"
    elif [ "${_fallback_rows:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_FALLBACK_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=fallback
        OW_AUTOCIRCULAR_STATE_ROWS="$_fallback_rows"
    elif [ -r "$OW_AUTOCIRCULAR_PRIMARY_PATH" ]; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_PRIMARY_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=persistent
    elif [ -r "$OW_AUTOCIRCULAR_FALLBACK_PATH" ]; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_FALLBACK_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=fallback
    fi
    if [ "${OW_AUTOCIRCULAR_STATE_ROWS:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE=active
    else
        OW_AUTOCIRCULAR_STATE=enabled-not-observed
    fi
    return 0
}

_ow_autocircular_state() {
    _ow_autocircular_detect
    printf '%s' "$OW_AUTOCIRCULAR_STATE"
}

print_autocircular() {
    local config="${Z2K_CONFIG:-$_cfg}" _primary_status _fallback_status
    _cfg="$config"
    _ow_autocircular_detect
    printf '\n=== autocircular ===\n'
    printf 'autocircular      : %s\n' "$OW_AUTOCIRCULAR_STATE"
    case "$OW_AUTOCIRCULAR_STATE" in
        disabled)
            printf 'state file        : N/A\n'
            return 0
            ;;
        unknown)
            printf 'state file        : unknown (configuration unavailable)\n'
            return 0
            ;;
        unavailable)
            printf 'state file        : unavailable (procd or process state unreadable)\n'
            return 0
            ;;
        broken)
            printf 'state file        : N/A (runtime process is not active with circular)\n'
            return 0
            ;;
    esac
    if [ "$OW_AUTOCIRCULAR_STATE" = active ]; then
        printf 'state file        : active (%s entries; %s %s)\n' \
            "$OW_AUTOCIRCULAR_STATE_ROWS" "$OW_AUTOCIRCULAR_STATE_STORAGE" "$OW_AUTOCIRCULAR_STATE_FILE"
    else
        printf 'state file        : not-observed\n'
    fi
    _primary_status=absent; _fallback_status=absent
    [ -r "$OW_AUTOCIRCULAR_PRIMARY_PATH" ] && _primary_status=present
    [ -r "$OW_AUTOCIRCULAR_FALLBACK_PATH" ] && _fallback_status=present
    if [ "$OW_AUTOCIRCULAR_PRIMARY_PATH" = "$OW_AUTOCIRCULAR_PERSISTENT_PATH" ]; then
        printf 'persistent path   : %s (runtime primary; %s)\n' "$OW_AUTOCIRCULAR_PERSISTENT_PATH" "$_primary_status"
    else
        printf 'persistent path   : %s (not used by runtime)\n' "$OW_AUTOCIRCULAR_PERSISTENT_PATH"
        printf 'Lua primary path  : %s (%s)\n' "$OW_AUTOCIRCULAR_PRIMARY_PATH" "$_primary_status"
    fi
    printf 'fallback path     : %s (%s)\n' "$OW_AUTOCIRCULAR_FALLBACK_PATH" "$_fallback_status"
}

print_offload() {
    local mode=unknown rules nft_rc tab selective_table selective_add exemptions
    local uci_soft=unset uci_hw=unset uci_flow=0 fw4_rules fw4_flowtables
    local hw_nat fastroute modules module_file sys_modules module_dir
    local software_cap hardware_cap capability conntrack conn_rc software_state hardware_state
    local actual backend owner_conflict core_running core_ready _v queue_rules queue_packets selective_rules
    local packet_state circular_state conclusion _line _count
    tab=${Z2K_ZAPRET_NFT_TABLE:-zapret2}
    if [ -r "$_cfg" ]; then
        mode=$(sed -n 's/^[[:space:]]*FLOWOFFLOAD[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null \
            | tail -1 | sed "s/[\"']//g" | tr -d ' \t\r\n')
        [ -n "$mode" ] || mode=unknown
    fi

    rules=$(nft list ruleset 2>/dev/null)
    nft_rc=$?
    [ "$nft_rc" -eq 0 ] || rules=
    selective_table=absent
    printf '%s\n' "$rules" | grep -Eq 'table[[:space:]]+inet[[:space:]]+zapret2|flowtable[[:space:]]+ft' \
        && selective_table=present
    selective_add=$(printf '%s\n' "$rules" | grep -ciE '(^|[[:space:]])flow[[:space:]]+add[[:space:]]+@ft([[:space:]]|;|$)' || true)
    selective_rules=$(nft list chain inet "$tab" flow_offload_zapret 2>/dev/null)
    exemptions=$(printf '%s\n' "$selective_rules" | grep -ci 'direct flow offloading exemption' || true)
    fw4_rules=$(printf '%s\n' "$rules" | sed -n '/table inet fw4/,/^[[:space:]]*}/p')
    fw4_flowtables=$(printf '%s\n' "$fw4_rules" | grep -ciE '^[[:space:]]*flowtable[[:space:]]' || true)
    queue_rules=$(printf '%s\n' "$rules" | grep -ciE 'queue([[:space:]].*)?bypass to 200' || true)
    queue_packets=$(printf '%s\n' "$rules" | awk '
        /queue([[:space:]].*)?bypass to 200/ {
            line=$0
            if (match(line, /counter packets [0-9]+/)) {
                value=substr(line, RSTART, RLENGTH)
                sub(/^.* /, "", value)
                total += value
            }
        }
        END { print total+0 }
    ')

    if command -v uci >/dev/null 2>&1; then
        _v=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || true)
        [ -n "$_v" ] && uci_soft=$_v
        [ "$_v" = 1 ] && uci_flow=1
        _v=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true)
        [ -n "$_v" ] && uci_hw=$_v
        [ "$_v" = 1 ] && uci_flow=1
    fi
    if [ -r "${Z2K_HW_NAT_FILE:-/proc/driver/hw_nat}" ]; then hw_nat=present; else hw_nat=absent; fi
    if [ -e "${Z2K_FASTROUTE_FILE:-/proc/sys/net/netfilter/nf_conntrack_fastroute}" ]; then
        fastroute=$(cat "${Z2K_FASTROUTE_FILE:-/proc/sys/net/netfilter/nf_conntrack_fastroute}" 2>/dev/null || echo unreadable)
    else
        fastroute=absent
    fi
    module_file=${Z2K_PROC_MODULES:-/proc/modules}
    sys_modules=${Z2K_SYS_MODULE_DIR:-/sys/module}
    module_dir=${Z2K_MODULE_DIR:-/lib/modules/$(uname -r 2>/dev/null)}
    modules=$(awk '$1 ~ /^(nf_flow_table|nf_flow_table_inet|shortcut_fe|fastpath)/ {n++} END {print n+0}' "$module_file" 2>/dev/null)
    [ -n "$modules" ] || modules=0
    software_cap=unavailable
    if [ "$modules" -gt 0 ] 2>/dev/null || [ -d "$sys_modules/nf_flow_table" ] \
       || [ -d "$sys_modules/nf_flow_table_inet" ]; then
        software_cap=available
    elif [ ! -r "$module_file" ] && [ ! -d "$sys_modules" ] && [ ! -d "$module_dir" ]; then
        software_cap=unknown
    fi
    hardware_cap=unavailable
    [ "$hw_nat" = present ] && hardware_cap=available
    capability=unavailable
    if [ "$software_cap" = available ] || [ "$hardware_cap" = available ]; then capability=available; fi
    [ "$software_cap" = unknown ] && [ "$hardware_cap" = unavailable ] && capability=unknown

    conntrack= conn_rc=127
    if command -v conntrack >/dev/null 2>&1; then
        conntrack=$(conntrack -L 2>/dev/null); conn_rc=$?
    elif [ -r "${Z2K_CONNTRACK_FILE:-/proc/net/nf_conntrack}" ]; then
        conntrack=$(cat "${Z2K_CONNTRACK_FILE:-/proc/net/nf_conntrack}" 2>/dev/null); conn_rc=$?
    fi
    actual=not-observed
    printf '%s\n' "$conntrack" | grep -qF '[HW_OFFLOAD]' && actual=hardware
    if [ "$actual" = not-observed ] && printf '%s\n' "$conntrack" | grep -qF '[OFFLOAD]'; then actual=software; fi

    software_state=N/A
    hardware_state=N/A
    backend=N/A
    owner_conflict=N/A
    case "$mode" in
        none)
            conclusion=disabled
            packet_state=N/A
            circular_state=N/A
            ;;
        software)
            packet_state=unknown
            circular_state=$(_ow_autocircular_state)
            if [ "$nft_rc" -ne 0 ]; then
                conclusion=unavailable; software_state=unavailable; backend=unavailable; packet_state=unavailable
            elif [ "$selective_table" = absent ] || [ "$selective_add" -eq 0 ]; then
                conclusion=inactive; software_state=inactive; backend=inactive
            elif [ "$actual" = software ]; then
                conclusion=active; software_state=active; backend=NFT_FLOW_TABLE
            else
                conclusion=not-observed; software_state=not-observed; backend=NFT_FLOW_TABLE
            fi
            ;;
        hardware)
            packet_state=unknown
            circular_state=$(_ow_autocircular_state)
            if [ "$actual" = hardware ]; then
                conclusion=active; hardware_state=active; backend=HARDWARE_NAT
            elif [ "$hw_nat" = present ]; then
                conclusion=not-observed; hardware_state=not-observed; backend=HARDWARE_NAT
            else
                conclusion=unavailable; hardware_state=unavailable; backend=unavailable
            fi
            ;;
        donttouch)
            packet_state=unknown
            circular_state=$(_ow_autocircular_state)
            if [ "$actual" != not-observed ]; then
                conclusion=active
                [ "$actual" = hardware ] && backend=HARDWARE_NAT || backend=NFT_FLOW_TABLE
            elif [ "$nft_rc" -ne 0 ]; then conclusion=unavailable; backend=unavailable
            elif [ "$fw4_flowtables" -gt 0 ] || [ "$hw_nat" = present ]; then conclusion=not-observed
            else conclusion=inactive
            fi
            ;;
        *)
            conclusion=unknown; packet_state=unknown; circular_state=unknown
            ;;
    esac
    if [ "$mode" != none ] && [ "$mode" != unknown ]; then
        if [ "$nft_rc" -ne 0 ]; then packet_state=unavailable
        elif [ "$queue_rules" -eq 0 ]; then packet_state=inactive
        elif [ "$queue_packets" -gt 0 ]; then packet_state=active
        else packet_state=not-observed
        fi
    fi

    core_running=0; core_ready=0
    "$_init" running >/dev/null 2>&1 && core_running=1
    z2k_ow_core_ready >/dev/null 2>&1 && core_ready=1
    owner_conflict=none
    if [ "$mode" != none ] && { [ "$uci_flow" -eq 1 ] || [ "$fw4_flowtables" -gt 0 ]; }; then
        if [ "$selective_table" = present ] || [ "$mode" = software ] || [ "$mode" = hardware ]; then
            owner_conflict=global_fw4+zapret2
        elif [ "$core_running" = 1 ] && [ "$core_ready" = 1 ]; then
            owner_conflict=global_fw4+nfqueue
        else owner_conflict=global_fw4_only
        fi
    fi
    printf '\n=== offload ===\n'
    printf 'flowoffload mode   : %s\n' "$mode"
    printf 'offload capability : %s\n' "$capability"
    printf 'software capability: %s\n' "$software_cap"
    printf 'hardware capability: %s\n' "$hardware_cap"
    printf 'zapret2 flowtable  : %s\n' "$selective_table"
    printf 'zapret2 flow add   : %s\n' "$selective_add"
    printf 'zapret2 exemptions  : %s\n' "$exemptions"
    printf 'fw4 global UCI     : software=%s hardware=%s\n' "$uci_soft" "$uci_hw"
    printf 'fw4 nft flowtables : %s\n' "$fw4_flowtables"
    printf 'owner conflict     : %s\n' "$owner_conflict"
    printf 'software modules   : %s (nf_flow_table family)\n' "$modules"
    printf 'software offload   : %s\n' "$software_state"
    printf 'hardware offload   : %s\n' "$hardware_state"
    printf 'observed dataplane : %s\n' "$actual"
    printf 'nf_conntrack_fastroute: %s\n' "$fastroute"
    printf 'backend            : %s\n' "$backend"
    printf 'offload state      : %s\n' "$conclusion"
    printf 'packet visibility  : %s\n' "$packet_state"
    printf 'circular           : %s\n' "$circular_state"
}

print_lists() {
    local d f n label user
    d=${Z2K_EXTRA_STRATS_DIR:-}
    user=${Z2K_USER_LISTS:-}
    printf '\n=== domain lists ===\n'
    for f in "TCP/RKN/List.txt:RKN blocked (TCP)" \
             "TCP/YT/List.txt:YouTube" \
             "TCP/YT_GV/List.txt:YouTube video" \
             "UDP/YT/List.txt:YouTube QUIC" \
             "TCP/RKN/Discord.txt:Discord"; do
        label=$(printf '%s' "$f" | cut -d: -f2-)
        f=$(printf '%s' "$f" | cut -d: -f1)
        if [ -s "$d/$f" ]; then
            n=$(grep -cv '^[[:space:]]*$' "$d/$f" 2>/dev/null)
            [ -n "$n" ] || n=0
            printf '%-18s: %s domains\n' "$label" "$n"
        else
            printf '%-18s: MISSING or empty (%s)\n' "$label" "$f"
        fi
    done
    for f in extra-domains.txt whitelist.txt exclude.txt; do
        if [ -s "$user/$f" ]; then
            n=$(grep -cvE '^[[:space:]]*(#|$)' "$user/$f" 2>/dev/null)
            [ -n "$n" ] || n=0
        else
            n=0
        fi
        label=$(printf '%s' "$f" | sed 's/\.txt$//')
        printf '%-18s: %s lines\n' "$label" "$n"
    done
}

print_netpath() {
    local panel holders dns settings
    settings=${Z2K_WEBPANEL_SETTINGS_DIR:-${Z2K_ETC:-/etc/z2k}/webpanel}
    panel=$(tr -dc '0-9' < "$settings/port" 2>/dev/null)
    case "$panel" in ''|*[!0-9]*) panel=${WP_PORT_DEFAULT:-8088} ;; esac
    holders=$(netstat -lntp 2>/dev/null | awk -v p=":$panel$" '$4 ~ p {print $NF; exit}')
    [ -n "$holders" ] || holders=none
    printf '\n=== network path ===\n'
    printf 'panel port         : %s\n' "$panel"
    printf 'panel listener     : %s\n' "$holders"
    dns=$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    [ -n "$dns" ] || dns=unknown
    printf 'dns servers        : %s\n' "$dns"
    if command -v nslookup >/dev/null 2>&1; then
        local resolve_output resolve_addr resolve_rc
        resolve_output=$(nslookup example.com 2>/dev/null)
        resolve_rc=$?
        resolve_addr=$(printf '%s\n' "$resolve_output" | awk '
            /^Name:/ { answer=1; next }
            answer && /^Address([[:space:]]+[0-9]+)?:/ {
                a=$NF
                if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print a; exit }
                if (any == "") any=a
            }
            END { if (NR && !answer) exit 2; if (any != "") print any }
        ' | head -1)
        if [ -n "$resolve_addr" ]; then
            printf 'resolve check      : active example.com -> %s\n' "$resolve_addr"
        elif [ "$resolve_rc" -ne 0 ]; then
            printf 'resolve check      : inactive (no resolved address)\n'
        elif [ -z "$resolve_output" ]; then
            printf 'resolve check      : unknown (empty nslookup response)\n'
        else
            printf 'resolve check      : inactive (no resolved address)\n'
        fi
    else
        printf 'resolve check      : unavailable (nslookup missing)\n'
    fi
}

case "$1" in
    health) print_health ;;
    service) print_service ;;
    firewall) print_firewall ;;
    tunnel) print_tunnel ;;
    warp) print_warp ;;
    platform) print_platform ;;
    offload) print_offload ;;
    autocircular) print_autocircular ;;
    lists) print_lists ;;
    netpath) print_netpath ;;
    *) exit 2 ;;
esac
