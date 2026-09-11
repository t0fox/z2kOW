#!/bin/sh
# tests/openwrt/test_ow_forbidden.sh - Step 14: Keenetic-зависимостям нет места.
# Запрещены в platform/ + package/ + tests/openwrt/ (в docs/fixtures — можно):
# ndmc, /opt/etc/ndm, kmod_ndms, Entware-инит, Keenetic-PPE, S99/keenetic в коде.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-forbidden"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# NOTE: сам guard-файл исключён из скана — он содержит эти строки как образцы.
_hits="$(grep -rEin 'ndmc|/opt/etc/ndm|kmod_ndms|entware|-j PPE|ipset-exclude.*PPE' \
    "$REPO/platform/openwrt" "$REPO/package/openwrt" "$REPO/tests/openwrt" \
    | grep -v 'test_ow_forbidden\.sh' || true)"
[ -z "$_hits" ] && _t_ok || _t_bad "Keenetic-зависимости: $_hits"

# S99/keenetic — только в комментариях (атрибуция), не в коде
_bad=""
for _f in "$REPO"/platform/openwrt/*.sh \
          "$REPO"/package/openwrt/files/etc/init.d/z2k \
          "$REPO"/package/openwrt/files/etc/hotplug.d/iface/90-z2k; do
    _h="$(sed 's/#.*$//' "$_f" | grep -inE 'keenetic|S99|(^|[^a-zA-Z_])ndm([^a-zA-Z_]|$)' || true)"
    [ -n "$_h" ] && _bad="$_bad $(basename "$_f"):$_h"
done
[ -z "$_bad" ] && _t_ok || _t_bad "keenetic-следы в коде:$_bad"

_t_done
