#!/bin/sh
# platform/openwrt/env.sh - мост между путями OpenWrt и именами upstream z2k.
#
# Upstream lib/*.sh параметризованы окружением (ZAPRET2_DIR, CONFIG_DIR,
# LISTS_DIR — все через ${VAR:-default}), поэтому перенаправление всего
# strategy/config-конвейера на OpenWrt-дерево делается БЕЗ правок common:
# достаточно выставить переменные ДО подключения lib/utils.sh.
#
# Lua-состояние тоже выведено наружу через env-хуки движка:
#   Z2K_STATE_DIR_OVERRIDE  (files/lua/z2k-state-persist.lua)
#   Z2K_TCP16_ASN/NETS/SNI, Z2K_SNI_PIN (files/lua/z2k-tcp16.lua)
#
# Использование: . paths.sh; . env.sh; затем . $Z2K_LIB/utils.sh ...
#
# Предусловие: пути уже выставлены (paths.sh подключён вызывающим).
# Автосорсинг paths.sh здесь невозможен: при `. env.sh` $0 — это вызывающий.

# Корень payload — единственная точка входа upstream-конвейера.
ZAPRET2_DIR="${ZAPRET2_DIR:-$Z2K_ROOT}"
CONFIG_DIR="${CONFIG_DIR:-$Z2K_CONF_DIR}"
LISTS_DIR="${LISTS_DIR:-$Z2K_LISTS_DIR}"
export ZAPRET2_DIR CONFIG_DIR LISTS_DIR

# FWTYPE для ГЕНЕРАЦИИ конфига: современный OpenWrt = nftables/fw4.
# В сам конфиг не пишется (там остаётся закомментированным — zapret2
# linux_fwtype автодетектит backend при каждом apply). Нужно только ветке
# IPv6-автодетекта create_official_config (проверка наличия nft).
FWTYPE="${FWTYPE:-nftables}"
export FWTYPE

# Lua: состояние autocircular — в persistent /etc/z2k/state.
Z2K_STATE_DIR_OVERRIDE="${Z2K_STATE_DIR_OVERRIDE:-$Z2K_STATE}"
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-$Z2K_TMP}"
export Z2K_STATE_DIR_OVERRIDE Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE

# Lua: tcp16-карты. ASN/SNI — рантайм-состояние (/etc), NETS/PIN — shipped.
Z2K_TCP16_ASN="${Z2K_TCP16_ASN:-$Z2K_STATE/tcp16_asn.txt}"
Z2K_TCP16_NETS="${Z2K_TCP16_NETS:-$Z2K_LISTS_DIR/tcp16_nets.txt}"
Z2K_TCP16_SNI="${Z2K_TCP16_SNI:-$Z2K_STATE/tcp16_sni.txt}"
Z2K_SNI_PIN="${Z2K_SNI_PIN:-$Z2K_LISTS_DIR/sni_wl_pin.txt}"
export Z2K_TCP16_ASN Z2K_TCP16_NETS Z2K_TCP16_SNI Z2K_SNI_PIN

# Конфиг, который читает zapret2 runtime (QNUM/marks/ports/offload):
# это и есть наш канонический /etc/z2k/config (см. generate.sh).
ZAPRET_CONFIG="${ZAPRET_CONFIG:-$Z2K_CONFIG}"
export ZAPRET_CONFIG

# LAN-сети для zapret2 ifsets (значение задаёт uci.sh, здесь — дефолт).
OPENWRT_LAN="${OPENWRT_LAN:-lan}"
export OPENWRT_LAN
