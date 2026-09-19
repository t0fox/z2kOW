#!/bin/sh
# platform/openwrt/paths.sh - единый источник OpenWrt-путей z2k.
#
# Единственное место, где записаны литералы /etc/z2k, /usr/lib/z2k, /tmp/z2k.
# Все остальные файлы адаптера (и package/openwrt) берут пути отсюда.
# Каждая переменная переопределяема окружением — это же используют тесты.
#
# Filesystem-модель (см. docs/openwrt-adapter-contract.md):
#   /etc/z2k/          persistent: config, state/, user-lists/, conf/
#   /usr/lib/z2k/      payload (read-only): lib/, lua/, fake/, lists/,
#                      extra_strats/, manifests/, platform/
#   /tmp/z2k/          transient: runtime/, locks/, logs/, downloads/, generated/

# --- persistent ---
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"
Z2K_CONFIG="${Z2K_CONFIG:-$Z2K_ETC/config}"
Z2K_STATE="${Z2K_STATE:-$Z2K_ETC/state}"
Z2K_USER_LISTS="${Z2K_USER_LISTS:-$Z2K_ETC/user-lists}"
# CONFIG_DIR — имя узнает upstream (lib/utils.sh строит из него пути
# strategies.conf/quic_strategies.conf). Значение — наше.
Z2K_CONF_DIR="${Z2K_CONF_DIR:-$Z2K_ETC/conf}"

# --- payload (read-only на роутере) ---
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_BIN="${Z2K_BIN:-$Z2K_ROOT/bin}"
Z2K_LIB="${Z2K_LIB:-$Z2K_ROOT/lib}"
Z2K_LUA_DIR="${Z2K_LUA_DIR:-$Z2K_ROOT/lua}"
Z2K_FAKE_DIR="${Z2K_FAKE_DIR:-$Z2K_ROOT/fake}"
Z2K_LISTS_DIR="${Z2K_LISTS_DIR:-$Z2K_ROOT/lists}"
Z2K_EXTRA_STRATS_DIR="${Z2K_EXTRA_STRATS_DIR:-$Z2K_ROOT/extra_strats}"
# Манифесты стратегий лежат в КОРНЕ payload (как на Keenetic): regen-step
# читает ${ZAPRET2_DIR}/strats_new2.txt напрямую. Переменная — для явности
# вызовов materialize.sh (каталог всё равно передаётся параметром).
Z2K_MANIFESTS_DIR="${Z2K_MANIFESTS_DIR:-$Z2K_ROOT}"
Z2K_ADAPTER_DIR="${Z2K_ADAPTER_DIR:-$Z2K_ROOT/platform/openwrt}"
# TLS bundle для TG-демона (доставляется updater'ом через files/etc/*,
# release_map: files/etc/* -> $Z2K_ROOT/etc/). Переопределяем для тестов.
Z2K_TG_TLS_BUNDLE="${Z2K_TG_TLS_BUNDLE:-$Z2K_ROOT/etc/z2k-roots.pem}"

# --- transient (tmpfs) ---
Z2K_TMP="${Z2K_TMP:-/tmp/z2k}"
Z2K_RUN="${Z2K_RUN:-$Z2K_TMP/runtime}"
Z2K_LOCKS="${Z2K_LOCKS:-$Z2K_TMP/locks}"
Z2K_LOG="${Z2K_LOG:-$Z2K_TMP/logs}"
Z2K_DOWNLOADS="${Z2K_DOWNLOADS:-$Z2K_TMP/downloads}"
Z2K_GENERATED="${Z2K_GENERATED:-$Z2K_TMP/generated}"
# Маркер dataplane-ready: создаётся start_service ПОСЛЕДНИМ (все required
# прошли), снимается ПЕРВЫМ в stop и при любом failed start. /status и
# health-гейты различают по нему running-процесс от готового dataplane.
Z2K_CORE_READY="${Z2K_CORE_READY:-$Z2K_RUN/core-ready}"
# fw4's user acceleration settings are snapshotted only while z2k owns the
# dataplane and restored verbatim on a clean stop/rollback.
Z2K_FW4_OFFLOAD_STATE="${Z2K_FW4_OFFLOAD_STATE:-$Z2K_STATE/fw4-offload.state}"
Z2K_FW4_RELOAD="${Z2K_FW4_RELOAD:-/etc/init.d/firewall}"
export Z2K_FW4_OFFLOAD_STATE Z2K_FW4_RELOAD

# --- zapret2 runtime (чужое дерево, только читаем) ---
# Каталог установки zapret2-z2k OpenWrt runtime: nfq2/nfqws2, common/*.sh,
# init.d/openwrt/functions, lua/zapret-{lib,antidpi,auto}.lua.
Z2K_ZAPRET2_RUNTIME="${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}"
Z2K_NFQWS2="${Z2K_NFQWS2:-$Z2K_ZAPRET2_RUNTIME/nfq2/nfqws2}"

# z2k_ow_paths_check — провалиться, если обязательные каталогы отсутствуют.
# $1 — режим: "payload" (ro-ветка) или "all" (включая persistent/tmp).
z2k_ow_paths_check() {
    local _mode="${1:-payload}" _d _missing=""
    for _d in "$Z2K_ROOT" "$Z2K_LIB" "$Z2K_LUA_DIR" "$Z2K_FAKE_DIR" \
             "$Z2K_LISTS_DIR" "$Z2K_EXTRA_STRATS_DIR"; do
        [ -d "$_d" ] || _missing="$_missing $_d"
    done
    if [ "$_mode" = "all" ]; then
        for _d in "$Z2K_ETC" "$Z2K_STATE" "$Z2K_RUN" "$Z2K_LOG"; do
            [ -d "$_d" ] || _missing="$_missing $_d"
        done
    fi
    if [ -n "$_missing" ]; then
        echo "z2k-openwrt: missing directories:$_missing" >&2
        return 1
    fi
    return 0
}
