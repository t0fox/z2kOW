#!/bin/sh
# Проверяет синтаксис OpenWrt shell-файлов один раз перед acceptance-shards.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
FAILED=""
for _f in platform/openwrt/*.sh platform/openwrt/custom.d/.keep \
          platform/openwrt/bin/z2k-rt-proxy platform/openwrt/bin/z2k-detect \
          platform/openwrt/files/etc/init.d/z2k \
          platform/openwrt/files/etc/init.d/z2k-webpanel \
          platform/openwrt/files/etc/init.d/z2k-detect \
          platform/openwrt/files/etc/hotplug.d/iface/90-z2k \
          scripts/openwrt/*.sh tests/openwrt/*.sh; do
    [ -f "$_f" ] || continue
    [ "$(basename "$_f")" = ".keep" ] && continue
    _interpreter='sh'
    case "$(sed -n '1p' "$_f")" in *bash*) _interpreter='bash' ;; esac
    if "$_interpreter" -n "$_f" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED="$FAILED $_f"
        echo "FAIL[syntax]: $_f" >&2
    fi
done

echo "OPENWRT-SYNTAX: pass=$PASS fail=$FAIL"
[ -z "$FAILED" ]
