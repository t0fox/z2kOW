#!/bin/sh
# tests/openwrt/test_ow_panel_runtime.sh - panel must expose live OpenWrt
# ownership and paths, not common Keenetic fallbacks or marker-only health.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-panel-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLAT="$REPO/webpanel/cgi/platform.sh"
ACT="$REPO/webpanel/cgi/actions.sh"
TG="$REPO/platform/openwrt/tg.sh"
LOAD="$REPO/webpanel/www/js/core/loadorder.js"

assert_contains "panel uses canonical nfqws2" "$PLAT" 'Z2K_NFQWS2'
assert_contains "panel ready uses canonical predicate" "$PLAT" 'z2k_ow_core_ready'
assert_contains "OpenWrt custom.d capability is computed" "$REPO/platform/openwrt/customd.sh" 'z2k_ow_customd_available'
assert_contains "OpenWrt custom.d toggle checks components" "$REPO/platform/openwrt/customd.sh" 'обязательные файлы или runtime отсутствуют'
assert_contains "Telegram panel loads OpenWrt adapter" "$PLAT" 'platform/openwrt/tg.sh'
assert_contains "Telegram status checks listeners" "$TG" 'z2k_ow_tg_listeners_ready'
assert_contains "strategy validation uses runtime engine" "$ACT" 'Z2K_NFQWS2'
assert_contains "panel payload contract marker" "$ACT" 'Z2K_OPENWRT_PANEL_CONTRACT=1'
assert_contains "panel payload compatibility is checked" "$REPO/platform/openwrt/panel.sh" 'z2k_ow_panel_payload_compatible'
assert_contains "panel mismatch is visible" "$PLAT" 'payload_compatible'
assert_contains "strategy shadow uses runtime custom source" "$ACT" 'Z2K_EXTRA_STRATEGIES_RUNTIME'
assert_contains "panel hides unsupported custom.d" "$LOAD" 'data-key="customd"'

_t_done
