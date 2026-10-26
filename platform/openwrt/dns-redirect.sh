#!/bin/sh
# Перенаправление обычных DNS-запросов LAN на локальный резолвер OpenWrt.

_z2k_dns_root="${Z2K_ROOT:-/usr/lib/z2k}"
[ -r "$_z2k_dns_root/platform/openwrt/paths.sh" ] && . "$_z2k_dns_root/platform/openwrt/paths.sh"
[ -r "${Z2K_CONFIG:-/etc/z2k/config}" ] && . "${Z2K_CONFIG:-/etc/z2k/config}"

Z2K_DNS_NFT_TABLE="${Z2K_DNS_NFT_TABLE:-z2k_dns_redirect}"
Z2K_DNS_STATE_DIR="${Z2K_DNS_STATE_DIR:-${Z2K_TMP:-/tmp/z2k}/dns-redirect}"

_z2k_dns_routes() {
    ip -4 route show scope link 2>/dev/null | awk '
        $1 ~ /^[0-9.]+\/[0-9]+$/ {
            dev=""
            for (i=1; i<NF; i++) if ($i == "dev") { dev=$(i+1); break }
            if (dev ~ /^br[A-Za-z0-9_.-]*$/) print $1, dev
        }
    '
}

_z2k_dns_resolver_ready() {
    command -v nslookup >/dev/null 2>&1 || return 1
    local _out _query _rc
    # Уникальное имя обходит кэш: проверяем ответ резолвера с апстрима, а не
    # наличие старой записи example.com. NXDOMAIN — валидный ответ DNS.
    _query="z2k-hc-$(date +%s 2>/dev/null)-$$.example.com"
    _out=$(nslookup -timeout=2 -retry=1 "$_query" 127.0.0.1 2>&1)
    _rc=$?
    printf '%s\n' "$_out" | grep -Eqi 'SERVFAIL|timed out|no servers could be reached|connection refused' && return 1
    if [ "$_rc" -eq 0 ]; then
        printf '%s\n' "$_out" | grep -Eqi 'Name:|NXDOMAIN|Non-existent domain'
        return $?
    fi
    printf '%s\n' "$_out" | grep -Eqi 'NXDOMAIN|Non-existent domain'
}

z2k_ow_dns_remove() {
    if nft list table inet "$Z2K_DNS_NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$Z2K_DNS_NFT_TABLE" >/dev/null 2>&1 || return 1
    fi
    rm -f "$Z2K_DNS_STATE_DIR/signature" 2>/dev/null
    return 0
}

z2k_ow_dns_apply() {
    local _routes _signature _current _script _nets _dev _expected _actual
    _routes=$(_z2k_dns_routes)
    [ -n "$_routes" ] || { z2k_ow_dns_remove; return 0; }
    _signature=$(printf '%s\n' "$_routes" | cksum | awk '{print $1 ":" $2}')
    _current=$(cat "$Z2K_DNS_STATE_DIR/signature" 2>/dev/null)
    _nets=$(printf '%s\n' "$_routes" | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    _expected=$(printf '%s\n' "$_routes" | awk '{seen[$2]=1} END {for (dev in seen) n++; print n*2}')
    _actual=$(nft list table inet "$Z2K_DNS_NFT_TABLE" 2>/dev/null | grep -c 'redirect to :53' || true)
    if [ "$_signature" = "$_current" ] && [ "$_actual" -ge "$_expected" ] 2>/dev/null; then return 0; fi
    mkdir -p "$Z2K_DNS_STATE_DIR" 2>/dev/null || return 1
    _script="$Z2K_DNS_STATE_DIR/rules.$$.nft"
    {
        printf 'add table inet %s\n' "$Z2K_DNS_NFT_TABLE"
        printf 'add chain inet %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$Z2K_DNS_NFT_TABLE"
        for _dev in $(printf '%s\n' "$_routes" | awk '{print $2}' | sort -u); do
            case "$_dev" in *[!A-Za-z0-9_.-]*) continue ;; esac
            printf 'add rule inet %s prerouting iifname "%s" ip daddr != { %s, 127.0.0.0/8 } udp dport 53 counter redirect to :53 comment "z2k DNS redirect"\n' "$Z2K_DNS_NFT_TABLE" "$_dev" "$_nets"
            printf 'add rule inet %s prerouting iifname "%s" ip daddr != { %s, 127.0.0.0/8 } tcp dport 53 counter redirect to :53 comment "z2k DNS redirect"\n' "$Z2K_DNS_NFT_TABLE" "$_dev" "$_nets"
        done
    } > "$_script" || { rm -f "$_script"; return 1; }
    if nft list table inet "$Z2K_DNS_NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$Z2K_DNS_NFT_TABLE" >/dev/null 2>&1 || { rm -f "$_script"; return 1; }
    fi
    if ! nft -f "$_script" >/dev/null 2>&1; then
        rm -f "$_script"
        return 1
    fi
    rm -f "$_script"
    printf '%s\n' "$_signature" > "$Z2K_DNS_STATE_DIR/signature.new.$$" \
        && mv -f "$Z2K_DNS_STATE_DIR/signature.new.$$" "$Z2K_DNS_STATE_DIR/signature"
}

z2k_ow_dns_sync() {
    [ "${ENABLED:-1}" = 1 ] && [ "${INIT_APPLY_FW:-1}" = 1 ] \
        && [ "${Z2K_DNS_REDIRECT:-1}" = 1 ] \
        && [ -f "${Z2K_CORE_READY:-${Z2K_RUN:-/tmp/z2k/runtime}/core-ready}" ] \
        || { z2k_ow_dns_remove; return 0; }

    if ! _z2k_dns_resolver_ready; then
        local _fail
        _fail=$(cat "$Z2K_DNS_STATE_DIR/failures" 2>/dev/null)
        case "$_fail" in ''|*[!0-9]*) _fail=0 ;; esac
        _fail=$((_fail + 1))
        mkdir -p "$Z2K_DNS_STATE_DIR" 2>/dev/null || return 1
        rm -f "$Z2K_DNS_STATE_DIR/successes"
        printf '%s\n' "$_fail" > "$Z2K_DNS_STATE_DIR/failures"
        if [ "$_fail" -ge 2 ]; then
            : > "$Z2K_DNS_STATE_DIR/paused"
            z2k_ow_dns_remove
            logger -t z2k-dns 'резолвер OpenWrt не отвечает; перенаправление DNS приостановлено' 2>/dev/null || true
        fi
        return 0
    fi

    mkdir -p "$Z2K_DNS_STATE_DIR" 2>/dev/null || return 1
    rm -f "$Z2K_DNS_STATE_DIR/failures"
    if [ -f "$Z2K_DNS_STATE_DIR/paused" ]; then
        local _success
        _success=$(cat "$Z2K_DNS_STATE_DIR/successes" 2>/dev/null)
        case "$_success" in ''|*[!0-9]*) _success=0 ;; esac
        _success=$((_success + 1))
        printf '%s\n' "$_success" > "$Z2K_DNS_STATE_DIR/successes"
        [ "$_success" -ge 2 ] || return 0
        rm -f "$Z2K_DNS_STATE_DIR/paused" "$Z2K_DNS_STATE_DIR/successes"
        logger -t z2k-dns 'резолвер OpenWrt снова отвечает; перенаправление DNS восстановлено' 2>/dev/null || true
    fi
    z2k_ow_dns_apply
}

z2k_ow_dns_check() { z2k_ow_dns_sync; }

case "${1:-}" in
    sync|check) z2k_ow_dns_sync ;;
    remove) z2k_ow_dns_remove ;;
    reset)
        rm -f "$Z2K_DNS_STATE_DIR/paused" "$Z2K_DNS_STATE_DIR/failures" "$Z2K_DNS_STATE_DIR/successes"
        z2k_ow_dns_sync
        ;;
    *) echo 'usage: dns-redirect.sh {sync|check|remove}' >&2; exit 2 ;;
esac
