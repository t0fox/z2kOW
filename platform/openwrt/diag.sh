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

_cfg=${Z2K_CONFIG:-}
_init=${Z2K_INIT:-}
_run=${Z2K_RUN:-}
_bin=${Z2K_BIN:-}
_nfq=${Z2K_NFQWS2:-}
_warp_status=${Z2K_TMP:-}
_warp_status=$_warp_status/warp/status.json
_warp_device=${Z2K_STATE:-}
_warp_device=$_warp_device/warp/device.json

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

print_health() {
    local issues="" nfq rules warp_on tg_pid
    _add() { issues="$issues  [!] $1
"; }
    if ! "$_init" running >/dev/null 2>&1; then
        _add "сервис z2k не запущен"
    fi
    [ -f "$_run/core-ready" ] || _add "dataplane не готов: отсутствует core-ready"
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
        if [ ! -x "$_bin/z2k-warpd" ]; then
            _add "WARP: z2k-warpd отсутствует в $_bin"
        elif [ ! -s "$_warp_device" ]; then
            _add "WARP: устройство не зарегистрировано"
        elif [ ! -f "$_warp_status" ] || ! grep -q '"ready":true' "$_warp_status" 2>/dev/null; then
            _add "WARP: туннель не готов (fail-open, трафик идёт напрямую)"
        fi
    fi
    printf '=== что не так ===\n'
    if [ -n "$issues" ]; then
        printf '%b' "$issues"
    else
        printf '  явных проблем не найдено — смотри детали ниже\n'
    fi
}

print_firewall() {
    local rules qcons chains
    rules=$(nft list ruleset 2>/dev/null | grep -c 'queue flags bypass to 200' || true)
    qcons=$(grep -c ' 200 ' /proc/net/netfilter/nfnetlink_queue 2>/dev/null || true)
    chains=$(nft list ruleset 2>/dev/null | grep -cE 'z2k_(tg|rt|warp)_' || true)
    [ -n "$rules" ] || rules=0
    [ -n "$qcons" ] || qcons=0
    [ -n "$chains" ] || chains=0
    printf '\n=== firewall (nftables) ===\n'
    printf 'NFQUEUE queue rules: %s (expected 8)\n' "$rules"
    printf 'queue 200 consumers : %s\n' "$qcons"
    printf 'owned helper chains : %s\n' "$chains"
    printf 'backend             : OpenWrt nftables\n'
}

print_tunnel() {
    local tg pid listeners
    tg=$_bin/tg-mtproxy-client
    printf '\n=== telegram tunnel ===\n'
    if [ -x "$tg" ]; then
        printf 'binary            : %s (%s bytes)\n' "$tg" "$(wc -c < "$tg" 2>/dev/null | tr -d ' ')"
    else
        printf 'binary            : (not installed: %s)\n' "$tg"
    fi
    pid=$(_count_process 'tg-mtproxy-client.*--listen=:1443')
    [ -n "$pid" ] || pid=0
    printf 'process :1443      : %s\n' "$pid"
    listeners=$(netstat -lnpt 2>/dev/null | grep -cE ':1443|:1444' || true)
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
    local on bin transport endpoint ready err
    bin=$_bin/z2k-warpd
    on=$(_warp_enabled)
    transport=$(_json_field transport "$_warp_status")
    endpoint=$(_json_field endpoint "$_warp_status")
    ready=$(grep -q '"ready":true' "$_warp_status" 2>/dev/null && echo true || echo false)
    err=$(_json_field error "$_warp_status")
    printf '\n=== warp ===\n'
    if [ "$on" = 1 ]; then printf 'mode              : on\n'; else printf 'mode              : off\n'; fi
    if [ -x "$bin" ]; then printf 'engine            : installed\n'; else printf 'engine            : missing\n'; fi
    if [ -s "$_warp_device" ]; then printf 'device            : registered\n'; else printf 'device            : missing\n'; fi
    [ -n "$transport" ] || transport=unknown
    [ -n "$endpoint" ] || endpoint=unknown
    printf 'status            : ready=%s transport=%s endpoint=%s\n' "$ready" "$transport" "$endpoint"
    [ -n "$err" ] && printf 'error             : %s\n' "$err"
    printf 'status file       : %s\n' "$_warp_status"
}

print_platform() {
    local root free
    root=${Z2K_ROOT:-}
    free=$(df -h "$root" 2>/dev/null | awk 'NR==2 {printf "%s свободно из %s (занято %s)", $4, $2, $5}')
    [ -n "$free" ] || free=неизвестно
    printf '\n=== platform ===\n'
    printf 'platform           : OpenWrt\n'
    printf 'payload root       : %s\n' "$root"
    printf 'payload space      : %s\n' "$free"
    if [ -r /proc/meminfo ]; then
        printf 'memory             : %s\n' "$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END {printf "%d МБ свободно из %d", a/1024, t/1024}' /proc/meminfo 2>/dev/null)"
    fi
    printf 'loadavg            : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
}

print_offload() {
    local rules ft_decl ft_add uci_flow hw_nat fastroute modules backend conclusion
    rules=$(nft list ruleset 2>/dev/null || true)
    _ft_word=$(printf 'flow%s' 'table')
    ft_decl=$(printf '%s\n' "$rules" | grep -ciE "(^|[[:space:]])${_ft_word}([[:space:]]|\{|$)" || true)
    ft_add=$(printf '%s\n' "$rules" | grep -ciE '(^|[[:space:]])flow[[:space:]]+add([[:space:]]|$)' || true)
    uci_flow=0
    if command -v uci >/dev/null 2>&1; then
        if uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null | grep -qx '1'; then
            uci_flow=1
        fi
        if uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null | grep -qx '1'; then
            uci_flow=1
        fi
    fi
    if [ -r /proc/driver/hw_nat ]; then
        hw_nat=present
    else
        hw_nat=absent
    fi
    if [ -e /proc/sys/net/netfilter/nf_conntrack_fastroute ]; then
        fastroute=$(cat /proc/sys/net/netfilter/nf_conntrack_fastroute 2>/dev/null || echo unreadable)
    else
        fastroute=absent
    fi
    modules=$(awk '$1 ~ /^(nf_flow_table|nf_flow_table_inet|shortcut_fe|fastpath)/ {n++} END {print n+0}' /proc/modules 2>/dev/null)
    [ -n "$modules" ] || modules=0

    backend=BACKEND_UNKNOWN
    if [ "$hw_nat" = present ]; then
        backend=HARDWARE_NAT
    elif [ "$ft_decl" -gt 0 ] || [ "$ft_add" -gt 0 ] || [ "$uci_flow" -eq 1 ]; then
        backend=NFT_FLOW_TABLE
    fi
    conclusion=OFFLOAD_NOT_ACTIVE
    if [ "$ft_decl" -gt 0 ] || [ "$ft_add" -gt 0 ] || [ "$uci_flow" -eq 1 ] || [ "$hw_nat" = present ]; then
        conclusion=OFFLOAD_CONFIGURED
    fi

    printf '\n=== offload ===\n'
    printf 'software modules   : %s (nf_flow_table family)\n' "$modules"
    printf 'software offload   : %s\n' "$(if [ "$ft_decl" -gt 0 ] || [ "$ft_add" -gt 0 ] || [ "$uci_flow" -eq 1 ]; then echo active; else echo inactive; fi)"
    printf 'hardware offload   : %s\n' "$hw_nat"
    printf 'nft acceleration   : declarations=%s flow_add=%s\n' "$ft_decl" "$ft_add"
    printf 'nf_conntrack_fastroute: %s\n' "$fastroute"
    printf 'backend            : %s\n' "$backend"
    printf 'visibility         : %s\n' "$conclusion"
    printf 'conclusion         : %s\n' "$conclusion"
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
    local panel holders dns
    panel=8088
    holders=$(netstat -lntp 2>/dev/null | awk -v p=":$panel$" '$4 ~ p {print $NF; exit}')
    [ -n "$holders" ] || holders=none
    printf '\n=== network path ===\n'
    printf 'panel port         : %s\n' "$panel"
    printf 'panel listener     : %s\n' "$holders"
    dns=$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    [ -n "$dns" ] || dns=unknown
    printf 'dns servers        : %s\n' "$dns"
    if command -v nslookup >/dev/null 2>&1; then
        printf 'resolve check      : %s\n' "$(nslookup example.com 2>/dev/null | awk '/^Address[0-9]*:/{print $NF; exit}')"
    fi
}

case "$1" in
    health) print_health ;;
    firewall) print_firewall ;;
    tunnel) print_tunnel ;;
    warp) print_warp ;;
    platform) print_platform ;;
    offload) print_offload ;;
    lists) print_lists ;;
    netpath) print_netpath ;;
    *) exit 2 ;;
esac
