#!/bin/sh
# platform/openwrt/generate.sh - генерация /etc/z2k/config штатным генератором.
#
# Вызывает НЕТРОНУТЫЙ upstream create_official_config (lib/config_official.sh)
# с явным путём канонического конфига. Все чтения стратегий/листов идут через
# ZAPRET2_DIR=$Z2K_ROOT (env.sh), supplementary-чтения ${ZAPRET2_DIR}/config —
# через симлинк bootstrap.sh. Результат — zapret2-совместимый конфиг:
# NFQWS2_OPT с реальными z2k-стратегиями + QNUM/marks/ports/offload для
# firewall-половины (firewall.sh скармливает этот же файл zapret2-функциям).
#
# Требует подключённых lib/utils.sh + lib/strategies.sh + lib/config_official.sh.

z2k_ow_generate() {
    [ -f "$Z2K_CONFIG" ] || { echo "z2k-openwrt: нет $Z2K_CONFIG (сначала bootstrap)" >&2; return 1; }
    create_official_config "$Z2K_CONFIG" || return 1
    # Мост $Z2K_ROOT/config обязан остаться симлинком: генератор пишет
    # "$Z2K_CONFIG.new.$$"+rename по ЯВНОМУ пути, но если кто-то начнёт
    # писать в ${ZAPRET2_DIR}/config — rename подменит симлинк файлом и
    # /etc/z2k/config протухнет. Ловим класс целиком.
    if [ ! -L "$Z2K_ROOT/config" ]; then
        echo "z2k-openwrt: $Z2K_ROOT/config больше не симлинк — кто-то пишет в \${ZAPRET2_DIR}/config" >&2
        return 1
    fi
    return 0
}
