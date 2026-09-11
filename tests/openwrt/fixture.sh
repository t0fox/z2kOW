#!/bin/sh
# tests/openwrt/fixture.sh - сборка изолированного Z2K_ROOT из РЕАЛЬНОГО репо.
# Симлинки на тяжёлый payload (только чтение), запись — в $T (tmpfs).
# Использование: . fixture.sh; ow_fixture_init  # выставляет Z2K_* + REPO
# Очистка: ow_fixture_done (вызывает caller через trap).

ow_fixture_init() {
    _OW_FIX_SELF="$(dirname "$0")"
    REPO="$(cd "$_OW_FIX_SELF/../.." && pwd)"
    T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-test.XXXXXX")" || return 1

    export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
    unset ZAPRET2_DIR CONFIG_DIR LISTS_DIR ZAPRET_CONFIG OPENWRT_LAN FWTYPE \
          Z2K_STATE_DIR_OVERRIDE Z2K_TCP16_ASN Z2K_TCP16_NETS Z2K_TCP16_SNI Z2K_SNI_PIN

    mkdir -p "$Z2K_ROOT" "$Z2K_ETC" || return 1
    # payload — симлинки на реальное дерево (read-only использование)
    ln -s "$REPO/lib" "$Z2K_ROOT/lib" || return 1
    ln -s "$REPO/files/lua" "$Z2K_ROOT/lua" || return 1
    ln -s "$REPO/files/fake" "$Z2K_ROOT/fake" || return 1
    mkdir -p "$Z2K_ROOT/platform/openwrt" || return 1
    for _f in "$REPO"/platform/openwrt/*.sh; do
        ln -s "$_f" "$Z2K_ROOT/platform/openwrt/$(basename "$_f")" || return 1
    done
    mkdir -p "$Z2K_ROOT/lists" || return 1
    for _f in "$REPO"/files/lists/*.txt; do
        ln -s "$_f" "$Z2K_ROOT/lists/$(basename "$_f")" || return 1
    done
    mkdir -p "$Z2K_ROOT/extra_strats" || return 1
    cp -a "$REPO/files/lists/extra_strats/TCP" "$REPO/files/lists/extra_strats/UDP" \
        "$Z2K_ROOT/extra_strats/" || return 1
    chmod -R u+w "$Z2K_ROOT/extra_strats" || return 1
    mkdir -p "$Z2K_ROOT/manifests" || return 1
    ln -s "$REPO/strats_new2.txt" "$Z2K_ROOT/manifests/strats_new2.txt" || return 1
    ln -s "$REPO/quic_strats.ini" "$Z2K_ROOT/manifests/quic_strats.ini" || return 1
    mkdir -p "$Z2K_ROOT/share" || return 1
    ln -s "$REPO/package/openwrt/files/etc/z2k/config.default" \
        "$Z2K_ROOT/share/config.default" || return 1
    return 0
}

ow_fixture_done() {
    [ -n "$T" ] && [ -d "$T" ] && rm -rf "$T"
}
