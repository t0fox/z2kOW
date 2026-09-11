#!/bin/sh
# platform/openwrt/uci.sh - чтение СИСТЕМНЫХ данных OpenWrt через UCI.
#
# Правило: новой UCI-схемы z2k здесь НЕТ (конфиг z2k остаётся shell-vars в
# /etc/z2k/config). UCI — только API к системе: network/dnsmasq.
# Приоритет каждого геттера: окружение (/etc/z2k/config) > uci > дефолт.
# Без бинарника uci — молча дефолты (тесты идут без OpenWrt).

# z2k_ow_lan — сети, считающиеся LAN (для zapret2 OPENWRT_LAN).
# Источник — только окружение (/etc/z2k/config: OPENWRT_LAN="lan lan2"),
# иначе дефолт zapret2. Отдельной UCI-схемы z2k нет.
z2k_ow_lan() {
    if [ -n "$OPENWRT_LAN" ]; then
        printf '%s' "$OPENWRT_LAN"
    else
        printf 'lan'
    fi
}

# z2k_ow_dnsmasq_servers — server= записи dnsmasq (для будущего dns-слоя;
# сейчас только экспонируется и покрыта тестом со stub-uci).
z2k_ow_dnsmasq_servers() {
    if command -v uci >/dev/null 2>&1; then
        uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null
        return 0
    fi
    return 0
}
