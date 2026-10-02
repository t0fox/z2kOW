#!/bin/sh
# tests/openwrt/fixture.sh - сборка изолированного Z2K_ROOT из РЕАЛЬНОГО репо.
# Изолированная копия payload; запись/миграции остаются только в $T.
# Использование: . fixture.sh; ow_fixture_init  # выставляет Z2K_* + REPO
# Очистка: ow_fixture_done (вызывает caller через trap).

ow_fixture_init() {
    _OW_FIX_SELF="$(dirname "$0")"
    REPO="$(cd "$_OW_FIX_SELF/../.." && pwd)"
    T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-test.XXXXXX")" || return 1

    export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
    unset ZAPRET2_DIR CONFIG_DIR LISTS_DIR ZAPRET_CONFIG OPENWRT_LAN FWTYPE \
          Z2K_STATE_DIR_OVERRIDE Z2K_TCP16_ASN Z2K_TCP16_NETS Z2K_TCP16_SNI Z2K_SNI_PIN \
          INIT_SCRIPT Z2K_CONFIG_FILE Z2K_AU_SBIN STATE_FILE \
          Z2K_EXTRA_DOMAINS_SHIPPED Z2K_EXTRA_DOMAINS_RUNTIME

    mkdir -p "$Z2K_ROOT" "$Z2K_ETC" || return 1
    # Copies work on Windows-hosted POSIX shells too, where creating symlinks
    # may require an elevated developer-mode privilege.
    cp -a "$REPO/lib" "$Z2K_ROOT/lib" || return 1
    cp -a "$REPO/files/lua" "$Z2K_ROOT/lua" || return 1
    cp -a "$REPO/files/fake" "$Z2K_ROOT/fake" || return 1
    mkdir -p "$Z2K_ROOT/platform/openwrt" || return 1
    for _f in "$REPO"/platform/openwrt/*.sh; do
        cp -p "$_f" "$Z2K_ROOT/platform/openwrt/$(basename "$_f")" || return 1
    done
    # Bootstrap validates the complete release tree's pinned upstream
    # executables. Supply architecture-correct test fixtures rather than
    # relying on host-installed /opt/zapret2 files.
    Z2K_ZAPRET2_RUNTIME="$T/zapret2"
    export Z2K_ZAPRET2_RUNTIME
    . "$Z2K_ROOT/platform/openwrt/arch.sh" || return 1
    _ow_runtime_arch="$(z2k_ow_arch_name)" || return 1
    mkdir -p "$Z2K_ZAPRET2_RUNTIME/binaries/linux-$_ow_runtime_arch" || return 1
    for _name in nfqws2 ip2net mdig; do
        printf '#!/bin/sh\nexit 0\n' > "$Z2K_ZAPRET2_RUNTIME/binaries/linux-$_ow_runtime_arch/$_name" || return 1
        chmod +x "$Z2K_ZAPRET2_RUNTIME/binaries/linux-$_ow_runtime_arch/$_name" || return 1
    done
    mkdir -p "$Z2K_ROOT/lists" || return 1
    for _f in "$REPO"/files/lists/*.txt; do
        cp -p "$_f" "$Z2K_ROOT/lists/$(basename "$_f")" || return 1
    done
    mkdir -p "$Z2K_ROOT/extra_strats" || return 1
    cp -a "$REPO/files/lists/extra_strats/TCP" "$REPO/files/lists/extra_strats/UDP" \
        "$Z2K_ROOT/extra_strats/" || return 1
    chmod -R u+w "$Z2K_ROOT/extra_strats" || return 1
    # Манифесты — в КОРНЕ payload (как на Keenetic/production).
    cp -p "$REPO/strats_new2.txt" "$Z2K_ROOT/strats_new2.txt" || return 1
    cp -p "$REPO/quic_strats.ini" "$Z2K_ROOT/quic_strats.ini" || return 1
    mkdir -p "$Z2K_ROOT/share" || return 1
    cp -p "$REPO/platform/openwrt/files/etc/z2k/config.default" \
        "$Z2K_ROOT/share/config.default" || return 1
    return 0
}

ow_fixture_done() {
    [ -n "$T" ] && [ -d "$T" ] && rm -rf "$T"
}
