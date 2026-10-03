#!/bin/sh
# OpenWrt host-record backend for the shared upstream IP refresh flow.
# The helper keeps its DNS fetch, HMAC, range filter, and HTTPS liveness probes;
# validated address records are applied through dnsmasq addnhosts.

Z2K_INSTA_HOSTS_FILE="${Z2K_INSTA_HOSTS_FILE:-${Z2K_STATE:-/etc/z2k/state}/insta-hosts}"
Z2K_INSTA_UCI_MARKER="${Z2K_INSTA_UCI_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.insta-addnhosts-owned}"
Z2K_INSTA_UCI_SECTION="${Z2K_INSTA_UCI_SECTION:-dhcp.@dnsmasq[0]}"
Z2K_INSTA_UCI_BIN="${Z2K_INSTA_UCI_BIN:-uci}"
Z2K_INSTA_DNSMASQ_INIT="${Z2K_INSTA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"

z2k_ow_insta_registered() {
    "$Z2K_INSTA_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | grep -F ".addnhosts=$Z2K_INSTA_HOSTS_FILE" >/dev/null 2>&1
}

z2k_ow_insta_reload_dnsmasq() {
    [ -x "$Z2K_INSTA_DNSMASQ_INIT" ] || return 1
    "$Z2K_INSTA_DNSMASQ_INIT" reload >/dev/null 2>&1
}

# Register an exact persistent file path without replacing any existing
# dnsmasq addnhosts entries. Remember ownership only if this function added it.
z2k_ow_insta_prepare() {
    command -v "$Z2K_INSTA_UCI_BIN" >/dev/null 2>&1 || return 1
    [ -x "$Z2K_INSTA_DNSMASQ_INIT" ] || return 1
    "$Z2K_INSTA_UCI_BIN" -q show "$Z2K_INSTA_UCI_SECTION" >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$Z2K_INSTA_HOSTS_FILE")" "$(dirname "$Z2K_INSTA_UCI_MARKER")" \
        2>/dev/null || return 1
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] || : > "$Z2K_INSTA_HOSTS_FILE" || return 1
    if ! z2k_ow_insta_registered; then
        "$Z2K_INSTA_UCI_BIN" add_list \
            "$Z2K_INSTA_UCI_SECTION.addnhosts=$Z2K_INSTA_HOSTS_FILE" || return 1
        "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
        printf '%s\n' "$Z2K_INSTA_HOSTS_FILE" > "$Z2K_INSTA_UCI_MARKER" || return 1
        chmod 0600 "$Z2K_INSTA_UCI_MARKER" 2>/dev/null || return 1
        z2k_ow_insta_reload_dnsmasq || return 1
    fi
    return 0
}

# Match the upstream `show running-config` shape so its host/IP diff loop and
# validation stay shared: `ip host <hostname> <address>`.
z2k_ow_insta_show_running_config() {
    [ -r "$Z2K_INSTA_HOSTS_FILE" ] || return 0
    awk '
        /^[[:space:]]*#/ || NF < 2 { next }
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            ip=$1
            for (i=2; i<=NF; i++)
                if ($i ~ /^[a-zA-Z0-9.-]+$/) print "ip host " $i " " ip
        }
    ' "$Z2K_INSTA_HOSTS_FILE"
}

_z2k_ow_insta_write() {
    local _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k.$$"
    mkdir -p "$(dirname "$Z2K_INSTA_HOSTS_FILE")" 2>/dev/null || return 1
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
}

z2k_ow_insta_add_host() {
    local _host="$1" _ip="$2" _tmp
    case "$_host" in ''|*[!a-zA-Z0-9.-]*) return 1 ;; esac
    printf '%s\n' "$_ip" | awk -F. 'NF==4 && $1<256 && $2<256 && $3<256 && $4<256 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/' \
        | grep -q . || return 1
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] && awk -v h="$_host" -v ip="$_ip" \
        '$1==ip && $2==h {found=1} END {exit !found}' "$Z2K_INSTA_HOSTS_FILE" \
        && return 0
    _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k.$$"
    { [ ! -f "$Z2K_INSTA_HOSTS_FILE" ] || cat "$Z2K_INSTA_HOSTS_FILE"; \
      printf '%s %s\n' "$_ip" "$_host"; } > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    return 0
}

z2k_ow_insta_remove_host() {
    local _host="$1" _ip="$2"
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] || return 0
    awk -v h="$_host" -v ip="$_ip" '!($1==ip && $2==h)' \
        "$Z2K_INSTA_HOSTS_FILE" | _z2k_ow_insta_write
}

z2k_ow_insta_commit() {
    "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
    z2k_ow_insta_reload_dnsmasq
}

z2k_ow_insta_flush_ip() {
    command -v conntrack >/dev/null 2>&1 || return 0
    conntrack -D -d "$1" >/dev/null 2>&1 || true
    return 0
}

# Called before the complete payload tree is removed. Only delete the UCI list
# entry if z2k created it; user addnhosts entries and dnsmasq settings survive.
z2k_ow_insta_uninstall() {
    local _owned=""
    if [ -r "$Z2K_INSTA_UCI_MARKER" ]; then
        _owned=$(cat "$Z2K_INSTA_UCI_MARKER" 2>/dev/null)
        if [ "$_owned" = "$Z2K_INSTA_HOSTS_FILE" ]; then
            "$Z2K_INSTA_UCI_BIN" del_list \
                "$Z2K_INSTA_UCI_SECTION.addnhosts=$Z2K_INSTA_HOSTS_FILE" || return 1
            "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
            z2k_ow_insta_reload_dnsmasq || return 1
        fi
    fi
    rm -f "$Z2K_INSTA_HOSTS_FILE" "$Z2K_INSTA_UCI_MARKER"
}
