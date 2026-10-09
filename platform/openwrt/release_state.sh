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

# Одноимённый хотфикс не добавляет новый тег в upstream history. Его
# доступность определяется отпечатком архива из проверенного манифеста.
update_hotfix_pending() {
    local _hotfix_manifest="$1" _hotfix_installed="$2" _hotfix_current _hotfix_sha _hotfix_state _hotfix_receipt
    _hotfix_current="$(z2k_ow_manifest_value "$_hotfix_manifest" current)" || return 1
    [ "$_hotfix_current" = "$_hotfix_installed" ] || return 1
    _hotfix_sha="$(z2k_ow_manifest_value "$_hotfix_manifest" artifact.sha256 | tr 'A-F' 'a-f')" || return 1
    printf '%s' "$_hotfix_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    _hotfix_state="${Z2K_OW_INSTALLED_RELEASE_FILE:-${Z2K_STATE:-/etc/z2k/state}/installed-release}"
    _hotfix_receipt="${_hotfix_state%/*}/installed-artifact-sha256"
    if [ -f "$_hotfix_receipt" ] && [ ! -L "$_hotfix_receipt" ] \
        && [ "$(wc -l < "$_hotfix_receipt" | tr -d ' \t\r\n')" = 1 ] \
        && grep -Fxq "$_hotfix_sha" "$_hotfix_receipt"; then
        return 1
    fi
    return 0
}
