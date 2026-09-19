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

# Здоровье адаптера: любой несорсящийся/отсутствующий компонент = controlled
# PLATFORM_UNAVAILABLE (fail-closed audit I). Молчаливый fallback в Keenetic
# defaults запрещён: мутации тогда действовали бы на чужие пути с success.
Z2K_PLATFORM_STATUS="ok"
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
export Z2K_ROOT
# shellcheck disable=SC1090,SC1091
if [ -f "$Z2K_ROOT/platform/openwrt/paths.sh" ]; then
    . "$Z2K_ROOT/platform/openwrt/paths.sh" 2>/dev/null || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
else
    Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
fi
# shellcheck disable=SC1090,SC1091
if [ -f "$Z2K_ROOT/platform/openwrt/env.sh" ]; then
    . "$Z2K_ROOT/platform/openwrt/env.sh" 2>/dev/null || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
else
    Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
fi
if [ -f "$Z2K_ROOT/platform/openwrt/tg.sh" ]; then
    . "$Z2K_ROOT/platform/openwrt/tg.sh" 2>/dev/null || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
else
    z2k_ow_tg_pids() { return 1; }
    z2k_ow_tg_listeners_ready() { return 1; }
fi
# Reassert persistent list root after the platform env map.  This keeps the
# panel safe in mixed-version sysroots where an older env.sh exported it empty.
Z2K_USER_LISTS="${Z2K_USER_LISTS:-$Z2K_ETC/user-lists}"
export Z2K_USER_LISTS
Z2K_NFQWS2="${Z2K_NFQWS2:-${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/nfq2/nfqws2}"
export Z2K_NFQWS2
[ -f "$Z2K_ROOT/platform/openwrt/paths.sh" ] || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
[ -f "$Z2K_ROOT/platform/openwrt/env.sh" ] || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
[ -f "$Z2K_ROOT/platform/openwrt/webpanel.sh" ] || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"

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
AUTOHOSTLIST_DOMAINS_FILE="${AUTOHOSTLIST_DOMAINS_FILE:-$Z2K_STATE/autohostlist-domains.txt}"
Z2K_PANEL_CONFIG="${Z2K_PANEL_CONFIG:-$Z2K_CONFIG}"
Z2K_PANEL_DIR="${Z2K_PANEL_DIR:-$Z2K_ETC/webpanel}"
Z2K_PAYLOAD_MARKER="${Z2K_PAYLOAD_MARKER:-$Z2K_ETC/.payload-initialized}"
Z2K_AU_MANIFEST_URL="${Z2K_AU_MANIFEST_URL:-$Z2K_AU_REPO_RAW/UPDATES.json}"
AU_MANIFEST_CACHE="${AU_MANIFEST_CACHE:-${Z2K_AU_TMP_DIR:-$Z2K_TMP}/UPDATES.json}"
Z2K_INIT="${Z2K_INIT:-/etc/init.d/z2k}"
INIT_SCRIPT="${INIT_SCRIPT:-${Z2K_INIT:-/etc/init.d/z2k}}"
export CONFIG_FILE WHITELIST_FILE EXTRA_DOMAINS_FILE EXCLUDE_FILE \
    CUSTOM_STRAT_DIR WARP_SCRIPT WARP_LISTS_DIR WARP_GAMES_DIR WARP_DEVICE \
    WARP_INIT STATE_FILE DNS_CHECK_SCRIPT DNS_CHECK_OWN Z2K_DETECT_BIN \
    AU_TAG_FILE AU_SCRIPT Z2K_PANEL_CONFIG Z2K_PANEL_DIR Z2K_PAYLOAD_MARKER \
    Z2K_AU_MANIFEST_URL AU_MANIFEST_CACHE Z2K_INIT INIT_SCRIPT DEBUG_FLAG_FILE \
    AUTOHOSTLIST_DOMAINS_FILE

# sbin — вперёд при отсутствии (как update.sh): операторский PATH не сносим.
case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) export PATH="/usr/sbin:/sbin:$PATH" ;;
esac

# shellcheck disable=SC1090,SC1091
if [ -f "$Z2K_ROOT/platform/openwrt/webpanel.sh" ]; then
    . "$Z2K_ROOT/platform/openwrt/webpanel.sh" 2>/dev/null || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
fi
# The common /update/schedule route calls this seam after persisting the
# value.  Loading the package-owned scheduler here keeps OpenWrt cron
# convergence in its sole platform authority; Keenetic never enters this
# branch.
if [ -f "$Z2K_ROOT/platform/openwrt/schedule.sh" ]; then
    . "$Z2K_ROOT/platform/openwrt/schedule.sh" 2>/dev/null || Z2K_PLATFORM_STATUS="PLATFORM_UNAVAILABLE"
fi
export Z2K_PLATFORM_STATUS

# --- overrides: те же имена, OS-эффект через замороженные адаптеры ---

# Core service state: реальный procd (не pgrep; класс ошибки Stage 5).
is_running() {
    "${Z2K_INIT:-/etc/init.d/z2k}" running >/dev/null 2>&1
}

is_installed() {
    [ -f "${Z2K_PAYLOAD_MARKER:-/etc/z2k/.payload-initialized}" ]
}

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

toggle_ppe() {
    echo "PPE toggle недоступен на OpenWrt (offload владеет zapret2 runtime)" >&2
    return 1
}

toggle_fastroute() {
    echo "Программный fastpath недоступен на OpenWrt: backend не обнаружен" >&2
    return 1
}

toggle_customd() {
    echo "custom.d недоступен на OpenWrt: каталог адаптера пуст" >&2
    return 1
}

tunnel_pid() {
    local _p
    _p=$(z2k_ow_tg_pids 2>/dev/null | head -1)
    [ -n "$_p" ] && z2k_ow_tg_listeners_ready || return 1
    printf '%s\n' "$_p"
}

fastroute_status() {
    printf 'Программный fastpath недоступен на OpenWrt: backend не обнаружен.'
}

policy_status() {
    printf 'name=|exclude=0|exists=0\n'
}

policy_save() {
    echo "Keenetic policy недоступна на OpenWrt (эквивалента нет)" >&2
    return 1
}

warp_neighbors() {
    wp_neighbors
}

uninstall_async() {
    echo "удаление z2k на OpenWrt — через пакетный менеджер роутера" >&2
    return 1
}

wp_capabilities_json() {
    local _ready=false _degraded=false _running=false
    is_running >/dev/null 2>&1 && _running=true
    command -v z2k_ow_core_ready >/dev/null 2>&1 && \
        z2k_ow_core_ready >/dev/null 2>&1 && _ready=true
    { [ "$_running" = "true" ] && [ "$_ready" = "false" ]; } && _degraded=true
    printf '"platform":"openwrt","ready":%s,"degraded":%s,"capabilities":{"policy":false,"ppe":false,"fastroute":false,"tcp16":false,"diag":false,"customd":false,"warp":true,"telegram":true,"uninstall":false}' \
        "$_ready" "$_degraded"
}

if [ "$Z2K_PLATFORM_STATUS" != "ok" ]; then
    is_installed() { return 1; }
    svc_start() { echo "PLATFORM_UNAVAILABLE: повреждён OpenWrt-адаптер" >&2; return 1; }
    svc_stop() { echo "PLATFORM_UNAVAILABLE: повреждён OpenWrt-адаптер" >&2; return 1; }
    svc_restart() { echo "PLATFORM_UNAVAILABLE: повреждён OpenWrt-адаптер" >&2; return 1; }
    restart_service_if_running() { echo "PLATFORM_UNAVAILABLE: повреждён OpenWrt-адаптер" >&2; return 1; }
    regenerate_config() { echo "PLATFORM_UNAVAILABLE: повреждён OpenWrt-адаптер" >&2; return 1; }
fi
