#!/bin/sh
# One-shot p-85.8 Telegram UDP retirement, invoked by adapter postinst.
# Runtime Telegram support after this migration is TCP-only (ports 1443/1444).

Z2K_OW_PROC_ROOT="${Z2K_OW_PROC_ROOT:-/proc}"
Z2K_OW_CONFIG="${Z2K_OW_CONFIG:-/etc/z2k/config}"
Z2K_OW_CORE_INIT="${Z2K_OW_CORE_INIT:-/etc/init.d/z2k}"
Z2K_OW_FIREWALL="${Z2K_OW_FIREWALL:-/etc/init.d/firewall}"
Z2K_OW_IP="${Z2K_OW_IP:-ip}"
Z2K_OW_NFT="${Z2K_OW_NFT:-nft}"
Z2K_OW_TG_READY="${Z2K_OW_TG_READY:-/tmp/z2k-log/tg-udp.ready}"
Z2K_OW_LEGACY_SHELL="${Z2K_OW_LEGACY_SHELL:-/opt/bin/sh}"
Z2K_OW_LEGACY_MARKER="${Z2K_OW_LEGACY_MARKER:-${Z2K_OW_LEGACY_SHELL%/*}/.z2k-tg-udp-legacy-shell-dir-owned}"
Z2K_OW_LEGACY_SHELL_SHA256=5a25e5e8333a640768fd6aaa466e523d4256d04365bcafc233efcd5885564a95

_z2k_ow_retire_cfg() {
    local _value
    _value=$(awk -F= -v key="$1" '$1 == key { value=$2 } END { print value }' \
        "$Z2K_OW_CONFIG" 2>/dev/null | tail -n 1 | tr -d ' "\r')
    [ -n "$_value" ] && printf '%s\n' "$_value" || printf '%s\n' "$2"
}

_z2k_ow_retire_processes() {
    local _f _cmd _pid _exe
    for _f in "$Z2K_OW_PROC_ROOT"/[0-9]*/cmdline; do
        [ -r "$_f" ] || continue
        _cmd=$(tr '\000' ' ' < "$_f" 2>/dev/null)
        _exe=${_cmd%% *}
        case "${_exe##*/}" in tg-mtproxy-client) ;; *) continue ;; esac
        case " $_cmd " in *' --telegram-udp '*) _pid=${_f%/cmdline}; printf '%s\n' "${_pid##*/}" ;; esac
    done
}

_z2k_ow_retire_exact_rule() {
    "$Z2K_OW_IP" "$1" rule show 2>/dev/null | awk '
        $1 == "89:" && $2 == "from" && $3 == "all" && $4 == "fwmark" {
            n=split($5, mark, "/")
            if ((mark[1] == "0x8000000" || mark[1] == "0x08000000") &&
                (n == 1 || mark[2] == "0xffffffff") &&
                $6 == "lookup" && $7 == "988" && NF == 7) found=1
        }
        END { exit !found }
    '
}

_z2k_ow_retire_routes() {
    local _family="$1" _cidr _routes
    case "$_family" in
        -4) set -- 149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 \
            91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 \
            95.161.64.0/20 185.76.151.0/24 ;;
        -6) set -- 2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280::/32 ;;
        *) return 2 ;;
    esac
    _routes=$("$Z2K_OW_IP" "$_family" route show table 988 2>/dev/null)
    for _cidr in "$@"; do
        printf '%s\n' "$_routes" | awk -v c="$_cidr" '$1 == c && $2 == "dev" && $3 == "z2ktg0" { found=1 } END { exit !found }' || continue
        "$Z2K_OW_IP" "$_family" route del "$_cidr" dev z2ktg0 table 988 >/dev/null 2>&1 || true
    done
    printf '%s\n' "$_routes" | awk '$1 == "throw" && $2 == "default" { found=1 } END { exit !found }' || return 0
    "$Z2K_OW_IP" "$_family" route del throw default table 988 >/dev/null 2>&1 || true
}

_z2k_ow_retire_nfqueue_rules() {
    local _chain="$1" _dump _line _handle
    _dump=$("$Z2K_OW_NFT" -a list chain inet zapret2 "$_chain" 2>/dev/null) || return 0
    while IFS= read -r _line; do
        case "$_line" in
            *'@z2k_tg_udp_dc4'*'meta l4proto udp return'*'# handle '*|\
            *'@z2k_tg_udp_dc6'*'meta l4proto udp return'*'# handle '*) ;;
            *) continue ;;
        esac
        _handle=$(printf '%s\n' "$_line" | sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p')
        [ -n "$_handle" ] || continue
        "$Z2K_OW_NFT" delete rule inet zapret2 "$_chain" handle "$_handle" >/dev/null 2>&1 || true
    done <<EOF_NFT_RULES
$_dump
EOF_NFT_RULES
}

_z2k_ow_retire_owned_chain() {
    local _chain="$1" _dump _line _count=0 _owned=1
    _dump=$("$Z2K_OW_NFT" -a list chain inet zapret2 "$_chain" 2>/dev/null) || return 0
    while IFS= read -r _line; do
        case "$_line" in *'# handle '*) ;; *) continue ;; esac
        _count=$((_count + 1))
        case "$_chain:$_line" in
            z2k_tg_udp_mark:*'meta l4proto udp'*'@z2k_tg_udp_dc4'*'meta mark set 0x08000000'*|\
            z2k_tg_udp_mark:*'meta l4proto udp'*'@z2k_tg_udp_dc6'*'meta mark set 0x08000000'*) ;;
            z2k_tg_udp_fwd:*'z2ktg0'*'meta l4proto udp'*'@z2k_tg_udp_dc4'*'accept'*|\
            z2k_tg_udp_fwd:*'z2ktg0'*'meta l4proto udp'*'@z2k_tg_udp_dc6'*'accept'*) ;;
            *) _owned=0 ;;
        esac
    done <<EOF_NFT_CHAIN
$_dump
EOF_NFT_CHAIN
    [ "$_count" -gt 0 ] && [ "$_owned" = 1 ] || {
        [ "$_count" -eq 0 ] || echo "z2k-openwrt: Telegram UDP retirement left non-matching chain $_chain untouched" >&2
        return 0
    }
    "$Z2K_OW_NFT" flush chain inet zapret2 "$_chain" >/dev/null 2>&1 || return 1
    "$Z2K_OW_NFT" delete chain inet zapret2 "$_chain" >/dev/null 2>&1 || return 1
}

_z2k_ow_retire_nft() {
    local _dump _set _owned
    _dump=$("$Z2K_OW_NFT" -a list ruleset 2>/dev/null)
    _z2k_ow_retire_nfqueue_rules prenat
    _z2k_ow_retire_nfqueue_rules postnat
    _z2k_ow_retire_owned_chain z2k_tg_udp_mark || return 1
    _z2k_ow_retire_owned_chain z2k_tg_udp_fwd || return 1
    for _set in z2k_tg_udp_dc4 z2k_tg_udp_dc6; do
        _owned=$("$Z2K_OW_NFT" list set inet zapret2 "$_set" 2>/dev/null) || continue
        printf '%s\n' "$_owned" | grep -qF 'comment "z2k-openwrt: Telegram UDP"' || continue
        "$Z2K_OW_NFT" delete set inet zapret2 "$_set" >/dev/null 2>&1 || true
    done
    case "$_dump" in
        *'!z2k: Telegram UDP forwarded traffic'*)
            if [ -x "$Z2K_OW_FIREWALL" ]; then
                "$Z2K_OW_FIREWALL" reload >/dev/null 2>&1 || {
                    echo 'z2k-openwrt: Telegram UDP retirement could not reload fw4' >&2
                    return 1
                }
            fi ;;
    esac
}

_z2k_ow_retire_pbr() {
    local _family _i _tun _v4 _v6
    for _family in -4 -6; do
        for _i in 1 2 3 4; do
            _z2k_ow_retire_exact_rule "$_family" || break
            "$Z2K_OW_IP" "$_family" rule del pref 89 fwmark 0x08000000/0xffffffff table 988 >/dev/null 2>&1 || break
        done
        _z2k_ow_retire_routes "$_family"
    done
    _tun=$("$Z2K_OW_IP" -d link show dev z2ktg0 2>/dev/null)
    case "$_tun" in *'tun type tun'*)
        _v4=$("$Z2K_OW_IP" -4 route show table all 2>/dev/null | grep -F 'dev z2ktg0' || true)
        _v6=$("$Z2K_OW_IP" -6 route show table all 2>/dev/null | grep -F 'dev z2ktg0' || true)
        [ -n "$_v4$_v6" ] || "$Z2K_OW_IP" link delete dev z2ktg0 >/dev/null 2>&1 || true ;;
    esac
}

_z2k_ow_retire_config_key() {
    [ -f "$Z2K_OW_CONFIG" ] && [ ! -L "$Z2K_OW_CONFIG" ] || return 0
    grep -qE '^Z2K_TG_UDP_RELAY[[:space:]]*=' "$Z2K_OW_CONFIG" || return 0
    local _tmp="${Z2K_OW_CONFIG}.retire.$$" _data="${Z2K_OW_CONFIG}.retire-data.$$"
    cp -p "$Z2K_OW_CONFIG" "$_tmp" || return 1
    awk '!($0 ~ /^Z2K_TG_UDP_RELAY[[:space:]]*=/)' "$Z2K_OW_CONFIG" > "$_data" || {
        rm -f "$_tmp" "$_data"
        return 1
    }
    cat "$_data" > "$_tmp" || { rm -f "$_tmp" "$_data"; return 1; }
    rm -f "$_data"
    mv -f "$_tmp" "$Z2K_OW_CONFIG"
}

_z2k_ow_retire_legacy_abi() {
    [ -f "$Z2K_OW_LEGACY_MARKER" ] || return 0
    grep -Fxq 'z2k-openwrt: created for Telegram UDP legacy ABI' "$Z2K_OW_LEGACY_MARKER" || return 0
    local _sum
    if [ -f "$Z2K_OW_LEGACY_SHELL" ]; then
        _sum=$(sha256sum "$Z2K_OW_LEGACY_SHELL" 2>/dev/null | awk '{print $1}')
        [ "$_sum" = "$Z2K_OW_LEGACY_SHELL_SHA256" ] || {
            echo 'z2k-openwrt: Telegram UDP retirement left modified /opt/bin/sh untouched' >&2
            return 0
        }
        rm -f "$Z2K_OW_LEGACY_SHELL" || return 1
    fi
    rm -f "$Z2K_OW_LEGACY_MARKER" || return 1
    rmdir "${Z2K_OW_LEGACY_SHELL%/*}" 2>/dev/null || true
}

z2k_ow_tg_retire_udp() {
    local _config_key=0 _processes _snapshot _legacy=0 _was_running=0 _enabled _process _wait
    if [ -f "$Z2K_OW_CONFIG" ] && grep -qE '^Z2K_TG_UDP_RELAY[[:space:]]*=' "$Z2K_OW_CONFIG"; then
        _config_key=1
        _legacy=1
    fi
    _processes=$(_z2k_ow_retire_processes)
    [ -n "$_processes" ] && _legacy=1
    _snapshot=$("$Z2K_OW_NFT" -a list ruleset 2>/dev/null)
    case "$_snapshot" in *z2k_tg_udp_dc4*|*z2k_tg_udp_dc6*|*z2k_tg_udp_mark*|*'Telegram UDP forwarded traffic'*) _legacy=1 ;; esac
    _z2k_ow_retire_exact_rule -4 && _legacy=1
    _z2k_ow_retire_exact_rule -6 && _legacy=1
    [ -f "$Z2K_OW_TG_READY" ] && _legacy=1
    [ -f "$Z2K_OW_LEGACY_MARKER" ] && _legacy=1
    [ "$_legacy" = 1 ] || return 0

    if [ -x "$Z2K_OW_CORE_INIT" ] && "$Z2K_OW_CORE_INIT" running >/dev/null 2>&1; then
        _was_running=1
    fi
    if [ -n "$_processes" ] && [ "$_was_running" = 1 ]; then
        "$Z2K_OW_CORE_INIT" stop >/dev/null 2>&1 || true
    fi
    for _process in $_processes; do
        [ -r "$Z2K_OW_PROC_ROOT/$_process/cmdline" ] || continue
        kill -TERM "$_process" 2>/dev/null || true
    done
    for _wait in 1 2 3 4 5; do
        [ -z "$(_z2k_ow_retire_processes)" ] && break
        sleep 1
    done
    [ -z "$(_z2k_ow_retire_processes)" ] || {
        echo 'z2k-openwrt: Telegram UDP process survived bounded stop; refusing to continue migration' >&2
        return 1
    }

    _z2k_ow_retire_config_key || return 1
    _z2k_ow_retire_nft || return 1
    _z2k_ow_retire_pbr
    rm -f "$Z2K_OW_TG_READY" 2>/dev/null || true
    _z2k_ow_retire_legacy_abi || return 1

    _enabled=$(_z2k_ow_retire_cfg ENABLED 1)
    if [ "$_was_running" = 1 ] && [ "$_config_key" = 1 ] && [ "$_enabled" = 1 ]; then
        "$Z2K_OW_CORE_INIT" start || {
            echo 'z2k-openwrt: Telegram UDP retired, but previously running core could not restart TCP services' >&2
            return 1
        }
    fi
    return 0
}
