#!/bin/sh
# The single canonical reader for the installed OpenWrt release record.
# The on-device file remains exactly tag=<release> + seq=<upstream sequence>.
z2k_ow_release_state_read() {
    local _state="${1:-${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}}"
    [ -r "$_state" ] || return 1
    awk '
        NR == 1 {
            if ($0 !~ /^tag=[pr]-[0-9]+(\.[0-9]+)+$/) bad = 1
            else tag = substr($0, 5)
            next
        }
        NR == 2 {
            if ($0 !~ /^seq=[1-9][0-9]*$/) bad = 1
            else seq = substr($0, 5)
            next
        }
        { bad = 1 }
        END {
            if (bad || NR != 2) exit 1
            printf "tag=%s\nseq=%s\n", tag, seq
        }
    ' "$_state"
}

z2k_ow_release_state_error() {
    local _state="${1:-${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}}"
    if [ ! -e "$_state" ]; then
        printf '%s' 'installed release metadata is missing'
    elif [ ! -r "$_state" ]; then
        printf '%s' 'installed release metadata is unreadable'
    else
        printf '%s' 'installed release metadata is invalid'
    fi
}

z2k_ow_release_state_payload_tag() {
    local _record
    _record=$(z2k_ow_release_state_read "${1:-${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}}") || return 1
    printf '%s\n' "$_record" | sed -n 's/^tag=//p' | head -1
}

# WebPanel /status uses this hook when the OpenWrt state adapter is loaded.
# The common API provides a Keenetic fallback with the same JSON key shape.
status_installed_json() {
    local _state="${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}" _record _tag _seq
    if _record=$(z2k_ow_release_state_read "$_state"); then
        _tag=$(printf '%s\n' "$_record" | sed -n 's/^tag=//p' | head -1)
        _seq=$(printf '%s\n' "$_record" | sed -n 's/^seq=//p' | head -1)
        printf '"installed":true,"installed_state":"valid","installed_release":'
        json_string "$_tag"
        printf ',"installed_seq":%s' "$_seq"
    else
        printf '"installed":false,"installed_state":"error","installed_state_error":'
        json_string "$(z2k_ow_release_state_error "$_state")"
    fi
}

update_state_error() {
    z2k_ow_release_state_error "${AU_TAG_FILE:-${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}}"
}
