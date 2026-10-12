#!/bin/sh
# Единая политика прозрачного Telegram TCP для адаптера OpenWrt.
# Это bootstrap-список портов, а не обнаружение адресов Telegram.
# После help.getConfig nft получает только точные пары IP+порт из Rust-манифеста.
# Параметр TG_TCP_PORTS в OpenWrt-конфиге может заменить этот список.
# Обычный HTTP порт не включён; добавлять его можно только после отдельной
# проверки MTProto TCP/HTTP и конфликтов с обычным HTTP/CDN.
Z2K_TG_TCP_PORTS_DEFAULT="443 5222"
Z2K_TG_DC_MAP_PATH_DEFAULT="${Z2K_TG_DC_MAP_PATH_DEFAULT:-$Z2K_TG_DC_MAP_PATH}"
Z2K_TG_DC_MAP_REFRESH_SECS_DEFAULT="21600"
Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT="${Z2K_TG_DC_MAP_ENDPOINTS_PATH_DEFAULT:-$Z2K_TG_DC_MAP_ENDPOINTS_PATH}"

# Встроенная проверенная копия диапазонов DC для работы без обновления сети.
# Официальный help.getConfig публикует адреса DC, а не CIDR; обновление CIDR
# из неофициальных списков здесь намеренно не выполняется.
Z2K_TG_CIDRS_DEFAULT="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
Z2K_TG_CIDRS6_DEFAULT="2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280:203::/48"
