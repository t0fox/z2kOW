#!/bin/sh
# tests/openwrt/test_ow_iface.sh - §1: iface ownership без дублирования.
# Вердикт аудита: stock 90-zapret2 гейтится на `zapret2 enabled`, а сервис
# zapret2 в нашей модели DISABLED — stock не сработал бы никогда. Поэтому
# 90-z2k существует, но содержит РОВНО один канонический вызов reload и
# ничего из: WAN/LAN-переопределения, nft-восстановления, recovery.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-iface"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HP="$REPO/package/openwrt/files/etc/hotplug.d/iface/90-z2k"

# ровно один hotplug-файл в нашем дереве дёргает reload_ifsets
# (firewall.sh — определение делегата, не hotplug; считается отдельно)
_n="$(find "$REPO/package" -path '*hotplug*' -type f | wc -l | tr -d ' ')"
assert_eq "один hotplug-файл" "1" "$_n"
_r="$(grep -l 'reload_ifsets' "$REPO"/package/openwrt/files/etc/hotplug.d/iface/* 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "он и вызывает reload" "1" "$_r"

# никакого дублирования: ни nft, ни рестартов, ни recovery в коде
_bad="$(sed 's/#.*$//' "$HP" | grep -nEi 'nft|iptables|fw3|fw4|restart|start_fw|stop_fw|recover|WAN=|LAN=' || true)"
[ -z "$_bad" ] && _t_ok || _t_bad "hotplug дублирует zapret2: $_bad"

# гейт — на z2k, НЕ на zapret2 (иначе не сработает при disabled zapret2)
assert_contains "гейт z2k enabled" "$HP" "init.d/z2k enabled"
if grep -q 'init\.d/zapret2' "$HP"; then
    _t_bad "hotplug гейтится на zapret2 (disabled — не сработает)"
else
    _t_ok
fi

# только ifup/ifdown, демон не упоминается
assert_contains "ifup" "$HP" "ifup"
assert_contains "ifdown" "$HP" "ifdown"
if sed 's/#.*$//' "$HP" | grep -qiE 'nfqws|procd'; then
    _t_bad "hotplug трогает daemon-слой"
else
    _t_ok
fi

_t_done
