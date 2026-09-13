#!/bin/sh
# tests/openwrt/test_ow_webpanel_pages.sh - каждая страница исполняется под
# OpenWrt-формой API (platform + capabilities + /toggles).
#
# test_panel_pages.sh гоняет те же страницы под Keenetic-ответами: OW-ветки
# фронта (applyCapabilities, OW-текст dynamic_ttl, title-guard) при этом не
# исполняются вовсе. Здесь panel_harness.js едет с Z2K_OW_CAPS=1, и падение
# любой OW-ветки (undefined-поле, опечатка в селекторе не роняет mock-DOM,
# но бросает настоящее исключение) краснит гейт.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-pages"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP[ow-webpanel-pages]: нет node (как test_panel_pages.sh)"
    echo "SUITE[ow-webpanel-pages]: pass=0 fail=0"
    exit 0
fi

# Харнесс обязан знать OW-режим, иначе тест вхолостую гоняет Keenetic-форму.
if grep -q 'Z2K_OW_CAPS' "$ROOT/tests/panel_harness.js"; then _t_ok
else _t_bad "panel_harness.js без Z2K_OW_CAPS-ветки"; fi

JS="$(sh "$ROOT/tests/lib/panel_js.sh")"
ROUTES="dashboard toggles strategies state warp whitelist exclude extra-domains diag credits"
# shellcheck disable=SC2086
_out="$(Z2K_OW_CAPS=1 node "$ROOT/tests/panel_harness.js" "$JS" $ROUTES 2>&1)"
_rc=$?
printf '%s\n' "$_out" | sed 's/^/    /'
[ "$_rc" -eq 0 ] || _t_bad "харнесс завершился с rc=$_rc"
for _r in $ROUTES; do
    if printf '%s\n' "$_out" | grep -q "ok  *#/$_r$"; then _t_ok
    else _t_bad "страница #/$_r под OW-caps НЕ отрисовалась"; fi
done

_t_done
