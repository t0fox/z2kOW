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

# S99/keenetic/baggage — только в комментариях (атрибуция), не в коде.
# Список багажа: Keenetic-инит, PPE-правила, вотчдоги, tcp16-probe,
# туннельные имена (TG/HTTP/RT/WARP — будущие слои, им здесь не место),
# ndm, /opt-пути. Границы токенов — чтобы не ловить SHIPPED/tcp16_asn
# (легитимный lua-state plumbing ядра). Когда туннельный слой приземлится —
# обновить этот список осознанно.
_bad=""
for _f in "$REPO"/platform/openwrt/*.sh \
          "$REPO"/package/openwrt/files/etc/init.d/z2k \
          "$REPO"/package/openwrt/files/etc/hotplug.d/iface/90-z2k; do
    # Исключение: дефолт Z2K_ZAPRET2_RUNTIME=/opt/zapret2 — canonical base
    # самого zapret2 (совпадает с его ZAPRET_BASE-дефолтом), не Keenetic-
    # предположение; переопределяется окружением. Всё остальное /opt/* — баг.
    _h="$(sed 's/#.*$//' "$_f" | grep -v 'Z2K_ZAPRET2_RUNTIME.*:-/opt/zapret2' \
        | grep -inE 'keenetic|S99|(^|[^a-zA-Z])PPE([^a-zA-Z]|$)|watchdog|tcp16-probe|Entware|/opt/|z2k-warp|tg-tunnel|http-tunnel|rt-proxy|(^|[^a-zA-Z_])ndm([^a-zA-Z_]|$)' || true)"
    [ -n "$_h" ] && _bad="$_bad $(basename "$_f"):$_h"
done
[ -z "$_bad" ] && _t_ok || _t_bad "багаж в коде:$_bad"

_t_done
