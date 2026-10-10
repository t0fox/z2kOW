#!/bin/sh
# Единственный источник сведений о выпусках OpenWrt — подписанный UPDATES.json
# в z2kOW/main. История выпуска нужна только для переноса настроек; установщик
# загружает полный набор файлов OpenWrt для архитектуры этого роутера. Старый
# общий архив выбирается только при отсутствии поля artifacts.

z2k_ow_manifest_value() {
    local _m="$1" _key="$2"
    command -v jsonfilter >/dev/null 2>&1 || return 1
    jsonfilter -i "$_m" -e "@.$_key" 2>/dev/null | head -n 1
}

z2k_ow_manifest_type() {
    local _m="$1" _key="$2"
    command -v jsonfilter >/dev/null 2>&1 || return 1
    jsonfilter -i "$_m" -t "@.$_key" 2>/dev/null | head -n 1
}

z2k_ow_manifest_local_arch() {
    local _adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_adapter/arch.sh" ] || return 1
    . "$_adapter/arch.sh" || return 1
    z2k_ow_arch_name
}

z2k_ow_manifest_positive_bytes() {
    local _value="$1"
    case "$_value" in ''|0|0*|*[!0-9]*) return 1 ;; esac
    [ "${#_value}" -le 10 ] || return 1
    [ "$_value" -le 2147483647 ] 2>/dev/null
}

# Выбрать и проверить ровно один архив выпуска. Если карта artifacts есть,
# она главная, даже когда в ней нет записи для нужной архитектуры. Старое
# поле artifact допускается только при полном отсутствии карты.
z2k_ow_manifest_select_artifact() {
    local _m="$1" _arch="$2" _expected_url="${3:-}" _map_type _record
    local _filename_key _field_prefix _filename _url _sha _size _unpacked
    case "$_arch" in arm64|arm|x86_64|x86|mips|mipsel|riscv64) ;; *) return 1 ;; esac
    z2k_ow_manifest_shape_ok "$_m" || return 1
    _map_type="$(z2k_ow_manifest_type "$_m" artifacts)"
    case "$_map_type" in
        '')
            Z2K_OW_ARTIFACT_MODE=legacy
            _field_prefix=artifact
            _filename_key=openwrt-rootfs.tar.gz
            _unpacked=
            ;;
        object)
            Z2K_OW_ARTIFACT_MODE=per-arch
            _field_prefix="artifacts.$_arch"
            _filename_key="openwrt-rootfs-$_arch.tar.gz"
            _unpacked="$(z2k_ow_manifest_value "$_m" "$_field_prefix.unpacked_size_bytes")" || return 1
            z2k_ow_manifest_positive_bytes "$_unpacked" || return 1
            ;;
        *) return 1 ;;
    esac

    _filename="$(z2k_ow_manifest_value "$_m" "$_field_prefix.filename")" || return 1
    _url="$(z2k_ow_manifest_value "$_m" "$_field_prefix.url")" || return 1
    _sha="$(z2k_ow_manifest_value "$_m" "$_field_prefix.sha256" | tr 'A-F' 'a-f')" || return 1
    _size="$(z2k_ow_manifest_value "$_m" "$_field_prefix.size_bytes")" || return 1
    [ "$_filename" = "$_filename_key" ] || return 1
    printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
    z2k_ow_manifest_positive_bytes "$_size" || return 1
    if [ -n "$_expected_url" ]; then
        [ "$_url" = "$_expected_url" ] || return 1
    else
        printf '%s' "$_url" | grep -Eq '^https://github[.]com/t0fox/z2kOW/releases/download/(openwrt-[0-9a-f]{40}|[pr]-[0-9]+([.][0-9]+)+)/[^/]+$' || return 1
        case "$_url" in */"$_filename") ;; *) return 1 ;; esac
    fi

    Z2K_OW_ARTIFACT_FILENAME="$_filename"
    Z2K_OW_ARTIFACT_URL="$_url"
    Z2K_OW_ARTIFACT_SHA256="$_sha"
    Z2K_OW_ARTIFACT_SIZE_BYTES="$_size"
    Z2K_OW_ARTIFACT_UNPACKED_SIZE_BYTES="$_unpacked"
    return 0
}

z2k_ow_manifest_artifact_sha256() {
    local _m="$1" _arch="${2:-}" _expected_url="${3:-}"
    [ -n "$_arch" ] || _arch="$(z2k_ow_manifest_local_arch)" || return 1
    z2k_ow_manifest_select_artifact "$_m" "$_arch" "$_expected_url" || return 1
    printf '%s\n' "$Z2K_OW_ARTIFACT_SHA256"
}

z2k_ow_manifest_verify_signature() {
    _m="$1" _sig="$2"
    [ -s "$_m" ] && [ -s "$_sig" ] || return 1
    _key_id="$(z2k_ow_manifest_value "$_m" signing.key_id)" || return 1
    printf '%s' "$_key_id" | grep -Eq '^[0-9a-f]{64}$' || return 1

    if [ -n "${Z2K_OW_BOOTSTRAP_PUBLIC_KEY:-}" ]; then
        _key="$Z2K_OW_BOOTSTRAP_PUBLIC_KEY"
    else
        _keys="${Z2K_OW_RELEASE_KEYS:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt/release-keys}"
        _key="$_keys/$_key_id.pub"
    fi
    [ -s "$_key" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 2
    _actual_key_id="$(openssl pkey -pubin -in "$_key" -outform DER 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')"
    [ "$_actual_key_id" = "$_key_id" ] || return 1
    command -v au_manifest_verify >/dev/null 2>&1 || return 2
    (
        Z2K_AU_PUBKEY="$_key"
        export Z2K_AU_PUBKEY
        au_manifest_verify "$_m" "$_sig"
    )
}

z2k_ow_manifest_shape_ok() {
    local _m="$1" _tag _seq _commit
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
    local _m="$1" _expected_url="${2:-}" _arch="${3:-}" _key_id
    z2k_ow_manifest_shape_ok "$_m" || return 1
    _key_id=$(z2k_ow_manifest_value "$_m" signing.key_id) || return 1
    printf '%s' "$_key_id" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [ -n "$_arch" ] || _arch="$(z2k_ow_manifest_local_arch)" || return 1
    z2k_ow_manifest_select_artifact "$_m" "$_arch" "$_expected_url"
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
        echo "z2k-openwrt: не удалось получить UPDATES.json и его подпись" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    [ -s "$_sig" ] && z2k_ow_manifest_verify_signature "$_out" "$_sig" || {
        echo "z2k-openwrt: подпись UPDATES.json отсутствует или неверна" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    z2k_ow_manifest_release_ok "$_out" || {
        echo "z2k-openwrt: в UPDATES.json неверно описан выпуск или архив для этой архитектуры" >&2
        rm -f "$_out" "$_sig"
        return 1
    }
    rm -f "$_sig"
    Z2K_OW_MANIFEST_PATH="$_out"
    export Z2K_OW_MANIFEST_PATH
    return 0
}
