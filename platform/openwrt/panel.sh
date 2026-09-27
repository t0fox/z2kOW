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
        # The same repository path appears first in install_map and later in
        # files_sha256.  CGI does not source lib/auto_update.sh, so this local
        # fallback must enter the digest object before looking up the key;
        # matching the first occurrence returns the install target array and
        # falsely reports a missing digest on a valid snapshot.
        _sha=$(awk -v key="$_path" '
            /"files_sha256"[[:space:]]*:/ { in_sha=1; next }
            in_sha && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit }
            in_sha && index($0, "\"" key "\"") {
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

z2k_ow_panel_snapshot_web_paths() {
    local _manifest="$1"
    [ -r "$_manifest" ] || return 1
    awk '
        /"install_map"[[:space:]]*:/ { in_map=1; next }
        in_map && /"files_sha256"[[:space:]]*:/ { exit }
        in_map && index($0, "\"webpanel/www/") {
            line=$0
            sub(/^[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            if (substr(line, 1, 13) == "webpanel/www/" && line !~ /[[:space:]]/) print line
        }
    ' "$_manifest"
}

z2k_ow_panel_snapshot_check_one() {
    local _root="$1" _manifest="$2" _path="$3" _dest _want _got _relative
    case "$_path" in
        webpanel/www/*)
            case "$_path" in *..*|*\\*) echo "unsafe frontend path in snapshot manifest: $_path" >&2; return 1 ;; esac
            _relative=$(printf '%s' "$_path" | sed 's|^webpanel/www/||')
            _dest="$_root/www/$_relative"
            ;;
        webpanel/cgi/*)
            case "$_path" in *..*|*\\*) echo "unsafe CGI path in snapshot manifest: $_path" >&2; return 1 ;; esac
            _dest="$_root/$_path"
            ;;
        *) echo "unexpected webpanel path in snapshot manifest: $_path" >&2; return 1 ;;
    esac
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
}

z2k_ow_panel_snapshot_check() {
    local _root _manifest _path _web_paths
    _root="${Z2K_ROOT:-}"
    [ -n "$_root" ] || {
        echo "OpenWrt payload root is not configured for panel snapshot check" >&2
        return 1
    }
    _manifest="$_root/share/snapshot-manifest.json"
    # Production packages do not carry a snapshot.  Their existing signed
    # updater path remains authoritative; only an embedded CI snapshot can
    # make a local byte-for-byte payload claim.
    [ -s "$_manifest" ] || return 0
    # CGI runtime contract files stay explicit; every served webpanel file is
    # discovered from install_map so newly added modules/assets cannot escape
    # this installed-byte check.
    for _path in webpanel/cgi/actions.sh webpanel/cgi/platform.sh webpanel/cgi/api.sh; do
        z2k_ow_panel_snapshot_check_one "$_root" "$_manifest" "$_path" || return 1
    done
    _web_paths=$(z2k_ow_panel_snapshot_web_paths "$_manifest") || return 1
    [ -n "$_web_paths" ] || {
        echo "snapshot manifest has no webpanel/www install_map entries" >&2
        return 1
    }
    for _path in $_web_paths; do
        z2k_ow_panel_snapshot_check_one "$_root" "$_manifest" "$_path" || return 1
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
