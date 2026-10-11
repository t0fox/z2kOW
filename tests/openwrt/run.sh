#!/bin/sh
# tests/openwrt/run.sh - раннер openwrt-наборов (POSIX sh).
# Использование: sh tests/openwrt/run.sh [из корня репо]
# Возвращает ненулевой код при любом провале.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0; FAILED=""
# STRICT=1 (CI): любой SKIP = FAIL. Локально SKIP допустим (нет lighttpd/curl,
# нет скачанного runtime tarball), в CI всё это есть — молчаливый пропуск
# там маскировал бы непроверенное (аудит, пункт 12).
STRICT="${OW_STRICT:-0}"
SKIPPED=""

# CI shards run on isolated GitHub runners. The default remains the entire suite.
# Pin the heaviest suites to separate shards, based on recorded job logs;
# every other shell/Python contract test is assigned round-robin.
SHARD_COUNT="${OW_SHARD_COUNT:-1}"
SHARD_INDEX="${OW_SHARD_INDEX:-0}"
case "$SHARD_COUNT" in ''|*[!0-9]*|0) echo "invalid OW_SHARD_COUNT" >&2; exit 2 ;; esac
case "$SHARD_INDEX" in ''|*[!0-9]*) echo "invalid OW_SHARD_INDEX" >&2; exit 2 ;; esac
[ "$SHARD_INDEX" -lt "$SHARD_COUNT" ] || { echo "shard index out of range" >&2; exit 2; }
_test_seq=0
_selected=0
_shard_select() {
    _target=$((_test_seq % SHARD_COUNT))
    _test_seq=$((_test_seq + 1))
    if [ "$SHARD_COUNT" -eq 4 ]; then
        case "${1##*/}" in
            test_ow_offload_benchmark.sh) _target=0 ;;
            test_ow_unified_release.sh|test_ow_webpanel_unit.sh) _target=1 ;;
            test_ow_webpanel_cgi.sh) _target=2 ;;
            test_ow_warp_lifecycle.sh) _target=3 ;;
        esac
    fi
    [ "$_target" -eq "$SHARD_INDEX" ] || return 1
    _selected=$((_selected + 1))
    return 0
}

# 0. syntax-check each shell file with its declared interpreter.
for _f in platform/openwrt/*.sh platform/openwrt/custom.d/.keep \
          platform/openwrt/bin/z2k-rt-proxy platform/openwrt/bin/z2k-detect \
          platform/openwrt/files/etc/init.d/z2k \
          platform/openwrt/files/etc/init.d/z2k-webpanel \
          platform/openwrt/files/etc/init.d/z2k-detect \
          platform/openwrt/files/etc/hotplug.d/iface/90-z2k \
          scripts/openwrt/*.sh \
          tests/openwrt/*.sh; do
    [ -f "$_f" ] || continue
    [ "$(basename "$_f")" = ".keep" ] && continue
    _syntax_shell='sh'
    case "$(sed -n '1p' "$_f")" in *bash*) _syntax_shell=bash ;; esac
    if "$_syntax_shell" -n "$_f" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED="$FAILED syntax:$_f"
        echo "FAIL[syntax]: $_f" >&2
    fi
done

# 1. наборы (каждый — один прогон, счёт из SUITE-строки)
for _t in tests/openwrt/test_ow_*.sh; do
    _shard_select "$_t" || continue
    _out="$(sh "$_t" 2>&1)"
    _rc=$?
    printf '%s\n' "$_out" | grep -E '^(SUITE|FAIL|SKIP)' || true
    if printf '%s\n' "$_out" | grep -q '^SKIP'; then
        SKIPPED="$SKIPPED $(basename "$_t")"
    fi
    _n="$(printf '%s\n' "$_out" | sed -n 's/^SUITE\[.*\]: pass=\([0-9]*\) fail=.*/\1/p')"
    _f="$(printf '%s\n' "$_out" | sed -n 's/^SUITE\[.*\]: pass=[0-9]* fail=\([0-9]*\)/\1/p')"
    PASS=$((PASS + ${_n:-0}))
    FAIL=$((FAIL + ${_f:-1}))
    { [ "$_rc" -eq 0 ] && [ "${_f:-1}" = "0" ]; } || FAILED="$FAILED $(basename "$_t")"
done

# Python contract tests are executable release gates too (not just developer
# helpers). Keep the unified rootfs and signed-manifest artifact checks in the
# same OpenWrt CI suite as the shell updater tests.
for _t in tests/openwrt/test_ow_*.py; do
    [ -f "$_t" ] || continue
    _shard_select "$_t" || continue
    if python3 "$_t"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED="$FAILED $(basename "$_t")"
    fi
done

echo "OPENWRT: pass=$PASS fail=$FAIL"
echo "OPENWRT-SHARD: index=$SHARD_INDEX total=$SHARD_COUNT selected=$_selected"
[ "$_selected" -gt 0 ] || { echo "empty OpenWrt test shard" >&2; FAIL=$((FAIL + 1)); }
[ -n "$FAILED" ] && echo "FAILED:$FAILED" >&2
if [ "$STRICT" = "1" ] && [ -n "$SKIPPED" ]; then
    echo "STRICT-SKIP:$SKIPPED" >&2
    FAIL=$((FAIL + 1))
fi
[ "$FAIL" -eq 0 ]
