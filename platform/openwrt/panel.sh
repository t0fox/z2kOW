#!/bin/sh
# platform/openwrt/panel.sh - package/update contract for executable panel bytes.

z2k_ow_panel_contract_version() {
    local _f="${Z2K_ROOT:-/usr/lib/z2k}/share/panel.api" _v _n
    [ -r "$_f" ] || return 1
    _n=$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]*$' "$_f" 2>/dev/null || true)
    [ "$_n" = "1" ] || return 1
    _v=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$_f" 2>/dev/null | tr -d ' \t\r\n')
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$_v"
}

z2k_ow_panel_payload_check() {
    local _root="${Z2K_ROOT:-/usr/lib/z2k}" _v _actions _platform
    _v=$(z2k_ow_panel_contract_version) || {
        echo "panel contract marker is missing or invalid" >&2
        return 1
    }
    _actions="$_root/webpanel/cgi/actions.sh"
    _platform="$_root/webpanel/cgi/platform.sh"
    [ -r "$_actions" ] || { echo "webpanel actions.sh is missing" >&2; return 1; }
    [ -r "$_platform" ] || { echo "webpanel platform.sh is missing" >&2; return 1; }
    grep -qE "^[[:space:]]*Z2K_OPENWRT_PANEL_CONTRACT=${_v}[[:space:]]*$" "$_actions" 2>/dev/null || {
        echo "webpanel actions.sh is older than package contract $_v" >&2
        return 1
    }
    grep -q 'Z2K_NFQWS2' "$_actions" 2>/dev/null || {
        echo "webpanel actions.sh has no OpenWrt nfqws2 seam" >&2
        return 1
    }
    grep -q 'Z2K_NFQWS2' "$_platform" 2>/dev/null || {
        echo "webpanel platform.sh has no OpenWrt nfqws2 seam" >&2
        return 1
    }
    return 0
}

z2k_ow_panel_payload_compatible() {
    z2k_ow_panel_payload_check >/dev/null 2>&1
}
