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

# 0. синтаксис всех shell-файлов слоя (+ Stage 7 release tooling)
for _f in platform/openwrt/*.sh platform/openwrt/custom.d/.keep \
          package/openwrt/files/etc/init.d/z2k \
          package/openwrt/files/etc/init.d/z2k-webpanel \
          package/openwrt/files/etc/init.d/z2k-detect \
          package/openwrt/files/etc/hotplug.d/iface/90-z2k \
          scripts/openwrt/*.sh \
          tests/openwrt/*.sh; do
    [ -f "$_f" ] || continue
    [ "$(basename "$_f")" = ".keep" ] && continue
    if sh -n "$_f" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED="$FAILED syntax:$_f"
        echo "FAIL[syntax]: $_f" >&2
    fi
done

# 1. наборы (каждый — один прогон, счёт из SUITE-строки)
for _t in tests/openwrt/test_ow_*.sh; do
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

echo "OPENWRT: pass=$PASS fail=$FAIL"
[ -n "$FAILED" ] && echo "FAILED:$FAILED" >&2
if [ "$STRICT" = "1" ] && [ -n "$SKIPPED" ]; then
    echo "STRICT-SKIP:$SKIPPED" >&2
    FAIL=$((FAIL + 1))
fi
[ "$FAIL" -eq 0 ]
