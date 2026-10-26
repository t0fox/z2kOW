#!/bin/sh
# Повторить TCP16-пробу, пока нет завершённого результата.
# Ночной слот запускает z2k-tcp16-probe.sh напрямую для перемера.
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1

case "${1:-check}" in
    check) ;;
    force) ;;
    *) echo 'usage: tcp16-check.sh {check|force}' >&2; exit 2 ;;
esac

if [ "${1:-check}" != force ] && [ -s "$Z2K_TCP16_FLAG" ] && [ -s "$Z2K_TCP16_TIMESTAMP" ]; then
    _verdict=$(cat "$Z2K_TCP16_FLAG" 2>/dev/null)
    _stamp=$(cat "$Z2K_TCP16_TIMESTAMP" 2>/dev/null)
    _started=$(cat "$Z2K_TCP16_FLAG.started" 2>/dev/null || echo 0)
    case "$_started" in ''|*[!0-9]*) _started=0 ;; esac
    case "$_verdict:$_stamp" in
        0:*[!0-9]*|1:*[!0-9]*|0:|1:) ;;
        0:*|1:*)
            if [ "$_stamp" -gt 0 ] 2>/dev/null && [ "$_stamp" -ge "$_started" ] 2>/dev/null; then
                if [ "$_verdict" = 0 ] || [ -f "$Z2K_TCP16_SNI" ]; then
                    exit 0
                fi
            fi
            ;;
    esac
fi

mkdir -p "$(dirname "$Z2K_TCP16_LOCK")" "$(dirname "$Z2K_TCP16_LOG")" || exit 1
exec sh "$Z2K_TCP16_PROBE"
