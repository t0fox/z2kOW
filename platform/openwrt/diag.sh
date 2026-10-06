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

_ow_warp_status_snapshot() {
    local _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_adapter/warp.sh" ] || return 1
    (
        Z2K_WARP_SOURCE_ONLY=1
        . "$_adapter/warp.sh" 2>/dev/null || exit 1
        warp_status
    )
}

_ow_warp_status_field() {
    local _key="$2"
    printf '%s\n' "$1" | awk -v key="$_key" '{
        for (i = 1; i <= NF; i++)
            if (index($i, key "=") == 1) { sub(/^[^=]*=/, "", $i); print $i; exit }
    }'
}

_tg_disabled() {
    grep -m1 '^TG_PROXY_USER_DISABLED=' "$_cfg" 2>/dev/null \
        | cut -d= -f2 | tr -d '" ' | grep -qx '1'
}

_json_field() {
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$2" 2>/dev/null | head -1
}

tg_connect_queue_failures() {
    local _log="${Z2K_DIAG_TUNNEL_LOG:-${Z2K_TG_LOG_FILE:-/tmp/z2k-log/tg-tunnel.log}}"
    if [ -r "$_log" ]; then
        tail -n 200 "$_log" 2>/dev/null | awk '/CONNECT throttled \(timeout\)/ {n++} END {print n+0}'
    elif command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -E 'z2k-tg|tg-mtproxy-client' | tail -n 200 \
            | awk '/CONNECT throttled \(timeout\)/ {n++} END {print n+0}'
    else
        printf '0\n'
    fi
}

print_tunnel_log() {
    command -v logread >/dev/null 2>&1 || return 0
    logread 2>/dev/null | grep -E 'z2k-tg|tg-mtproxy-client' | tail -n 200
}

_ow_diag_qnum() {
    local _q
    _q=$(sed -n 's/^[[:space:]]*QNUM[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null | tail -1 | tr -d "'\" \t\r")
    case "$_q" in ''|*[!0-9]*) _q=${QNUM:-200} ;; esac
    printf '%s' "$_q"
}

_ow_diag_queue_stats() {
    local _chain="$1" _q="$2" _rules
    _rules=$(nft list chain inet "${Z2K_ZAPRET_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}" "$_chain" 2>/dev/null) || {
        printf 'unavailable unavailable unavailable\n'; return 0;
    }
    printf '%s\n' "$_rules" | awk -v q="$_q" '
        index($0, "queue flags bypass to " q) {
            tail=substr($0, index($0, "queue flags bypass to " q) + length("queue flags bypass to " q))
            if (tail !~ /^[[:space:];#]/ && tail != "") next
            n++
            line=$0
            if (match(line, /counter packets [0-9]+ bytes [0-9]+/)) {
                c=substr(line, RSTART, RLENGTH)
                sub(/^counter packets /, "", c)
                split(c, a, " bytes ")
                packets+=a[1]; bytes+=a[2]; counted++
            }
        }
        END {
            if (!n) print "0 0 0"
            else if (counted != n) print n " unavailable unavailable"
            else print n, packets+0, bytes+0
        }'
}

_ow_diag_fw_path_state() {
    local _hook="$1" _chain="$2" _q="$3" _hook_rules _stats _count
    _hook_rules=$(nft list chain inet "${Z2K_ZAPRET_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}" "$_hook" 2>/dev/null) || {
        printf 'unavailable\n'; return 0;
    }
    printf '%s\n' "$_hook_rules" | grep -qE "(^|[[:space:]])jump[[:space:]]+$_chain([;[:space:]]|$)" || {
        printf 'unreachable\n'; return 0;
    }
    _stats=$(_ow_diag_queue_stats "$_chain" "$_q")
    _count=$(printf '%s\n' "$_stats" | awk '{print $1}')
    case "$_count" in ''|*[!0-9]*) printf 'unavailable\n' ;; *)
        [ "$_count" -gt 0 ] && printf 'reachable\n' || printf 'unreachable\n' ;;
    esac
}

_ow_diag_queue_consumer() {
    local _q="$1" _pid _cmd _proc="${Z2K_DIAG_PROC_ROOT:-/proc}"
    _pid=$(awk -v q="$_q" '$1 == q {print $2; exit}' "${Z2K_NFQUEUE_PROC:-/proc/net/netfilter/nfnetlink_queue}" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) printf 'unavailable'; return 0 ;; esac
    [ -r "$_proc/$_pid/cmdline" ] || { printf 'unavailable'; return 0; }
    _cmd=$(tr '\000' ' ' < "$_proc/$_pid/cmdline" 2>/dev/null)
    case "$_cmd" in *nfqws2*) printf 'PID %s' "$_pid" ;; *) printf 'none' ;; esac
}

_ow_diag_doh_snapshot() (
    _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_adapter/doh.sh" ] || exit 1
    . "$_adapter/doh.sh" 2>/dev/null || exit 1
    z2k_ow_doh_status 2>/dev/null
)

_ow_diag_doh_field() {
    local _status="$1" _key="$2" _item
    for _item in $_status; do
        case "$_item" in
            "$_key"=*) printf '%s' "${_item#*=}"; return 0 ;;
        esac
    done
    return 1
}

print_doh() {
    local _status _package _owner _enabled _provider _proxy _dnsmasq _force
    _status=$(_ow_diag_doh_snapshot) || _status="state=unavailable installed=0 enabled=0 provider=xbox package_owner=external proxy=unavailable dnsmasq=unavailable force_lan_dns=0"
    _package=$(_ow_diag_doh_field "$_status" installed); [ "$_package" = 1 ] && _package=installed || _package=absent
    _owner=$(_ow_diag_doh_field "$_status" package_owner); [ -n "$_owner" ] || _owner=unknown
    _enabled=$(_ow_diag_doh_field "$_status" enabled); [ "$_enabled" = 1 ] && _enabled=yes || _enabled=no
    _provider=$(_ow_diag_doh_field "$_status" provider); [ -n "$_provider" ] || _provider=unknown
    _proxy=$(_ow_diag_doh_field "$_status" proxy); [ -n "$_proxy" ] || _proxy=unavailable
    _dnsmasq=$(_ow_diag_doh_field "$_status" dnsmasq); [ -n "$_dnsmasq" ] || _dnsmasq=unavailable
    _force=$(_ow_diag_doh_field "$_status" force_lan_dns); [ "$_force" = 1 ] && _force=yes || _force=no
    printf '\nDoH:\n'
    printf '  package: %s\n  owner: %s\n  enabled: %s\n  provider: %s\n  proxy: %s\n  dnsmasq: %s\n  force_lan_dns: %s\n' \
        "$_package" "$_owner" "$_enabled" "$_provider" "$_proxy" "$_dnsmasq" "$_force"
}

print_health() {
    local issues="" nfq rules warp_on tg_pid _tg_queue_failures
    local _warp_probe _warp_runtime_ready _warp_route_ready _warp_runtime_state _qnum _out_path _in_path
    _add() { issues="$issues  [!] $1
"; }
    _tg_queue_failures=$(tg_connect_queue_failures)
    case "$_tg_queue_failures" in ''|*[!0-9]*) _tg_queue_failures=0 ;; esac
    if [ "$_tg_queue_failures" -gt 0 ]; then
        _add "в последних 200 строках лога телеграм-туннеля $_tg_queue_failures отказов очереди CONNECT — соединения отброшены на роутере до отправки на VPS"
    fi
    _qnum=$(_ow_diag_qnum)
    _out_path=$(_ow_diag_fw_path_state postnat_hook postnat "$_qnum")
    _in_path=$(_ow_diag_fw_path_state prenat_hook prenat "$_qnum")
    [ "$_out_path" = reachable ] || _add "NFQUEUE исходящий path $_out_path (postnat_hook → postnat, qnum $_qnum)"
    [ "$_in_path" = reachable ] || _add "NFQUEUE входящий path $_in_path (prenat_hook → prenat, qnum $_qnum)"
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
        else
            _warp_probe=$(_ow_warp_status_snapshot 2>/dev/null)
            _warp_runtime_ready=$(_ow_warp_status_field "$_warp_probe" ready)
            _warp_route_ready=$(_ow_warp_status_field "$_warp_probe" route_ready)
            _warp_runtime_state=$(_ow_warp_status_field "$_warp_probe" state)
            if [ "$_warp_runtime_ready" != 1 ]; then
                _add "WARP: туннель не готов (state=${_warp_runtime_state:-unavailable}, fail-open — игровой трафик идёт напрямую)"
            elif [ "$_warp_route_ready" = 0 ]; then
                _add "WARP: туннель готов, но маршрутизация OpenWrt не подтверждена — nft/TUN/PBR не доказаны, игровой трафик может идти напрямую"
            elif [ "$_warp_route_ready" != 1 ]; then
                _add "WARP: туннель готов, но состояние маршрутизации недоступно для проверки"
            fi
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
    print_doh
}

print_firewall() {
    local rules qcons chains tg4 tg6 tgcdn persistence qnum out_stats in_stats out_path in_path static_contract
    qnum=$(_ow_diag_qnum)
    out_stats=$(_ow_diag_queue_stats postnat "$qnum")
    in_stats=$(_ow_diag_queue_stats prenat "$qnum")
    out_path=$(_ow_diag_fw_path_state postnat_hook postnat "$qnum")
    in_path=$(_ow_diag_fw_path_state prenat_hook prenat "$qnum")
    qcons=$(_ow_diag_queue_consumer "$qnum")
    chains=$(nft list ruleset 2>/dev/null | grep -cE 'z2k_(tg|rt|warp)_' || true)
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
    [ -n "$chains" ] || chains=0
    . "${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt/firewall.sh" 2>/dev/null || true
    static_contract=failed
    command -v z2k_ow_fw_verify >/dev/null 2>&1 && QNUM="$qnum" z2k_ow_fw_verify >/dev/null 2>&1 && static_contract=proven
    printf '\n=== firewall (nftables) ===\n'
    printf 'NFQUEUE исходящие : %s\n' "$(printf '%s\n' "$out_stats" | awk '{print $1}')"
    printf 'NFQUEUE входящие  : %s\n' "$(printf '%s\n' "$in_stats" | awk '{print $1}')"
    printf 'OUT path           : %s (postnat_hook → postnat)\n' "$out_path"
    printf 'IN path            : %s (prenat_hook → prenat)\n' "$in_path"
    printf 'static contract    : %s (z2k_ow_fw_verify)\n' "$static_contract"
    printf 'queue %s consumer: %s\n' "$qnum" "$qcons"
    printf 'счётчики правил:\n'
    printf '  NFQUEUE OUT packets=%s bytes=%s\n' "$(printf '%s\n' "$out_stats" | awk '{print $2}')" "$(printf '%s\n' "$out_stats" | awk '{print $3}')"
    printf '  NFQUEUE IN  packets=%s bytes=%s\n' "$(printf '%s\n' "$in_stats" | awk '{print $2}')" "$(printf '%s\n' "$in_stats" | awk '{print $3}')"
    printf 'owned helper chains : %s\n' "$chains"
    printf 'fw4 table           : %s\n' "$fw4"
    printf 'Telegram sets       : total=%s dc4=%s dc6=%s cdn4=%s\n' "${tgsets:-0}" "$tg4" "$tg6" "$tgcdn"
    printf 'persistence         : %s\n' "$persistence"
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
    local on bin transport endpoint ready err state _adapter _status _route_ready _runtime_state _iface _reason
    local _edge_colo _edge_country _edge_rtt _edge_selection _entries _devices
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
            _status=$(_ow_warp_status_snapshot 2>/dev/null)
            if [ ! -r "$_warp_status" ] || [ -z "$_status" ]; then
                state=unavailable
                ready=unavailable
            else
                ready=$(_ow_warp_status_field "$_status" ready)
                _route_ready=$(_ow_warp_status_field "$_status" route_ready)
                _runtime_state=$(_ow_warp_status_field "$_status" state)
                case "$ready" in
                    1) ready=true ;;
                    0) ready=false ;;
                    *) ready=unknown ;;
                esac
                # Reuse the state machine from warp/status. A proven daemon
                # transport is only `tunnel` when OpenWrt's route projection
                # is not proven; `active` requires both proofs.
                case "$_runtime_state" in
                    error|connecting|recovering|inactive) state=$_runtime_state ;;
                    tunnel) state=tunnel ;;
                    ready|active)
                        case "$_route_ready" in
                            1) state=active ;;
                            0) state=tunnel ;;
                            *) state=unavailable ;;
                        esac
                        ;;
                    *)
                        if [ "$ready" = true ]; then
                            case "$_route_ready" in
                                1) state=active ;;
                                0) state=tunnel ;;
                                *) state=unavailable ;;
                            esac
                        elif [ "$ready" = false ]; then
                            state=inactive
                        else
                            state=unknown
                        fi
                        ;;
                esac
            fi
            transport=$(_ow_warp_status_field "$_status" transport)
            endpoint=$(_ow_warp_status_field "$_status" endpoint)
            err=$(_ow_warp_status_field "$_status" error)
            [ -n "$transport" ] || transport=unavailable
            [ -n "$endpoint" ] || endpoint=unavailable
            printf 'state             : %s\n' "$state"
            printf 'status            : ready=%s transport=%s endpoint=%s\n' "$ready" "$transport" "$endpoint"
            [ -n "$err" ] && printf 'error             : %s\n' "$err"
            if [ -r "$_adapter/warp.sh" ]; then
                # Use the same read-only predicates as the status API. This
                # distinguishes an established tunnel from proven OpenWrt PBR.
                Z2K_WARP_SOURCE_ONLY=1
                if . "$_adapter/warp.sh" 2>/dev/null; then
                    unset Z2K_WARP_SOURCE_ONLY
                    [ -n "$_route_ready" ] || _route_ready=unavailable
                    _edge_colo=$(printf '%s\n' "$_status" | sed -n 's/.* edge_colo=\([^ ]*\).*/\1/p')
                    _edge_country=$(printf '%s\n' "$_status" | sed -n 's/.* edge_country=\([^ ]*\).*/\1/p')
                    _edge_rtt=$(printf '%s\n' "$_status" | sed -n 's/.* edge_rtt_ms=\([^ ]*\).*/\1/p')
                    _edge_selection=$(printf '%s\n' "$_status" | sed -n 's/.* edge_selection=\([^ ]*\).*/\1/p')
                    _entries=$(_ow_warp_status_field "$_status" entries)
                    _devices=$(_ow_warp_status_field "$_status" devices)
                    [ -n "$_entries" ] || _entries=unavailable
                    [ -n "$_devices" ] || _devices=unavailable
                    [ -n "$_edge_colo" ] || _edge_colo=unavailable
                    [ -n "$_edge_country" ] || _edge_country=unavailable
                    case "$_edge_rtt" in ''|0) _edge_rtt=unavailable ;; esac
                    [ -n "$_edge_selection" ] || _edge_selection=unavailable
                    warp_status_routing_proofs >/dev/null 2>&1 || true
                    printf 'route_ready       : %s\n' "$_route_ready"
                    printf 'TUN interface      : %s\n' "${WARP_ROUTE_INTERFACE:-unavailable}"
                    printf 'nft mark path     : %s\n' "${WARP_ROUTE_NFT_MARK:-unavailable}"
                    printf 'TUN dataplane      : %s\n' "${WARP_ROUTE_TUN:-unavailable}"
                    printf 'PBR rule+route     : %s\n' "${WARP_ROUTE_PBR:-unavailable}"
                    printf 'PBR owner record   : %s\n' "${WARP_ROUTE_OWNER:-unavailable}"
                    printf 'selected sets      : destinations=%s devices=%s\n' "$_entries" "$_devices"
                    if [ "$_route_ready" = 1 ]; then
                        _reason=confirmed
                    elif [ "$ready" != true ]; then
                        _reason='transport proof incomplete'
                    else
                        _iface="$(_warp_live_iface)"
                        if ! _warp_proven_ready; then
                            _reason='live tunnel process or interface is not proven'
                        elif ! warp_nft_tun_verify "$_iface" >/dev/null 2>&1; then
                            _reason='nft/tun rules absent or inconsistent'
                        elif ! warp_pbr_verify >/dev/null 2>&1; then
                            _reason='policy route/rules absent, duplicated, or inconsistent'
                        elif ! warp_pbr_owner_verify "$_iface" >/dev/null 2>&1; then
                            _reason='OpenWrt route ownership record absent or inconsistent'
                        else
                            _reason='route status changed during diagnostic probe'
                        fi
                    fi
                    printf 'routing reason   : %s\n' "$_reason"
                    printf 'edge             : colo=%s country=%s rtt_ms=%s selection=%s\n' \
                        "$_edge_colo" "$_edge_country" "$_edge_rtt" "$_edge_selection"
                else
                    unset Z2K_WARP_SOURCE_ONLY
                    printf 'route_ready       : unavailable\n'
                    printf 'routing reason   : OpenWrt WARP probe could not be loaded\n'
                fi
            else
                printf 'route_ready       : unavailable\n'
                printf 'routing reason   : OpenWrt WARP probe is unavailable\n'
            fi
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
    arch=${Z2K_OPENWRT_ARCH:-$(awk -F= '$1=="DISTRIB_ARCH" {gsub(/["\047]/, "", $2); print $2; exit}' "$release_file" 2>/dev/null)}
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

print_insta() {
    local _adapter _refresh _dns _records _managed _runtime _cfgfile _cfg_seen _process
    _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    if [ ! -r "$_adapter/insta-ip.sh" ]; then
        printf 'dnsmasq addnhosts: unavailable (OpenWrt adapter missing)\n'
        return 0
    fi
    . "$_adapter/insta-ip.sh" || {
        printf 'dnsmasq addnhosts: unavailable (adapter could not load)\n'
        return 0
    }
    _refresh=$(sed -n 's/^[[:space:]]*Z2K_INSTA_IP_REFRESH[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null \
        | tail -1 | tr -d "'\" \t\r")
    _dns=$(sed -n 's/^[[:space:]]*Z2K_INSTA_DNS[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null \
        | tail -1 | tr -d "'\" \t\r")
    if [ "$_dns" = 0 ]; then
        printf 'dnsmasq addnhosts: disabled by user (static Insta/WhatsApp pins off)\n'
    elif ! command -v "$Z2K_INSTA_UCI_BIN" >/dev/null 2>&1; then
        printf 'dnsmasq addnhosts: unavailable (uci missing)\n'
    elif z2k_ow_insta_registered; then
        _records=$(z2k_ow_insta_show_running_config | awk 'NF {n++} END {print n+0}')
        _managed=$(awk -F'"' '/^HOSTS="/ {n=split($2, hosts, /[[:space:]]+/); print n; exit}' \
            "${Z2K_INSTA_REFRESH_SCRIPT:-${Z2K_ROOT:-/usr/lib/z2k}/z2k-insta-ip-refresh.sh}" 2>/dev/null)
        case "$_managed" in ''|*[!0-9]*) _managed=unknown ;; esac
        _runtime=unavailable
        _process=0
        ps w 2>/dev/null | grep -E '[d]nsmasq' >/dev/null && _process=1
        if [ "$_process" = 0 ]; then
            _runtime=inactive
        else
            _cfg_seen=0
            for _cfgfile in ${Z2K_INSTA_DNSMASQ_RUNTIME_CONFIGS:-/var/etc/dnsmasq.conf.*}; do
                [ -r "$_cfgfile" ] || continue
                _cfg_seen=1
                if grep -F -x "addn-hosts=$Z2K_INSTA_HOSTS_FILE" "$_cfgfile" >/dev/null 2>&1; then
                    _runtime=active
                    break
                fi
            done
            [ "$_runtime" = active ] || { [ "$_cfg_seen" = 1 ] && _runtime=not-observed; }
        fi
        printf 'dnsmasq addnhosts: registered; %s records; runtime=%s; managed hostnames=%s\n' \
            "${_records:-0}" "$_runtime" "$_managed"
    else
        printf 'dnsmasq addnhosts: unregistered; no active OpenWrt DNS pin configuration\n'
    fi
    case "$_refresh" in
        0) printf 'Insta IP refresh  : disabled by user\n' ;;
        1) printf 'Insta IP refresh  : enabled\n' ;;
        *) printf 'Insta IP refresh  : not-observed\n' ;;
    esac
}

print_insta_records() {
    local _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_adapter/insta-ip.sh" ] || return 0
    . "$_adapter/insta-ip.sh" || return 0
    z2k_ow_insta_show_running_config
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
    local config="${Z2K_CONFIG:-$_cfg}" mode="${1:-full}" _primary_status _fallback_status _rows
    _cfg="$config"
    _ow_autocircular_detect
    printf '\n=== autocircular state ===\n'
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
        printf 'tracked entries   : %s\n' "$OW_AUTOCIRCULAR_STATE_ROWS"
        _rows=10
        [ "$mode" = report ] && _rows=40
        printf '(first %s rows: key / host / strategy / ts)\n' "$_rows"
        awk -F '\t' '$1 !~ /^#/ && $1 != "pool" && NF >= 3 {print; n++; if (n >= limit) exit}' \
            limit="$_rows" "$OW_AUTOCIRCULAR_STATE_FILE" 2>/dev/null
        if [ "$OW_AUTOCIRCULAR_STATE_ROWS" -gt "$_rows" ] 2>/dev/null; then
            printf '... %s more rows\n' "$((OW_AUTOCIRCULAR_STATE_ROWS - _rows))"
        fi
    else
        printf 'state file        : not-observed\n'
        printf 'tracked entries   : 0 (not observed)\n'
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
    # A live conntrack flag is stronger evidence than a missing vendor-specific
    # capability file: runtime offload proves the corresponding path exists.
    [ "$actual" = hardware ] && hardware_cap=available
    [ "$actual" = software ] && software_cap=available
    capability=unavailable
    if [ "$software_cap" = available ] || [ "$hardware_cap" = available ]; then
        capability=available
    elif [ "$software_cap" = unknown ] && [ "$hardware_cap" = unavailable ]; then
        capability=unknown
    fi

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
    doh) print_doh ;;
    firewall) print_firewall ;;
    tunnel) print_tunnel ;;
    warp) print_warp ;;
    platform) print_platform ;;
    insta) print_insta ;;
    insta-records) print_insta_records ;;
    offload) print_offload ;;
    autocircular) print_autocircular "${2:-full}" ;;
    lists) print_lists ;;
    netpath) print_netpath ;;
    tunnel-log) print_tunnel_log ;;
    *) exit 2 ;;
esac
