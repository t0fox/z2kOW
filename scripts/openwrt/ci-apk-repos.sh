#!/bin/sh
# scripts/openwrt/ci-apk-repos.sh - canonical repositories fragment (CI-only).
#
# Один источник набора системных feeds для apk --repository транзакций:
# target packages + arch base + arch packages + exact kmods/$KABI + z2k feed.
# Используют: fresh resolution, old-root fixture, upgrade transaction —
# чтобы тесты не расходились по набору системных feeds (live-урок: upgrade
# phase 1 без kmods не нашёл kmod-nft-* зависимости).
#
# Использование:
#   . scripts/openwrt/ci-apk-repos.sh
#   z2k_apk_repos "$apkbin" "$tmpdir" "$z2k_feed_url"
# Печатает готовые --repository флаги (по одному на строку; вызывающий
# подставляет НЕкавыченно — это намеренное word splitting для флагов).
# KABI выводится из target packages feed (источник правды, kernel-запись
# формата "  - name: kernel"), произвольный ABI не хардкодим.
# set -u safe: все входы проверены до использования.
z2k_apk_repos() {
    if [ $# -ne 3 ]; then
        echo "z2k_apk_repos: usage: z2k_apk_repos <apkbin> <tmpdir> <z2k-feed-url>" >&2
        return 1
    fi
    _apkbin="$1"; _tmpdir="$2"; _feed="$3"
    [ -x "$_apkbin" ] || { echo "z2k_apk_repos: нет apkbin [$_apkbin]" >&2; return 1; }
    [ -n "$_tmpdir" ] || { echo "z2k_apk_repos: пуст tmpdir" >&2; return 1; }
    [ -n "$_feed" ] || { echo "z2k_apk_repos: пуст z2k feed url" >&2; return 1; }
    _rel="25.12.5"; _arch="aarch64_cortex-a53"; _tgt="mediatek/filogic"
    _dl="https://downloads.openwrt.org/releases/$_rel"
    curl -fSLsS --retry 3 -o "$_tmpdir/z2k-ci-target-packages.adb" \
        "$_dl/targets/$_tgt/packages/packages.adb" || return 1
    _kver="$("$_apkbin" adbdump "$_tmpdir/z2k-ci-target-packages.adb" 2>/dev/null \
        | grep -A3 '^  - name: kernel$' | sed -n 's/^ *version: //p' | head -1 || true)"
    [ -n "$_kver" ] || { echo "z2k_apk_repos: kernel record не распознан" >&2; return 1; }
    _kabi="$(printf '%s' "$_kver" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)~([0-9a-f]+)-r[0-9]+$/\1-1-\2/')"
    case "$_kabi" in
        [0-9]*.[0-9]*.[0-9]*-1-[0-9a-f]*) ;;
        *) echo "z2k_apk_repos: kmods ABI не вывелся из kernel $_kver" >&2; return 1 ;;
    esac
    curl -fSLsS --retry 3 -o /dev/null "$_dl/targets/$_tgt/kmods/$_kabi/" \
        || { echo "z2k_apk_repos: kmods dir $_kabi отсутствует на релизе" >&2; return 1; }
    printf '%s\n' "--repository $_dl/targets/$_tgt/packages/packages.adb"
    printf '%s\n' "--repository $_dl/packages/$_arch/base/packages.adb"
    printf '%s\n' "--repository $_dl/packages/$_arch/packages/packages.adb"
    printf '%s\n' "--repository $_dl/targets/$_tgt/kmods/$_kabi/packages.adb"
    printf '%s\n' "--repository $_feed"
    return 0
}
