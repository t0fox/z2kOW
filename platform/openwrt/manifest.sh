#!/bin/sh
# The one OpenWrt release authority: signed UPDATES.json on z2kOW/main.
# Release type/history is informational to migration hooks; deployment always
# downloads and converges the complete current OpenWrt filesystem archive.

z2k_ow_manifest_value() {
    _m="$1" _key="$2"
    command -v jsonfilter >/dev/null 2>&1 || return 1
    jsonfilter -i "$_m" -e "@.$_key" 2>/dev/null | head -n 1
}

z2k_ow_manifest_shape_ok() {
    _m="$1"
    [ -s "$_m" ] || return 1
    [ "$(z2k_ow_manifest_value "$_m" schema)" = 1 ] || return 1
    [ "$(z2k_ow_manifest_value "$_m" branch)" = main ] || return 1
    [ "$(z2k_ow_manifest_value "$_m" platform)" = openwrt ] || return 1
    _tag=$(z2k_ow_manifest_value "$_m" current) || return 1
    _seq=$(z2k_ow_manifest_value "$_m" seq) || return 1
    [ "$(z2k_ow_manifest_value "$_m" upstream.repository)" = necronicle/z2k ] || return 1
    [ "$(z2k_ow_manifest_value "$_m" upstream.branch)" = z2k-enhanced ] || return 1
    [ "$(z2k_ow_manifest_value "$_m" upstream.tag)" = "$_tag" ] || return 1
    _commit=$(z2k_ow_manifest_value "$_m" upstream.commit) || return 1
    printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || return 1
    printf '%s' "$_seq" | grep -Eq '^[1-9][0-9]*$' || return 1
    printf '%s' "$_commit" | grep -Eq '^[0-9a-f]{40}$'
}

z2k_ow_manifest_release_ok() {
    _m="$1"
    z2k_ow_manifest_shape_ok "$_m" || return 1
    _tag=$(z2k_ow_manifest_value "$_m" current) || return 1
    _filename=$(z2k_ow_manifest_value "$_m" artifact.filename) || return 1
    _url=$(z2k_ow_manifest_value "$_m" artifact.url) || return 1
    _sha=$(z2k_ow_manifest_value "$_m" artifact.sha256 | tr 'A-F' 'a-f') || return 1
    _size=$(z2k_ow_manifest_value "$_m" artifact.size_bytes) || return 1
    _expected="https://github.com/t0fox/z2kOW/releases/download/$_tag/openwrt-rootfs.tar.gz"
    [ "$_filename" = openwrt-rootfs.tar.gz ] \
        && [ "$_url" = "$_expected" ] \
        && printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' \
        && printf '%s' "$_size" | grep -Eq '^[1-9][0-9]*$'
}

z2k_ow_manifest_prepare_production() {
    _out="${1:-${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json}"
    _sig="$_out.sig"
    mkdir -p "$(dirname "$_out")" 2>/dev/null || return 1
    rm -f "$_out" "$_sig"
    command -v au_fetch_pair >/dev/null 2>&1 || return 1
    command -v au_manifest_verify >/dev/null 2>&1 || return 1
    _base="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/t0fox/z2kOW/main}"
    au_fetch_pair "$_base/UPDATES.json" "$_base/UPDATES.json.sig" "$_out" "$_sig" || {
        echo "z2k-openwrt: controlled UPDATES.json fetch failed" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    [ -s "$_sig" ] && au_manifest_verify "$_out" "$_sig" || {
        echo "z2k-openwrt: controlled UPDATES.json signature invalid or missing" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    z2k_ow_manifest_release_ok "$_out" || {
        echo "z2k-openwrt: controlled UPDATES.json has an invalid release record" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    rm -f "$_sig"
    Z2K_OW_MANIFEST_PATH="$_out"
    export Z2K_OW_MANIFEST_PATH
    return 0
}
