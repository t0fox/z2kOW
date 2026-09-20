#!/bin/sh
# platform/openwrt/autohostlist.sh - OpenWrt auto-hostlist lifecycle.
#
# The engine file is a live, append-only input for nfqws2.  The panel ledger is
# persistent user state.  They are deliberately separate: the former is
# drained atomically and recreated on start, while the latter is the only
# source used by WebUI duplicate checks.

AUTOHOSTLIST_DOMAINS_FILE="${AUTOHOSTLIST_DOMAINS_FILE:-${Z2K_AUTOHOSTLIST_DOMAINS_FILE:-${Z2K_STATE:-/etc/z2k/state}/autohostlist-domains.txt}}"
export AUTOHOSTLIST_DOMAINS_FILE

z2k_ow_autohostlist_enabled() {
    local _v="${Z2K_AUTOHOSTLIST:-}" _cfg="${Z2K_CONFIG:-${Z2K_ETC:-/etc/z2k}/config}"
    if [ -z "$_v" ] && [ -r "$_cfg" ]; then
        _v=$(sed -n 's/^[[:space:]]*Z2K_AUTOHOSTLIST[[:space:]]*=[[:space:]]*//p' \
            "$_cfg" 2>/dev/null | tail -1 | sed "s/[\"']//g" | tr -d ' \t\r\n')
    fi
    [ "$_v" = "1" ]
}

# Keep the upstream normalisation rules: comments, URL decoration, ports and
# wildcard prefixes are removed, malformed domains are ignored, and output is
# bare lowercase names suitable for both the panel and --hostlist-auto.
z2k_ow_autohostlist_normalize() {
    awk '
    {
        s=$0
        gsub(/\r/, "", s)
        sub(/#.*/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (s == "") next
        s=tolower(s)
        sub(/^[a-z][a-z0-9+.-]*:\/\//, "", s)
        sub(/\/.*/, "", s)
        sub(/:[0-9]+$/, "", s)
        gsub(/^\*\./, "", s)
        sub(/\.$/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (s == "" || s ~ /[^a-z0-9.-]/ || s ~ /\.\./) next
        n=split(s, a, ".")
        if (n < 2) next
        bad=0
        for (i=1; i<=n; i++) {
            if (a[i] == "" || a[i] ~ /^-/ || a[i] ~ /-$/ || a[i] !~ /^[a-z0-9-]+$/) {
                bad=1; break
            }
        }
        if (!bad) print s
    }'
}

_z2k_ow_autohostlist_write() {
    local _dst="$1" _src="$2" _tmp="${1}.z2k.$$"
    mkdir -p "$(dirname "$_dst")" 2>/dev/null || return 1
    cat "$_src" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$_dst" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    return 0
}

_z2k_ow_autohostlist_chown_live() {
    local _user="${WS_USER:-nobody}" _file="$1"
    [ -f "$_file" ] || return 0
    [ "$_user" = root ] || chown "$_user" "$_file" 2>/dev/null || true
    return 0
}

# Merge the persistent ledger and discoveries drained from the live engine
# file.  The live file is renamed before it is read so an nfqws2 append cannot
# be lost between a read and truncate.  No payload list is consulted.
z2k_ow_autohostlist_sync() {
    local _ledger="${AUTOHOSTLIST_DOMAINS_FILE}" _auto="${Z2K_AUTOHOSTLIST_FILE:-${Z2K_STATE:-/etc/z2k/state}/zapret-hosts-auto.txt}"
    local _have_ledger=0 _have_auto=0 _auto_exists=0 _drain="${_auto}.drain.$$" _merged="${Z2K_TMP:-/tmp/z2k}/autohostlist-merged.$$"
    [ -s "$_ledger" ] && _have_ledger=1
    [ -s "$_auto" ] && _have_auto=1
    [ -e "$_auto" ] && _auto_exists=1
    [ "$_have_ledger" = 1 ] || [ "$_have_auto" = 1 ] || return 0
    mkdir -p "$(dirname "$_ledger")" "$(dirname "$_auto")" "${Z2K_TMP:-/tmp/z2k}" 2>/dev/null || return 1

    if [ "$_have_auto" = 1 ]; then
        mv -f "$_auto" "$_drain" 2>/dev/null || return 1
    else
        : > "$_drain" || return 1
    fi
    if [ "$_auto_exists" = 1 ] || z2k_ow_autohostlist_enabled; then
        : > "$_auto" 2>/dev/null || { rm -f "$_drain"; return 1; }
    fi

    {
        [ -f "$_ledger" ] && cat "$_ledger"
        [ -f "$_drain" ] && cat "$_drain"
    } | z2k_ow_autohostlist_normalize | LC_ALL=C sort -u > "$_merged" 2>/dev/null || {
        rm -f "$_drain" "$_merged"
        return 1
    }
    _z2k_ow_autohostlist_write "$_ledger" "$_merged" || {
        rm -f "$_drain" "$_merged"
        return 1
    }
    rm -f "$_drain" 2>/dev/null

    # Keep an already-used engine input present and empty after a stop;
    # start/prepare repopulates it from the persistent ledger.  Disabled mode
    # does not materialize a new working file merely because the ledger exists.
    if [ "$_auto_exists" = 1 ] || z2k_ow_autohostlist_enabled; then
        : > "$_merged.live" 2>/dev/null || { rm -f "$_merged"; return 1; }
        mv -f "$_merged.live" "$_auto" 2>/dev/null || { rm -f "$_merged"; return 1; }
    else
        rm -f "$_auto" "$_merged.live" 2>/dev/null
    fi
    rm -f "$_merged" 2>/dev/null
    _z2k_ow_autohostlist_chown_live "$_auto"
    return 0
}

# Restore the persistent ledger into the engine file before config generation.
# Disabled mode deliberately leaves no live file: the ledger is retained for a
# later re-enable and is still visible in WebUI.
z2k_ow_autohostlist_prepare() {
    z2k_ow_autohostlist_enabled || return 0
    local _ledger="${AUTOHOSTLIST_DOMAINS_FILE}" _auto="${Z2K_AUTOHOSTLIST_FILE:-${Z2K_STATE:-/etc/z2k/state}/zapret-hosts-auto.txt}"
    local _merged="${Z2K_TMP:-/tmp/z2k}/autohostlist-prepare.$$"
    mkdir -p "$(dirname "$_ledger")" "$(dirname "$_auto")" "${Z2K_TMP:-/tmp/z2k}" 2>/dev/null || return 1
    [ -f "$_ledger" ] || : > "$_ledger" || return 1
    cat "$_ledger" | z2k_ow_autohostlist_normalize | LC_ALL=C sort -u > "$_merged" 2>/dev/null || {
        rm -f "$_merged"; return 1;
    }
    _z2k_ow_autohostlist_write "$_ledger" "$_merged" || { rm -f "$_merged"; return 1; }
    _z2k_ow_autohostlist_write "$_auto" "$_merged" || { rm -f "$_merged"; return 1; }
    rm -f "$_merged" 2>/dev/null
    _z2k_ow_autohostlist_chown_live "$_auto"
    return 0
}
