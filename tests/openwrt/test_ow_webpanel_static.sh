#!/bin/sh
# tests/openwrt/test_ow_webpanel_static.sh - Stage 6 Layer A: статика панели.
# Контракт, маленький seam, запрет platform-логики в CGI, отсутствие форков.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-static"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPSH="$REPO/webpanel/cgi/platform.sh"
WPSH="$REPO/platform/openwrt/webpanel.sh"
PINIT="$REPO/package/openwrt/files/etc/init.d/z2k-webpanel"
TPL="$REPO/webpanel/lighttpd.conf"
AU="$REPO/lib/auto_update.sh"
RM="$REPO/lib/release_map.sh"

assert_file "контракт существует" "$REPO/docs/openwrt-webpanel-contract.md"
assert_file "platform.sh существует" "$CPSH"
assert_file "webpanel.sh существует" "$WPSH"
assert_file "init панели существует" "$PINIT"

# Seam маленький: platform.sh обязан быть компактным.
_nlines="$(wc -l < "$CPSH" | tr -d ' ')"
[ "$_nlines" -le 170 ] && _t_ok || _t_bad "platform.sh раздут: $_nlines строк (seam должен быть tiny)"
_nlines="$(wc -l < "$WPSH" | tr -d ' ')"
[ "$_nlines" -le 260 ] && _t_ok || _t_bad "webpanel.sh раздут: $_nlines строк"

# Нет форков upstream-файлов.
for _f in webpanel/cgi/actions-openwrt.sh webpanel/cgi/api-openwrt.sh \
         webpanel/www/app-openwrt.js webpanel/lighttpd-openwrt.conf; do
    if [ -e "$REPO/$_f" ]; then _t_bad "форк upstream: $_f"; else _t_ok; fi
done

# Keenetic-дефолт: без Z2K_PLATFORM platform.sh — no-op (ничего не выводит,
# ничего не меняет, rc 0).
_out="$(env -u Z2K_PLATFORM sh "$CPSH" 2>&1)"
assert_eq "platform.sh no-op без платформы" "" "$_out"

# Запрещённая platform-логика в CGI-слое панели: nft/ip-rule/ip-route/ubus/
# uci-команды, opkg, ndmc, ipset, Entware-иниты, LuCI/uhttpd, z2k.sh uninstall.
# Проверяем REACHABILITY (код, не комментарии): Keenetic-исходники upstream
# эти строки содержат — здесь только наши platform-файлы.
for _f in "$CPSH" "$WPSH" "$PINIT"; do
    _code="$(sed 's/#.*$//' "$_f")"
    _n="basename-$_f"
    for _pat in 'nft add' 'nft delete' 'nft flush' 'ip rule add' 'ip rule del' \
                'ip route add' 'ip route del' 'ubus call' 'uci set' 'uci commit' \
                'uci delete' 'uci add' 'opkg ' 'ndmc' 'ipset ' 'iptables' \
                'apk del' 'z2k.sh uninstall' 'luci' 'uhttpd' \
                'S98tg-tunnel' 'S97z2k-http' 'S51z2k-warp' 'S96z2k-rt-proxy' \
                'S99zapret2' '/opt/etc/init.d/'; do
        if printf '%s' "$_code" | grep -qF -- "$_pat"; then
            _t_bad "запрет [$_pat] в $(basename "$_f")"
        else
            _t_ok
        fi
    done
done

# Template: ровно известные плейсхолдеры (PLATFORM_ENV — единственный новый).
for _ph in WWW_DIR PORT BIND IPV6_SOCKET PLATFORM_ENV; do
    assert_contains "template: @$PH@" "$TPL" "@${_ph}@"
done
if grep -oE '@[A-Z_]+@' "$TPL" | sort -u | grep -vE '^@(WWW_DIR|PORT|BIND|IPV6_SOCKET|PLATFORM_ENV)@$' | grep -q .; then
    _t_bad "template: неизвестные плейсхолдеры"
else
    _t_ok
fi
# Keenetic-инсталлер обязан знать новый плейсхолдер (иначе оставит как есть).
assert_contains "install.sh знает PLATFORM_ENV" "$REPO/webpanel/install.sh" "PLATFORM_ENV"

# api.sh: platform.sh до И после actions.sh (env раньше дефолтов, overrides позже).
# Матчим только исполняемые source-строки (SELF_DIR/...): упоминания
# в комментариях и shellcheck-директивах для порядка не показательны.
_lp1="$(grep -n 'SELF_DIR/platform\.sh"' "$REPO/webpanel/cgi/api.sh" | head -1 | cut -d: -f1)"
_la="$(grep -n 'SELF_DIR/actions\.sh"' "$REPO/webpanel/cgi/api.sh" | head -1 | cut -d: -f1)"
_lp2="$(grep -n 'SELF_DIR/platform\.sh"' "$REPO/webpanel/cgi/api.sh" | tail -1 | cut -d: -f1)"
if [ -n "$_lp1" ] && [ -n "$_la" ] && [ -n "$_lp2" ] \
    && [ "$_lp1" -lt "$_la" ] && [ "$_la" -lt "$_lp2" ]; then
    _t_ok
else
    _t_bad "api.sh: порядок platform/actions/platform нарушен ($_lp1/$_la/$_lp2)"
fi
# /status capabilities — только openwrt-ветка (Keenetic-байты не меняются).
if grep -q 'Z2K_PLATFORM:-keenetic.*"openwrt"' "$REPO/webpanel/cgi/api.sh" 2>/dev/null \
    || grep -q 'capabilities' "$REPO/webpanel/cgi/api.sh"; then
    _t_ok
else
    _t_bad "api.sh: нет capability-ветки"
fi

# Common diff budget (§44): openwrt-специфичных строк в upstream-файлах — единицы.
for _spec in "actions.sh:12" "api.sh:8" "auth.sh:6"; do
    _f="${_spec%%:*}"; _lim="${_spec##*:}"
    _n="$(grep -cE 'Z2K_PLATFORM|platform\.sh|PLATFORM_ENV|Z2K_PANEL_DIR|DEBUG_FLAG_FILE|Z2K_AU_MANIFEST_URL' \
        "$REPO/webpanel/cgi/$_f" 2>/dev/null || true)"
    if [ "$_n" -le "$_lim" ]; then _t_ok; else _t_bad "$_f: $_n openwrt-строк (бюджет $_lim)"; fi
done

# warp.sh имеет ipset-верб (панельный live-reload без второй реализации).
assert_contains "warp.sh: ipset verb" "$REPO/platform/openwrt/warp.sh" "warp_ipset()"

# rebuild-panel: имя шага общее + openwrt-исполнитель.
assert_contains "rebuild-panel hook" "$AU" "_au_rebuild_panel_openwrt"
assert_contains "restart-set openwrt" "$AU" 'S96z2k-webpanel'
# release_map: openwrt webpanel-мэппинги.
assert_contains "release_map cgi" "$RM" 'webpanel/cgi/*.sh)'
assert_contains "release_map www" "$RM" 'webpanel/www/*)'
assert_contains "release_map template" "$RM" 'webpanel/lighttpd.conf)'
assert_contains "release_map dns-check" "$RM" 'files/z2k-dns-check.sh)'

# ownership: webpanel-классы из контракта §43.
for _e in "/usr/lib/z2k/webpanel/* updater" "/usr/lib/z2k/www/* updater" \
          "/etc/z2k/webpanel/* user" "/etc/init.d/z2k-webpanel package" \
          "/usr/lib/z2k/platform/openwrt/webpanel.sh package"; do
    if grep -qxF "$_e" "$REPO/package/openwrt/ownership.map" 2>/dev/null; then
        _t_ok
    else
        _t_bad "ownership.map: нет [$_e]"
    fi
done

# Init панели: procd, bounded respawn, без shell-супервизора и чужого lighttpd.
assert_contains "init: procd instance" "$PINIT" 'procd_open_instance "z2k-webpanel"'
assert_contains "init: bounded respawn" "$PINIT" 'procd_set_param respawn 3600 5 5'
assert_contains "init: dedicated lighttpd" "$PINIT" 'lighttpd -D -f'
if grep -qE 'while :|/etc/init.d/lighttpd|/etc/config/lighttpd' "$PINIT" 2>/dev/null; then
    _t_bad "init: супервизор или чужой lighttpd"
else
    _t_ok
fi

# Frontend: только capability visibility (allowlisted файлы + loadorder helper).
assert_contains "js: caps helper" "$REPO/webpanel/www/js/core/loadorder.js" "applyCapabilities"
assert_contains "js: toggles hook" "$REPO/webpanel/www/js/pages/toggles.js" "applyCapabilities"
assert_contains "js: boot hook" "$REPO/webpanel/www/app.js" "applyCapabilities"
if grep -rlE 'openwrt|PLATFORM|capabilit' "$REPO/webpanel/www/js" 2>/dev/null \
    | grep -vE 'loadorder\.js|toggles\.js|app\.js|router\.js' | grep -q .; then
    _t_bad "js: capability-логика вне allowlisted файлов"
else
    _t_ok
fi
# router.js — только недостающий ROUTE_TITLES.autohostlist, никакой
# platform-логики (см. проверку выше: слова openwrt там быть не должно).
assert_contains "js: autohostlist title" "$REPO/webpanel/www/js/router.js" 'autohostlist:'
if grep -n 'openwrt\|PLATFORM\|capabilit' "$REPO/webpanel/www/js/router.js" 2>/dev/null | grep -q .; then
    _t_bad "js: router.js с platform-логикой (разрешён только title)"
else
    _t_ok
fi

# Stage 8 parity: GET /toggles — общий кейс (обе платформы), без
# platform-ветвления (форма та же, что вложенный "toggles" из /status).
assert_contains "api.sh: GET /toggles case" "$REPO/webpanel/cgi/api.sh" '"GET /toggles")'
if grep -n '"GET /toggles")' "$REPO/webpanel/cgi/api.sh" | cut -d: -f1 | { read -r _l; sed -n "${_l},$((_l + 25))p" "$REPO/webpanel/cgi/api.sh"; } | grep -qE 'Z2K_PLATFORM|openwrt'; then
    _t_bad "api.sh: GET /toggles с platform-ветвлением (должен быть общим)"
else
    _t_ok
fi

# Stage 8 parity текстов: upstream-формулировки 1-в-1, OW-варианты только
# за capability-сигналом и только в тех же трёх файлах.
assert_contains "js: OW dynamic_ttl desc" "$REPO/webpanel/www/js/pages/toggles.js" "DYNAMIC_TTL_DESC_OPENWRT"
assert_contains "js: OW desc за platform" "$REPO/webpanel/www/js/pages/toggles.js" 's.platform === "openwrt"'
assert_contains "js: upstream TTL-fix текст цел" "$REPO/webpanel/www/js/pages/toggles.js" "TTL-fix Keenetic"
assert_contains "js: OW title guard" "$REPO/webpanel/www/js/core/loadorder.js" 'для OpenWrt'
assert_contains "js: telemetry nav-guard" "$REPO/webpanel/www/js/pages/telemetry.js" 'host.isConnected === false'

_t_done
