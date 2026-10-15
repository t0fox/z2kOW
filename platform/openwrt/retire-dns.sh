#!/bin/sh
# One-time compatibility cleanup for installations created before removal of
# the integrated DNS editor. Never install/remove/stop any resolver package.
_state="${Z2K_STATE:-/etc/z2k/state}"
[ -d "$_state" ] && [ ! -L "$_state" ] || exit 0
_route="$_state/.dnsproxy-dnsmasq-snapshot"
_redirect="$_state/.dnsproxy-lan-redirect-owned"
[ -s "$_route" ] || [ -s "$_redirect" ] || exit 0
_uci_bin="${Z2K_DNS_RETIRE_UCI_BIN:-uci}"
_dnsmasq_init="${Z2K_DNS_RETIRE_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
_fw_init="${Z2K_DNS_RETIRE_FIREWALL_INIT:-/etc/init.d/firewall}"
_fw4_bin="${Z2K_DNS_RETIRE_FW4_BIN:-fw4}"
_lookup_bin="${Z2K_DNS_RETIRE_NSLOOKUP_BIN:-nslookup}"
_upstream='127.0.0.1#5353'
_key='dhcp.@dnsmasq[0]'
_warn() { printf 'z2kow: old DNS cleanup: %s\n' "$*" >&2; }
_uci() { "$_uci_bin" -q "$@"; }
_get() { _uci get "$1" 2>/dev/null; }
_snapshot() { sed -n "s/^$2=//p" "$1" | sed -n '1p'; }
_has_route() {
    _uci show dhcp 2>/dev/null | awk -F= -v key="$_key.server" -v want="$_upstream" '
    $1==key {
        value=substr($0,index($0,"=")+1);gsub(/\047/," ",value)
        n=split(value,parts,/[[:space:]]+/)
        for(i=1;i<=n;i++)if(parts[i]==want)found=1
    } END {exit !found}'
}
_probe() {
    _answer=$("$_lookup_bin" example.com 127.0.0.1 2>/dev/null) || return 1
    printf '%s\n' "$_answer" | grep -Eq 'Address([[:space:]]+[0-9]+)?:[[:space:]]*([0-9]{1,3}\.){3}[0-9]{1,3}'
}
_restore_active_route() {
    _has_route || _uci add_list "$_key.server=$_upstream" || return 1
    _uci set "$_key.noresolv=1" || return 1
    _uci commit dhcp || return 1
    "$_dnsmasq_init" restart
}
_retire_route() {
    [ -s "$_route" ] || return 0
    _old_noresolv=$(_snapshot "$_route" noresolv)
    _preexisting=$(_snapshot "$_route" route_preexisting)
    case "$_old_noresolv" in __unset__|-1|0|1) ;; *) _warn 'invalid saved noresolv; preserving DNS'; return 1 ;; esac
    case "$_preexisting" in
        1) _warn 'pre-existing dnsproxy route remains independently managed'; return 0 ;;
        0) ;;
        *) _warn 'invalid route ownership; preserving DNS'; return 1 ;;
    esac
    # Preserve external configuration and legacy https-dns-proxy cutovers.
    if [ -s "$_state/.dnsproxy-config-backup" ] || [ -s "$_state/.dnsproxy-legacy-route-txn" ]; then
        _warn 'saved external resolver configuration; preserving DNS'
        return 1
    fi
    if [ -s "$_state/.dnsproxy-config-baseline" ]; then
        _current=$(_uci export dnsproxy 2>/dev/null) || return 1
        _baseline=$(cat "$_state/.dnsproxy-config-baseline") || return 1
        if [ "$_current" != "$_baseline" ]; then
            _warn 'dnsproxy configuration was edited; preserving DNS'
            return 1
        fi
    fi
    if ! _has_route || [ "$(_get "$_key.noresolv")" != 1 ]; then
        _warn 'dnsmasq differs from saved owned snapshot; preserving DNS'
        return 1
    fi
    _uci del_list "$_key.server=$_upstream" || return 1
    case "$_old_noresolv" in
        __unset__|-1) _uci delete "$_key.noresolv" || { _restore_active_route; return 1; } ;;
        *) _uci set "$_key.noresolv=$_old_noresolv" || { _restore_active_route; return 1; } ;;
    esac
    if ! _uci commit dhcp || ! "$_dnsmasq_init" restart || ! _probe; then
        _warn 'previous DNS failed live lookup; restoring working dnsproxy route'
        _restore_active_route || _warn 'URGENT: route rollback failed; saved snapshot retained'
        return 1
    fi
    rm -f "$_route"
    _warn 'restored previous dnsmasq configuration; left dnsproxy installed and unmanaged'
}
_retire_redirect() {
    [ -s "$_redirect" ] || return 0
    _redirect_ip=$(_snapshot "$_redirect" redirect_ip)
    [ -n "$_redirect_ip" ] || return 1
    _fw='firewall.z2kow_dns_redirect'
    [ "$(_get "$_fw.name")" = 'z2kOW DNS redirect' ] &&
    [ "$(_get "$_fw.src")" = lan ] &&
    [ "$(_get "$_fw.dest")" = lan ] &&
    [ "$(_get "$_fw.proto")" = 'tcp udp' ] &&
    [ "$(_get "$_fw.src_dport")" = 53 ] &&
    [ "$(_get "$_fw.dest_ip")" = "$_redirect_ip" ] &&
    [ "$(_get "$_fw.dest_port")" = 53 ] &&
    [ "$(_get "$_fw.family")" = ipv4 ] &&
    [ "$(_get "$_fw.target")" = DNAT ] || {
        _warn 'redirect differs from owned firewall rule; preserving it'
        return 1
    }
    _uci delete "$_fw" || return 1
    if ! _uci commit firewall || ! "$_fw4_bin" -q check || ! "$_fw_init" reload; then
        _uci set "$_fw=redirect" &&
        _uci set "$_fw.name=z2kOW DNS redirect" &&
        _uci set "$_fw.src=lan" &&
        _uci set "$_fw.dest=lan" &&
        _uci set "$_fw.proto=tcp udp" &&
        _uci set "$_fw.src_dport=53" &&
        _uci set "$_fw.dest_ip=$_redirect_ip" &&
        _uci set "$_fw.dest_port=53" &&
        _uci set "$_fw.family=ipv4" &&
        _uci set "$_fw.target=DNAT" &&
        _uci commit firewall &&
        "$_fw_init" reload || _warn 'URGENT: firewall rollback failed; marker retained'
        return 1
    fi
    rm -f "$_redirect"
    _warn 'removed the former forced LAN DNS redirect'
}
_rc=0
_retire_route || _rc=1
_retire_redirect || _rc=1
exit "$_rc"
