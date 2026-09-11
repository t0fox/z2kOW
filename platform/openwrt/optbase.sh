#!/bin/sh
# platform/openwrt/optbase.sh - сборка базовой части argv nfqws2 (OPT_BASE).
#
# Логика — порт соответствующего блока Keenetic S99zapret2.new (LUAOPT,
# --blob-регистрации, --bind-fix, --ipcache-hostname): это init-логика, а не
# common-библиотека, поэтому её место — здесь, в адаптере.
# Пути — через env.sh ($Z2K_LUA_DIR/$Z2K_FAKE_DIR payload, fork-lua из
# $Z2K_ZAPRET2_RUNTIME). Требует выставленных WS_USER/DESYNC_MARK (из
# прочитанного /etc/z2k/config) — дефолты совпадают с каноническими z2k.
#
# Использование: . env.sh; . /etc/z2k/config; _base=$(z2k_ow_optbase)

# z2k_ow_optbase — печатает OPT_BASE в stdout.
z2k_ow_optbase() {
    local _lib _antidpi _auto _f _opt=""

    # Порядок lua-init — как в S99: сначала fork (lib→antidpi→auto),
    # затем z2k-расширения (alert/quic-silence/tcp16 — детекторы, затем
    # fooling/range-rand/modern-core, последним state-persist, который
    # оборачивает circular из zapret-auto).
    _lib="$Z2K_ZAPRET2_RUNTIME/lua/zapret-lib.lua"
    [ -f "$_lib" ] || _lib="$_lib.gz"
    _antidpi="$Z2K_ZAPRET2_RUNTIME/lua/zapret-antidpi.lua"
    [ -f "$_antidpi" ] || _antidpi="$_antidpi.gz"
    _opt="--lua-init=@$_lib --lua-init=@$_antidpi"
    _auto="$Z2K_ZAPRET2_RUNTIME/lua/zapret-auto.lua"
    [ -f "$_auto" ] || _auto="$_auto.gz"
    [ -f "$_auto" ] && _opt="$_opt --lua-init=@$_auto"
    for _f in z2k-alert z2k-quic-silence z2k-tcp16 z2k-fooling-ext \
             z2k-range-rand z2k-modern-core z2k-state-persist; do
        [ -f "$Z2K_LUA_DIR/$_f.lua" ] && _opt="$_opt --lua-init=@$Z2K_LUA_DIR/$_f.lua"
    done
    # NOTE: переходный гард z2k-silence.lua из S99 здесь НЕ нужен: это
    # Keenetic-only защита апгрейда p-84.4…p-84.6, в свежем payload файла нет.

    _opt="--user=${WS_USER:-nobody} --fwmark=${DESYNC_MARK:-0x40000000} --bind-fix4 --bind-fix6 $_opt"
    _opt="$_opt --ipcache-hostname=1"
    [ "${IPBLOCK_DETECT:-0}" = "1" ] && _opt="$_opt --ipblock-detect=on"

    # Регистрации fake-блобов. Таблица имя→файл — из S99 (порядок и состав
    # 1:1, там же задокументировано снятие неиспользуемых). Путь — payload
    # $Z2K_FAKE_DIR (наш маппинг files/fake/* → fake/, см. package Makefile).
    # Полный список сверяется тестом closure с blob=*-ссылками стратегий.
    for _b in "tls_max_ru:tls_clienthello_max_ru.bin" \
               "tls_clienthello_14:tls_clienthello_14.bin" \
               "tls_clienthello_www_google_com:tls_clienthello_www_google_com.bin" \
               "stun:stun.bin" \
               "tls_clienthello_4pda_to:tls_clienthello_4pda_to.bin" \
               "tls_clienthello_vk_com:tls_clienthello_vk_com.bin" \
               "tls_clienthello_gosuslugi_ru:tls_clienthello_gosuslugi_ru.bin" \
               "tls_clienthello_activated:tls_clienthello_activated.bin" \
               "syn_packet:syn_packet.bin" \
               "quic_google:quic_initial_www_google_com.bin" \
               "quic5:quic_5.bin" \
               "quic4:quic_4.bin" \
               "quic6:quic_6.bin" \
               "quic1:quic_1.bin" \
               "quic_rutracker:quic_initial_rutracker_org.bin" \
               "quic_dbankcloud:quic_initial_dbankcloud_ru.bin" \
               "tls_clienthello_www_onetrust_com:tls_clienthello_www_onetrust_com.bin" \
               "t2:t2.bin"; do
        [ -s "$Z2K_FAKE_DIR/${_b#*:}" ] \
            && _opt="$_opt --blob=${_b%%:*}:@$Z2K_FAKE_DIR/${_b#*:}"
    done

    printf '%s\n' "$_opt"
}
