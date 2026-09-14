#!/bin/sh
# platform/openwrt/firewall.sh - граница владения firewall/nft.
#
# ТАБЛИЦА ВЛАДЕНИЯ (единственная, см. contract):
#   процесс nfqws2 ............ z2k procd-сервис (init.d/z2k). Причина: OPT_BASE
#     stock zapret2-init жёстко зашит в скрипте без z2k lua-init/--blob/
#     --bind-fix — через конфиг не инжектится, делегировать нечего.
#   nft-таблица zapret2 ...... zapret2 runtime (zapret_apply_firewall/remove).
#   lan/wan ifsets ........... zapret2 runtime (reload_ifsets по hotplug).
#   QNUM/marks/ports ......... ОБЩИЕ: лежат в /etc/z2k/config, демон и firewall
#     читают один файл (тест сверяет равенство).
#   flow offload ............. zapret2 runtime (FLOWOFFLOAD из того же конфига;
#     своих offload-правил адаптер НЕ создаёт — см. тест ownership).
#   custom.d ................. РАЗДЕЛЬНО: zapret2/custom.d — runtime'а (пуст
#     upstream); z2k/custom.d — наш раннер ниже (будущие TG/RT/WARP-хуки).
#
# Делегирование — вызовом РЕАЛЬНЫХ функций zapret2 (functions сорсится лениво
# здесь; на тестах без runtime — только раннер custom.d, он автономен).

_Z2K_OW_FW_SOURCED=""

z2k_ow_fw_source() {
    [ -n "$_Z2K_OW_FW_SOURCED" ] && return 0
    local _f="$Z2K_ZAPRET2_RUNTIME/init.d/openwrt/functions"
    [ -f "$_f" ] || { echo "z2k-openwrt: нет zapret2 runtime: $_f" >&2; return 1; }
    # shellcheck disable=SC1090
    . "$_f" || return 1
    _Z2K_OW_FW_SOURCED=1
}

# Применить/снять firewall zapret2 (читает $ZAPRET_CONFIG=/etc/z2k/config).
z2k_ow_fw_apply() { z2k_ow_fw_source || return 1; zapret_apply_firewall; }
z2k_ow_fw_remove() { z2k_ow_fw_source || return 1; zapret_unapply_firewall; }
z2k_ow_fw_reload_ifsets() { z2k_ow_fw_source || return 1; zapret_reload_ifsets; }

# z2k_ow_runtime_preflight — fail loudly ДО procd (start gate).
# Ложный success прошлого live: POST /service/start -> job exit=0, процесс
# exit=127 (нет бинарника), UI потом показывал stopped. Проверяем здесь:
# демон +x, functions, fork-lua (plain или .gz, как в optbase.sh).
# Сообщение — точный путь (runtime_missing: ...); rc!=0 роняет start_service
# до создания instance, а webpanel job — в exit!=0.
z2k_ow_runtime_preflight() {
    local _n _rt="${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}"
    local _nfqws2="${Z2K_NFQWS2:-$_rt/nfq2/nfqws2}"
    [ -x "$_nfqws2" ] || {
        echo "z2k-openwrt: runtime_missing: $_nfqws2 (поставьте z2k-zapret2-runtime)" >&2
        return 1
    }
    [ -f "$_rt/init.d/openwrt/functions" ] || {
        echo "z2k-openwrt: runtime_missing: $_rt/init.d/openwrt/functions" >&2
        return 1
    }
    for _n in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
        if [ ! -f "$_rt/lua/$_n" ] && [ ! -f "$_rt/lua/$_n.gz" ]; then
            echo "z2k-openwrt: runtime_missing: $_rt/lua/$_n" >&2
            return 1
        fi
    done
    # Required z2k-owned binaries (инвариант fresh-install completeness):
    # tg-mtproxy-client, z2k-rt-proxy, z2k-detect ставит ensure-binaries
    # (postinst best-effort / updater); WARP — optional (кнопка), здесь
    # не проверяется. Отсутствующий required — громкий отказ, а не
    # молчаливый skip: silent-degraded core хуже нестартанувшего.
    for _n in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
        if [ ! -x "${Z2K_BIN:-/usr/lib/z2k/bin}/$_n" ]; then
            echo "z2k-openwrt: missing required binary: ${Z2K_BIN:-/usr/lib/z2k/bin}/$_n (fresh install incomplete: нет сети для ensure?)" >&2
            return 1
        fi
    done
    return 0
}

# --- z2k custom.d: точка расширения для будущих RT/WARP-демонов ---
# Контракт повторяет zapret2 custom_runner, отдельный неймспейс:
# каждый $Z2K_CUSTOM_DIR/*.sh может определить z2k_custom_daemons(),
# которая вызывается с $1=1 (start) / 0 (stop). DISABLE_CUSTOM=1 (дефолт
# upstream) раннер гасит целиком.
#
# TG (Stage 3) через этот раннер НЕ идёт осознанно: DISABLE_CUSTOM не должен
# гасить first-class feature — tg.sh вызывается из init.d/z2k напрямую.
Z2K_CUSTOM_DIR="${Z2K_CUSTOM_DIR:-$Z2K_ADAPTER_DIR/custom.d}"

z2k_ow_custom_daemons() {
    [ "${DISABLE_CUSTOM:-1}" = "1" ] && return 0
    [ -d "$Z2K_CUSTOM_DIR" ] || return 0
    local _script
    for _script in "$Z2K_CUSTOM_DIR"/*.sh; do
        [ -f "$_script" ] || continue
        unset -f z2k_custom_daemons
        # shellcheck disable=SC1090
        . "$_script"
        if command -v z2k_custom_daemons >/dev/null 2>&1; then
            z2k_custom_daemons "$1" || return 1
        fi
    done
    return 0
}
