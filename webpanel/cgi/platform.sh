#!/bin/sh
# webpanel/cgi/platform.sh - tiny platform compatibility frontend (Stage 6).
#
# Keenetic (Z2K_PLATFORM unset/keenetic): NO-OP, current behavior default.
# OpenWrt: frozen-ownership env map + source PACKAGE adapter
# ($Z2K_ROOT/platform/openwrt/webpanel.sh) with OS-effect helpers and
# function overrides below. Sourced by api.sh between auth.sh and actions.sh.
# No actions-openwrt.sh / api-openwrt.sh / app-openwrt.js forks.

if [ "${Z2K_PLATFORM:-keenetic}" != "openwrt" ]; then
    return 0 2>/dev/null || true
fi

# --- пути: замороженный адаптер, затем панельный домен (никакого
# дублирования канальных дефолтов и никакого /opt-symlink костыля) ---
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
export Z2K_ROOT
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" 2>/dev/null || return 0
# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/env.sh" 2>/dev/null || return 0

# Панельные пути поверх адаптерных (панельный домен; env.sh их не знает).
# Updater-owned и user-owned списки не смешиваются никогда (§5 контракта).
CONFIG_FILE="${CONFIG_FILE:-$Z2K_CONFIG}"
WHITELIST_FILE="${WHITELIST_FILE:-$Z2K_USER_LISTS/whitelist.txt}"
EXTRA_DOMAINS_FILE="${EXTRA_DOMAINS_FILE:-$Z2K_USER_LISTS/extra-domains.txt}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$Z2K_USER_LISTS/exclude.txt}"
CUSTOM_STRAT_DIR="${CUSTOM_STRAT_DIR:-$Z2K_USER_LISTS/custom-strategies}"
WARP_SCRIPT="${WARP_SCRIPT:-$Z2K_ROOT/platform/openwrt/warp.sh}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$Z2K_USER_LISTS/warp}"
WARP_GAMES_DIR="${WARP_GAMES_DIR:-$Z2K_LISTS_DIR/warp/games}"
WARP_DEVICE="${WARP_DEVICE:-$Z2K_STATE/warp/device.json}"
WARP_INIT="${WARP_INIT:-/etc/init.d/z2k}"
STATE_FILE="${STATE_FILE:-$Z2K_STATE/state.tsv}"
DNS_CHECK_SCRIPT="${DNS_CHECK_SCRIPT:-$Z2K_ROOT/z2k-dns-check.sh}"
DNS_CHECK_OWN="${DNS_CHECK_OWN:-$Z2K_USER_LISTS/dns-check.txt}"
Z2K_DETECT_BIN="${Z2K_DETECT_BIN:-$Z2K_BIN/z2k-detect}"
AU_TAG_FILE="${AU_TAG_FILE:-$Z2K_STATE/installed-tag}"
AU_SCRIPT="${AU_SCRIPT:-$Z2K_ROOT/platform/openwrt/update.sh}"
DEBUG_FLAG_FILE="${DEBUG_FLAG_FILE:-${Z2K_TMP}/debug.flag}"
Z2K_PANEL_CONFIG="${Z2K_PANEL_CONFIG:-$Z2K_CONFIG}"
Z2K_PANEL_DIR="${Z2K_PANEL_DIR:-$Z2K_ETC/webpanel}"
Z2K_PAYLOAD_MARKER="${Z2K_PAYLOAD_MARKER:-$Z2K_ETC/.payload-initialized}"
Z2K_AU_MANIFEST_URL="${Z2K_AU_MANIFEST_URL:-$Z2K_AU_REPO_RAW/UPDATES.json}"
Z2K_INIT="${Z2K_INIT:-/etc/init.d/z2k}"
INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"
export CONFIG_FILE WHITELIST_FILE EXTRA_DOMAINS_FILE EXCLUDE_FILE \
    CUSTOM_STRAT_DIR WARP_SCRIPT WARP_LISTS_DIR WARP_GAMES_DIR WARP_DEVICE \
    WARP_INIT STATE_FILE DNS_CHECK_SCRIPT DNS_CHECK_OWN Z2K_DETECT_BIN \
    AU_TAG_FILE AU_SCRIPT Z2K_PANEL_CONFIG Z2K_PANEL_DIR Z2K_PAYLOAD_MARKER \
    Z2K_AU_MANIFEST_URL Z2K_INIT INIT_SCRIPT DEBUG_FLAG_FILE

# sbin — вперёд при отсутствии (как update.sh): операторский PATH не сносим.
case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) export PATH="/usr/sbin:/sbin:$PATH" ;;
esac

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/webpanel.sh" 2>/dev/null || true

# --- overrides: те же имена, OS-эффект через замороженные адаптеры ---

# Core service state: реальный procd (не pgrep; класс ошибки Stage 5).
is_running() {
    "${Z2K_INIT:-/etc/init.d/z2k}" running >/dev/null 2>&1
}

is_installed() {
    [ -f "${Z2K_PAYLOAD_MARKER:-/etc/z2k/.payload-initialized}" ]
}

# TG: тот же TG_PROXY_USER_DISABLED-флаг; вместо S98/S97 — converge
# существующего z2k/procd (instance владеет Stage 3). Демона из CGI
# не стартуем/не убиваем, nft не пишем.
tunnel_enable() {
    local cfg="${CONFIG_FILE:-/etc/z2k/config}" _init="${Z2K_INIT:-/etc/init.d/z2k}"
    if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg" 2>/dev/null; then
        sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=0/' "$cfg" 2>/dev/null
    fi
    echo "Применяю через z2k/procd..."
    [ -x "$_init" ] || { echo "нет $_init" >&2; return 1; }
    "$_init" reload 2>&1
}

tunnel_disable() {
    local cfg="${CONFIG_FILE:-/etc/z2k/config}" _init="${Z2K_INIT:-/etc/init.d/z2k}"
    if grep -q '^TG_PROXY_USER_DISABLED=' "$cfg" 2>/dev/null; then
        sed -i 's/^TG_PROXY_USER_DISABLED=.*/TG_PROXY_USER_DISABLED=1/' "$cfg" 2>/dev/null
    else
        echo "TG_PROXY_USER_DISABLED=1" >> "$cfg" 2>/dev/null
    fi
    echo "Применяю через z2k/procd..."
    [ -x "$_init" ] || { echo "нет $_init" >&2; return 1; }
    "$_init" reload 2>&1
}

# Keenetic-only: честный отказ вместо молчаливой пустышки.
toggle_ppe() {
    echo "PPE toggle недоступен на OpenWrt (offload владеет zapret2 runtime)" >&2
    return 1
}

policy_status() {
    printf 'name=|exclude=0|exists=0\n'
}

policy_save() {
    echo "Keenetic policy недоступна на OpenWrt (эквивалента нет)" >&2
    return 1
}

# Соседи: провайдер платформы вместо ndmc (тот же \037 TSV).
warp_neighbors() {
    wp_neighbors
}

# Full z2k uninstall из браузера запрещён: package ownership уважается.
uninstall_async() {
    echo "удаление z2k на OpenWrt — через пакетный менеджер роутера" >&2
    return 1
}

# Capability JSON для /status (только openwrt; Keenetic ответы не меняются).
wp_capabilities_json() {
    printf '"platform":"openwrt","capabilities":{"policy":false,"ppe":false,"tcp16":false,"diag":false,"warp":true,"telegram":true,"uninstall":false}'
}
