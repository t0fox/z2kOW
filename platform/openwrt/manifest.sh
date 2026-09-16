#!/bin/sh
# platform/openwrt/manifest.sh - one manifest authority for OpenWrt.
#
# A CI snapshot package carries its own immutable manifest and source commit.
# That pair is the authority for fresh provisioning, including optional WARP;
# the production channel is never consulted in that mode.  Without the pair,
# the normal production channel is used, but only after a real signature check.
#
# The helper deliberately does not implement a second updater.  It only
# resolves the manifest, source mode, immutable target ref, and file URL so
# callers can continue using the common download/hash primitives.

z2k_ow_manifest_snapshot_mode() {
    local _root="${Z2K_ROOT:-/usr/lib/z2k}"
    local _manifest="$_root/share/snapshot-manifest.json"
    local _commit="$_root/share/snapshot-commit"

    if [ -e "$_manifest" ] || [ -e "$_commit" ]; then
        if [ -s "$_manifest" ] && [ -s "$_commit" ]; then
            return 0
        fi
        echo "z2k-openwrt: неполная snapshot-пара (manifest/commit) — отказываюсь" >&2
        return 2
    fi
    return 1
}

z2k_ow_manifest_file_sha() {
    # Common auto_update.sh owns the canonical files_sha256 parser.  Refuse to
    # guess if the caller did not load it: an unverified expected hash is not a
    # valid artifact contract.
    command -v au_manifest_file_sha >/dev/null 2>&1 || return 1
    au_manifest_file_sha "$1" "$2"
}

z2k_ow_manifest_shape_ok() {
    local _m="$1"
    [ -s "$_m" ] || return 1
    command -v au_manifest_platform_ok >/dev/null 2>&1 || return 1
    au_manifest_platform_ok "$_m" || return 1
    grep -q '"current"' "$_m" 2>/dev/null || return 1
    grep -q '"install_map"' "$_m" 2>/dev/null || return 1
    grep -q '"files_sha256"' "$_m" 2>/dev/null || return 1
    # A snapshot without any WARP digest could silently fall back to an
    # unpinned binary later.  Keep this generic; the caller additionally checks
    # the exact architecture it is about to install.
    grep -Eq '"z2k-warpd/builds/z2k-warpd-linux-[A-Za-z0-9_-]+"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{64}"' "$_m" 2>/dev/null
}

z2k_ow_manifest_prepare() {
    # $1 = destination manifest path; $2 = optional WARP arch to require.
    local _out="${1:-${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json}"
    local _sig="$_out.sig" _arch="${2:-}"
    local _root="${Z2K_ROOT:-/usr/lib/z2k}"
    local _snap_manifest="$_root/share/snapshot-manifest.json"
    local _snap_commit="$_root/share/snapshot-commit"
    local _mode _ref _want

    mkdir -p "$(dirname "$_out")" 2>/dev/null || return 1
    rm -f "$_out" "$_sig"

    _mode=production
    z2k_ow_manifest_snapshot_mode
    case "$?" in
        0) _mode=snapshot ;;
        1) ;;
        *) return 1 ;;
    esac

    if [ "$_mode" = snapshot ]; then
        cp -f "$_snap_manifest" "$_out" 2>/dev/null || return 1
        _ref=$(tr -d ' \t\r\n' < "$_snap_commit" 2>/dev/null)
        # build-release writes the complete SHA-1 commit.  Short refs would
        # make the URL mutable in repositories where another object shares the
        # prefix, so they are rejected at the trust boundary.
        printf '%s' "$_ref" | grep -Eq '^[0-9a-f]{40}$' || {
            echo "z2k-openwrt: бит snapshot-commit (нужен полный SHA-1)" >&2
            rm -f "$_out"
            return 1
        }
        z2k_ow_manifest_shape_ok "$_out" || {
            echo "z2k-openwrt: snapshot-манифест не прошёл OpenWrt/WARP-проверку" >&2
            rm -f "$_out"
            return 1
        }
        if [ -n "$_arch" ]; then
            _want=$(z2k_ow_manifest_file_sha "$_out" "z2k-warpd/builds/z2k-warpd-linux-$_arch" | tr 'A-F' 'a-f')
            printf '%s' "$_want" | grep -Eq '^[0-9a-f]{64}$' || {
                echo "z2k-openwrt: snapshot не содержит hash WARP для арки $_arch" >&2
                rm -f "$_out"
                return 1
            }
        fi
        Z2K_AU_TARGET_REF="$_ref"
        Z2K_OW_MANIFEST_MODE=snapshot
        Z2K_OW_MANIFEST_PATH="$_out"
        export Z2K_AU_TARGET_REF Z2K_OW_MANIFEST_MODE Z2K_OW_MANIFEST_PATH
        return 0
    fi

    # Production mode is intentionally stricter than au_fetch_manifest's
    # pre-pin compatibility path: WARP provisioning must always have a signed
    # channel manifest.  Missing verifier, missing signature, or bad signature
    # all fail closed.
    command -v au_fetch_pair >/dev/null 2>&1 || return 1
    command -v au_manifest_verify >/dev/null 2>&1 || return 1
    local _base="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt}"
    au_fetch_pair "$_base/UPDATES.json" "$_base/UPDATES.json.sig" "$_out" "$_sig" || {
        echo "z2k-openwrt: production manifest fetch failed" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    [ -s "$_sig" ] && au_manifest_verify "$_out" "$_sig" || {
        echo "z2k-openwrt: production manifest signature invalid or missing" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    z2k_ow_manifest_shape_ok "$_out" || {
        echo "z2k-openwrt: production manifest не прошёл OpenWrt/WARP-проверку" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    if [ -n "$_arch" ]; then
        _want=$(z2k_ow_manifest_file_sha "$_out" "z2k-warpd/builds/z2k-warpd-linux-$_arch" | tr 'A-F' 'a-f')
        printf '%s' "$_want" | grep -Eq '^[0-9a-f]{64}$' || {
            echo "z2k-openwrt: production manifest has no WARP hash for $_arch" >&2
            rm -f "$_out" "$_sig"
            return 1
        }
    fi
    unset Z2K_AU_TARGET_REF
    Z2K_OW_MANIFEST_MODE=production
    Z2K_OW_MANIFEST_PATH="$_out"
    export Z2K_OW_MANIFEST_MODE Z2K_OW_MANIFEST_PATH
    rm -f "$_sig"
    return 0
}

z2k_ow_manifest_file_url() {
    local _path="$1" _base
    [ -n "$_path" ] || return 1
    case "${Z2K_OW_MANIFEST_MODE:-}" in
        snapshot)
            [ -n "${Z2K_AU_TARGET_REF:-}" ] || return 1
            _base="${Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/t0fox/z2kOW}/${Z2K_AU_TARGET_REF}"
            printf '%s/%s' "$_base" "$_path"
            ;;
        production)
            _base="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt}"
            printf '%s/%s' "$_base" "$_path"
            ;;
        *) return 1 ;;
    esac
}
