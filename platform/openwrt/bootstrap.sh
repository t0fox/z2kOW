#!/bin/sh
# platform/openwrt/bootstrap.sh - идемпотентный bootstrap persistent-состояния.
#
# Вызывается из procd-сервиса перед генерацией (и из package postinst).
# НЕ пишет в payload ($Z2K_ROOT read-only): только /etc/z2k и /tmp/z2k.
#
# Мосты, которые здесь создаются (обоснование — в contract):
#   $Z2K_ROOT/config → /etc/z2k/config (чтения ${ZAPRET2_DIR}/config внутри
#     generate_*; запись идёт явным $1 мимо симлинка, он в безопасности);
#   lists/whitelist.txt → /etc/z2k/user-lists/whitelist.txt (user-owned);
#   lists/discovered-domains.txt → /etc/z2k/state/discovered-domains.txt
#     (публикации демона; генератор ссылается безусловно).
#
# Требует выставленных путей (env.sh).

z2k_ow_bootstrap() {
    # --- каталоги ---
    mkdir -p "$Z2K_ETC" "$Z2K_STATE" "$Z2K_USER_LISTS" "$Z2K_CONF_DIR" \
             "$Z2K_RUN" "$Z2K_LOCKS" "$Z2K_LOG" "$Z2K_DOWNLOADS" "$Z2K_GENERATED" \
        || return 1

    # --- канонический конфиг ---
    if [ ! -f "$Z2K_CONFIG" ]; then
        if [ -f "$Z2K_ROOT/share/config.default" ]; then
            cp -f "$Z2K_ROOT/share/config.default" "$Z2K_CONFIG" || return 1
        else
            echo "z2k-openwrt: нет ни $Z2K_CONFIG, ни дефолта" >&2
            return 1
        fi
    fi

    # --- мост supplementary-reads ---
    if [ ! -L "$Z2K_ROOT/config" ]; then
        [ -e "$Z2K_ROOT/config" ] && {
            echo "z2k-openwrt: $Z2K_ROOT/config существует и не симлинк — отказываюсь" >&2
            return 1
        }
        ln -s "$Z2K_CONFIG" "$Z2K_ROOT/config" || return 1
    fi

    # --- stateful-члены lists (пустые плейсхолдеры по образцу install.sh) ---
    if [ ! -L "$Z2K_LISTS_DIR/whitelist.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/whitelist.txt" ] && {
            echo "z2k-openwrt: lists/whitelist.txt существует и не симлинк" >&2
            return 1
        }
        ln -s "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_LISTS_DIR/whitelist.txt" || return 1
    fi
    if [ ! -L "$Z2K_LISTS_DIR/discovered-domains.txt" ]; then
        [ -e "$Z2K_LISTS_DIR/discovered-domains.txt" ] && {
            echo "z2k-openwrt: lists/discovered-domains.txt существует и не симлинк" >&2
            return 1
        }
        ln -s "$Z2K_STATE/discovered-domains.txt" "$Z2K_LISTS_DIR/discovered-domains.txt" || return 1
    fi
    for _f in "$Z2K_USER_LISTS/whitelist.txt" "$Z2K_STATE/discovered-domains.txt" \
             "$Z2K_STATE/tcp16_asn.txt" "$Z2K_STATE/tcp16_sni.txt"; do
        [ -e "$_f" ] || : > "$_f" || return 1
    done

    # --- Strategy.txt прематериализованы сборкой; отсутствие = fail-closed ---
    for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
        [ -s "$Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt" ] || {
            echo "z2k-openwrt: нет $Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt (сборка не материализовала стратегии)" >&2
            return 1
        }
    done

    # --- fork-lua в runtime: только предупреждение (зависимость пакета) ---
    for _f in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f" ] && \
           [ ! -f "$Z2K_ZAPRET2_RUNTIME/lua/$_f.gz" ]; then
            echo "z2k-openwrt: предупреждение: нет $Z2K_ZAPRET2_RUNTIME/lua/$_f (поставьте zapret2 runtime)" >&2
        fi
    done
    return 0
}
