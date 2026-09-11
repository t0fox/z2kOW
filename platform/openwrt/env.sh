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

# Тот же файл глазами shell-стороны: шаг reset-state апдейтера чистит
# ${STATE_FILE} (дефолт — keenetic-путь; здесь указываем наш).
STATE_FILE="${STATE_FILE:-$Z2K_STATE/state.tsv}"
export STATE_FILE

# Пара 3-way merge extra-domains (au_merge_extra_domains): shipped-база из
# payload, runtime-мерж в user-lists. Keenetic-дефолты — в самом хуке.
Z2K_EXTRA_DOMAINS_SHIPPED="${Z2K_EXTRA_DOMAINS_SHIPPED:-$Z2K_LISTS_DIR/extra-domains.txt}"
Z2K_EXTRA_DOMAINS_RUNTIME="${Z2K_EXTRA_DOMAINS_RUNTIME:-$Z2K_USER_LISTS/extra-domains.txt}"
export Z2K_EXTRA_DOMAINS_SHIPPED Z2K_EXTRA_DOMAINS_RUNTIME

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

# Канонический конфиг для шагов апдейтера (regen-config/validate-config/
# restart-service): тот же файл. PLATFORM HOOK в lib/auto_update.sh читает
# именно эту переменную; unset = keenetic-путь, там её никто не выставляет.
Z2K_CONFIG_FILE="${Z2K_CONFIG_FILE:-$Z2K_CONFIG}"
export Z2K_CONFIG_FILE

# Init-скрипт для шага restart-service семантики (au_step_restart_service
# вызывает "$INIT_SCRIPT restart"). utils.sh уважает предустановку.
INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"
export INIT_SCRIPT

# Каталог Go-бинарников для шага refresh-binaries (au_step_refresh_binaries
# кладёт в ${Z2K_AU_SBIN}). Persistent, согласно storage-модели.
Z2K_AU_SBIN="${Z2K_AU_SBIN:-$Z2K_BIN}"
export Z2K_AU_SBIN

# LAN-сети для zapret2 ifsets (значение задаёт uci.sh, здесь — дефолт).
OPENWRT_LAN="${OPENWRT_LAN:-lan}"
export OPENWRT_LAN
