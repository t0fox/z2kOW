#!/bin/sh
# platform/openwrt/firewall.sh - граница владения firewall/nft.
#
# ТАБЛИЦА ВЛАДЕНИЯ (единственная, см. contract):
#   процесс nfqws2 ............ z2k procd-сервис (init.d/z2k). Причина: OPT_BASE
#     stock zapret2-init жёстко зашит в скрипте без z2k lua-init/--blob/
#     --bind-fix — через конфиг не инжектится, делегировать нечего.
#   nft-таблица zapret ....... zapret2 runtime (zapret_apply_firewall/remove).
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

# --- z2k custom.d: точка расширения для будущих TG/RT/WARP-демонов ---
# Контракт повторяет zapret2 custom_runner, отдельный неймспейс:
# каждый $Z2K_CUSTOM_DIR/*.sh может определить z2k_custom_daemons(),
# которая вызывается с $1=1 (start) / 0 (stop). DISABLE_CUSTOM=1 (дефолт
# upstream) раннер гасит целиком.
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
