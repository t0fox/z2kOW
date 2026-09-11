#!/bin/sh
# platform/openwrt/materialize.sh - материализация Strategy.txt из манифестов.
#
# Используется ДВАЖДЫ одним и тем же кодом:
#   1. на этапе сборки пакета (payload read-only — Strategy.txt запекаются
#      в /usr/lib/z2k/extra_strats прематериализованными);
#   2. в тестах (доказательство closure на реальном конвейере).
# На роутере в boot-пути НЕ вызывается: только проверка наличия (bootstrap.sh).
#
# Требует подключённых lib/utils.sh + lib/strategies.sh и выставленных
# ZAPRET2_DIR (корень назначения extra_strats) и CONFIG_DIR (куда класть
# strategies.conf/quic_strategies.conf).
# $1 — каталог манифестов (strats_new2.txt, quic_strats.ini).

z2k_ow_materialize() {
    local _manifests="$1"
    [ -n "$_manifests" ] || { echo "z2k-openwrt: materialize: нужен каталог манифестов" >&2; return 1; }
    [ -f "$_manifests/strats_new2.txt" ] || { echo "z2k-openwrt: нет $_manifests/strats_new2.txt" >&2; return 1; }
    [ -f "$_manifests/quic_strats.ini" ] || { echo "z2k-openwrt: нет $_manifests/quic_strats.ini" >&2; return 1; }

    mkdir -p "$CONFIG_DIR" || return 1
    generate_strategies_conf "$_manifests/strats_new2.txt" "$CONFIG_DIR/strategies.conf" || return 1
    generate_quic_strategies_conf "$_manifests/quic_strats.ini" "$CONFIG_DIR/quic_strategies.conf" || return 1
    create_default_strategy_files || return 1
}
