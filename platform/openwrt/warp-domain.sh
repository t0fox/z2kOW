#!/bin/sh
# OpenWrt-only passive DNS observation and client-scoped WARP route setup.
# The observer never alters DNS packets: nft only NFLOGs ordinary IPv4 DNS
# replies directed to interfaces in firewall's LAN zone.

WARP_DOMAIN_SET="${WARP_DOMAIN_SET:-z2k_warp_domain4}"
# z2k-warpd's upstream runtime contract uses /tmp/z2k-warp. Keep the OpenWrt
# producer, observer, and API status reader on that same tmpfs directory.
WARP_DOMAIN_RULES="${WARP_DOMAIN_RULES:-/tmp/z2k-warp/domains.v1}"
WARP_DOMAIN_SNAPSHOT="${WARP_DOMAIN_SNAPSHOT:-/tmp/z2k-warp/domain-pairs.v1}"
WARP_DOMAIN_STATUS="${WARP_DOMAIN_STATUS:-/tmp/z2k-warp/domain-status.json}"
WARP_DOMAIN_ERROR="${WARP_DOMAIN_ERROR:-/tmp/z2k-warp/domain-setup-error}"
WARP_DOMAIN_NFT_FAMILY="${WARP_DOMAIN_NFT_FAMILY:-inet}"
WARP_DOMAIN_NFT_TABLE="${WARP_DOMAIN_NFT_TABLE:-z2k_warp_dns}"
WARP_DOMAIN_NFT_OUT="${WARP_DOMAIN_NFT_OUT:-z2k_dns_output}"
WARP_DOMAIN_NFT_FWD="${WARP_DOMAIN_NFT_FWD:-z2k_dns_forward}"
WARP_DOMAIN_NFLOG_GROUP="${WARP_DOMAIN_NFLOG_GROUP:-189}"
WARP_DOMAIN_FILTER="${WARP_DOMAIN_FILTER:-${Z2K_ROOT:-/usr/lib/z2k}/z2k-warp-list-filter.awk}"
WARP_DOMAIN_RUNTIME_BIN="${WARP_DOMAIN_RUNTIME_BIN:-${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/bin/z2k-warpd}"
WARP_DOMAIN_TABLE_COMMENT="z2k WARP passive DNS observer"
WARP_DOMAIN_CHAIN_COMMENT="z2k WARP passive DNS observer chain"

warp_validated_domains() {
    warp_active_lists 2>/dev/null | while IFS= read -r _f; do cat "$_f" 2>/dev/null; done |
        awk -v mode=domains -f "$WARP_DOMAIN_FILTER" 2>/dev/null | LC_ALL=C sort -u
}

warp_domain_error_set() {
    mkdir -p "$(dirname "$WARP_DOMAIN_ERROR")" 2>/dev/null || return 1
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$WARP_DOMAIN_ERROR"
    else
        rm -f "$WARP_DOMAIN_ERROR"
    fi
}

warp_domain_rules_load() {
    local _tmp="${WARP_DOMAIN_RULES}.new.$$" _count
    mkdir -p "$(dirname "$WARP_DOMAIN_RULES")" 2>/dev/null || {
        warp_domain_error_set state-dir-unavailable
        return 1
    }
    if [ ! -r "$WARP_DOMAIN_FILTER" ]; then
        printf 'v1\n' > "$_tmp" && mv -f "$_tmp" "$WARP_DOMAIN_RULES"
        warp_domain_error_set domain-filter-missing
        return 1
    fi
    { printf 'v1\n'; warp_validated_domains; } > "$_tmp" || {
        rm -f "$_tmp"
        warp_domain_error_set domain-rules-write-failed
        return 1
    }
    _count=$(awk 'END { print (NR > 0 ? NR - 1 : 0) }' "$_tmp")
    if [ "$_count" -gt 4096 ]; then
        printf 'v1\n' > "$_tmp" || { rm -f "$_tmp"; return 1; }
        warp_domain_error_set domain-rule-limit-exceeded
    else
        warp_domain_error_set ""
    fi
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$WARP_DOMAIN_RULES" || {
        rm -f "$_tmp"
        warp_domain_error_set domain-rules-publish-failed
        return 1
    }
    return 0
}

warp_domain_set_ensure() {
    _z2k_ow_warp_table_ok || { warp_domain_error_set zapret2-table-unavailable; return 1; }
    local _set
    _set=$(nft list set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_DOMAIN_SET" 2>/dev/null) || _set=""
    if [ -n "$_set" ]; then
        printf '%s\n' "$_set" | grep -qF 'comment "z2k WARP DNS pairs"' || {
            warp_domain_error_set nft-pair-set-conflict
            return 1
        }
        return 0
    fi
    nft add set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_DOMAIN_SET" \
        '{ type ipv4_addr . ipv4_addr; flags timeout; timeout 1h; size 8192; comment "z2k WARP DNS pairs"; }' >/dev/null 2>&1 || {
        warp_domain_error_set nft-pair-set-unavailable
        return 1
    }
    return 0
}

warp_domain_lan_devices() {
    if [ -n "${Z2K_WARP_DOMAIN_LAN_DEVICES:-}" ]; then
        printf '%s\n' "$Z2K_WARP_DOMAIN_LAN_DEVICES" | tr ' ' '\n' | LC_ALL=C sort -u
        return 0
    fi
    command -v uci >/dev/null 2>&1 && command -v ubus >/dev/null 2>&1 || return 0
    local _section _net _dev
    uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^.]*\|firewall\.@zone\[[0-9][0-9]*\]\)\.name='lan'$/\1/p" |
    while IFS= read -r _section; do
        [ -n "$_section" ] || continue
        for _net in $(uci -q get "$_section.network" 2>/dev/null); do
            _dev=$(ubus call "network.interface.$_net" status 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null | head -n 1)
            [ -n "$_dev" ] || _dev=$(uci -q get "network.$_net.device" 2>/dev/null)
            [ -n "$_dev" ] || _dev=$(uci -q get "network.$_net.ifname" 2>/dev/null)
            case "$_dev" in
                ''|*[!A-Za-z0-9_.:-]*) continue ;;
            esac
            [ "${#_dev}" -le 15 ] && printf '%s\n' "$_dev"
        done
    done | LC_ALL=C sort -u
}

warp_domain_chain_ensure() {
    local _chain="$1" _hook="$2" _priority="$3" _out
    if _out=$(nft list chain "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$_chain" 2>/dev/null); then
        printf '%s\n' "$_out" | grep -qF "comment \"$WARP_DOMAIN_CHAIN_COMMENT $_chain\"" || {
            warp_domain_error_set "nft-observer-chain-conflict-$_chain"
            return 1
        }
        return 0
    fi
    nft add chain "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$_chain" \
        "{ type filter hook $_hook priority $_priority; policy accept; comment \"$WARP_DOMAIN_CHAIN_COMMENT $_chain\"; }" >/dev/null 2>&1 || {
        warp_domain_error_set "nft-observer-chain-unavailable-$_chain"
        return 1
    }
    _out=$(nft list chain "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$_chain" 2>/dev/null) || {
        warp_domain_error_set "nft-observer-chain-unavailable-$_chain"
        return 1
    }
    printf '%s\n' "$_out" | grep -qF "comment \"$WARP_DOMAIN_CHAIN_COMMENT $_chain\"" || {
        warp_domain_error_set "nft-observer-chain-conflict-$_chain"
        return 1
    }
    return 0
}

warp_domain_observer_rules_apply() {
    local _dev _table
    warp_domain_rules_load >/dev/null 2>&1 || true
    _table=$(nft list table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" 2>/dev/null)
    if [ -z "$_table" ]; then
        nft add table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" \
            '{ comment "z2k WARP passive DNS observer"; }' >/dev/null 2>&1 || {
            warp_domain_error_set nft-observer-table-conflict
            return 1
        }
        _table=$(nft list table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" 2>/dev/null)
    fi
    printf '%s\n' "$_table" | grep -qF "comment \"$WARP_DOMAIN_TABLE_COMMENT\"" || {
        warp_domain_error_set nft-observer-table-conflict
        return 1
    }
    warp_domain_chain_ensure "$WARP_DOMAIN_NFT_OUT" output -150 || return 1
    warp_domain_chain_ensure "$WARP_DOMAIN_NFT_FWD" forward -150 || return 1
    local _devices
    _devices=$(warp_domain_lan_devices)
    [ -n "$_devices" ] || { warp_domain_error_set lan-device-unavailable; return 1; }
    {
        printf 'flush chain %s %s %s\n' "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_OUT"
        printf 'flush chain %s %s %s\n' "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_FWD"
        for _dev in $_devices; do
            case "$_dev" in ''|*[!A-Za-z0-9_.:-]*) continue ;; esac
            [ "${#_dev}" -le 15 ] || continue
            printf 'add rule %s %s %s oifname "%s" ip protocol { tcp, udp } th sport 53 counter log group %s snaplen 4096 queue-threshold 1\n' \
                "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_OUT" "$_dev" "$WARP_DOMAIN_NFLOG_GROUP"
            printf 'add rule %s %s %s oifname "%s" ip protocol { tcp, udp } th sport 53 counter log group %s snaplen 4096 queue-threshold 1\n' \
                "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_FWD" "$_dev" "$WARP_DOMAIN_NFLOG_GROUP"
        done
    } | nft -f - >/dev/null 2>&1 || {
        warp_domain_error_set nft-observer-rules-failed
        return 1
    }
    return 0
}

warp_domain_backend_ready() {
    local _set _table _out _fwd _rules
    [ ! -s "$WARP_DOMAIN_ERROR" ] || return 1
    _rules=$(warp_validated_domains 2>/dev/null)
    [ -n "$_rules" ] || return 1
    _set=$(nft list set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_DOMAIN_SET" 2>/dev/null) || return 1
    printf '%s\n' "$_set" | grep -qF 'comment "z2k WARP DNS pairs"' || return 1
    _table=$(nft list table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" 2>/dev/null) || return 1
    printf '%s\n' "$_table" | grep -qF "comment \"$WARP_DOMAIN_TABLE_COMMENT\"" || return 1
    _out=$(nft list chain "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_OUT" 2>/dev/null) || return 1
    _fwd=$(nft list chain "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" "$WARP_DOMAIN_NFT_FWD" 2>/dev/null) || return 1
    printf '%s\n' "$_out" | grep -qF "comment \"$WARP_DOMAIN_CHAIN_COMMENT $WARP_DOMAIN_NFT_OUT\"" || return 1
    printf '%s\n' "$_fwd" | grep -qF "comment \"$WARP_DOMAIN_CHAIN_COMMENT $WARP_DOMAIN_NFT_FWD\"" || return 1
    printf '%s\n%s\n' "$_out" "$_fwd" | grep -qF "log group $WARP_DOMAIN_NFLOG_GROUP" || return 1
    return 0
}

# The observer can start with an empty rule file and watch for a later list
# update. It must use the package-built nft backend; an upstream Keenetic
# binary is never allowed to silently fall back to per-client ipset rules.
warp_domain_observer_procd_ready() {
    local _domains
    _domains=$(warp_validated_domains 2>/dev/null)
    if [ ! -r "$WARP_DOMAIN_FILTER" ]; then
        [ -n "$_domains" ] && warp_domain_error_set domain-filter-missing
        return 1
    fi
    if [ ! -x "$WARP_DOMAIN_RUNTIME_BIN" ] || [ "$WARP_BIN" != "$WARP_DOMAIN_RUNTIME_BIN" ]; then
        [ -n "$_domains" ] && warp_domain_error_set observer-runtime-unavailable
        return 1
    fi
    if ! command -v nft >/dev/null 2>&1; then
        [ -n "$_domains" ] && warp_domain_error_set nft-unavailable
        return 1
    fi
    if [ -n "$_domains" ]; then
        warp_domain_backend_ready || {
            [ -s "$WARP_DOMAIN_ERROR" ] || warp_domain_error_set domain-backend-unavailable
            return 1
        }
    else
        warp_domain_error_set ""
    fi
    return 0
}

warp_domain_nft_remove() {
    local _full="${1:-}" _tables _table _main_table _conflict=0 _rc=0
    _tables=$(nft list tables 2>/dev/null) || return 1
    if printf '%s\n' "$_tables" | grep -qxF "table $WARP_DOMAIN_NFT_FAMILY $WARP_DOMAIN_NFT_TABLE"; then
        _table=$(nft list table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" 2>/dev/null) || return 1
        if printf '%s\n' "$_table" | grep -qF "comment \"$WARP_DOMAIN_TABLE_COMMENT\""; then
            nft delete table "$WARP_DOMAIN_NFT_FAMILY" "$WARP_DOMAIN_NFT_TABLE" >/dev/null 2>&1 || _rc=1
        else
            _conflict=1
            warp_domain_error_set nft-observer-table-conflict
        fi
    fi
    if printf '%s\n' "$_tables" | grep -qxF "table $Z2K_WARP_NFT_FAMILY $Z2K_WARP_NFT_TABLE"; then
        _main_table=$(nft list table "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" 2>/dev/null) || return 1
        if printf '%s\n' "$_main_table" | grep -Eq "^[[:space:]]*set[[:space:]]+$WARP_DOMAIN_SET[[:space:]]*\{"; then
            if printf '%s\n' "$_main_table" | grep -qF 'comment "z2k WARP DNS pairs"'; then
                if [ "$_full" = full ]; then
                    nft delete set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_DOMAIN_SET" >/dev/null 2>&1 || _rc=1
                else
                    nft flush set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_DOMAIN_SET" >/dev/null 2>&1 || _rc=1
                fi
            else
                _conflict=1
                warp_domain_error_set nft-pair-set-conflict
            fi
        fi
    fi
    if [ "$_conflict" = "1" ]; then return 1; fi
    [ "$_rc" = "0" ] && warp_domain_error_set ""
    return "$_rc"
}
