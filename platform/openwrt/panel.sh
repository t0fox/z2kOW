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

z2k_ow_panel_file_sha() {
    local _file="$1"
    [ -f "$_file" ] || return 1
    if command -v z2k_sha256_file >/dev/null 2>&1; then
        z2k_sha256_file "$_file"
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$_file" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

z2k_ow_panel_snapshot_sha() {
    local _manifest="$1" _path="$2" _sha
    [ -r "$_manifest" ] || return 1
    # The updater's parser is canonical when the full updater is loaded (for
    # example by package postinst).  CGI has a deliberately smaller source
    # graph, so retain a local read-only fallback for the same flat map.
    if command -v au_manifest_file_sha >/dev/null 2>&1; then
        _sha=$(au_manifest_file_sha "$_manifest" "$_path" 2>/dev/null)
    else
        _sha=$(awk -v key="$_path" '
            index($0, "\"" key "\"") {
                line=$0
                sub(".*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
                sub("\".*", "", line)
                if (length(line) == 64 && line !~ /[^0-9A-Fa-f]/) print line
                exit
            }
        ' "$_manifest" 2>/dev/null)
    fi
    _sha=$(printf '%s' "$_sha" | tr -d ' \t\r\n' | tr 'A-F' 'a-f')
    printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s' "$_sha"
}

z2k_ow_panel_snapshot_check() {
    local _root="${Z2K_ROOT:-/usr/lib/z2k}" _manifest="$_root/share/snapshot-manifest.json"
    local _path _dest _want _got
    # Production packages do not carry a snapshot.  Their existing signed
    # updater path remains authoritative; only an embedded CI snapshot can
    # make a local byte-for-byte payload claim.
    [ -s "$_manifest" ] || return 0
    for _path in webpanel/cgi/actions.sh webpanel/cgi/platform.sh; do
        _dest="$_root/$_path"
        _want=$(z2k_ow_panel_snapshot_sha "$_manifest" "$_path") || {
            echo "snapshot manifest has no hash for $_path" >&2
            return 1
        }
        _got=$(z2k_ow_panel_file_sha "$_dest" | tr -d ' \t\r\n' | tr 'A-F' 'a-f') || {
            echo "cannot hash installed panel payload $_path" >&2
            return 1
        }
        [ "$_got" = "$_want" ] || {
            echo "installed panel payload is stale: $_path" >&2
            return 1
        }
    done
    return 0
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
    z2k_ow_panel_snapshot_check || return 1
    return 0
}

z2k_ow_panel_payload_compatible() {
    z2k_ow_panel_payload_check >/dev/null 2>&1
}
