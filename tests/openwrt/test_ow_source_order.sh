#!/bin/sh
# tests/openwrt/test_ow_source_order.sh - §13: platform env раньше common.
# Regression: UPDATER_COMMON_SOURCED_BEFORE_PLATFORM_ENV — любой OpenWrt
# auto-update entry обязан source paths.sh+env.sh ДО lib/utils.sh+auto_update,
# иначе channel/path overrides не применятся (дефолты вычисляются при сорсинге).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-source-order"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

for _entry in "$REPO"/platform/openwrt/update.sh; do
    _code="$(sed 's/#.*$//' "$_entry")"
    _lp="$(printf '%s\n' "$_code" | grep -n 'platform/openwrt/paths\.sh' | head -1 | cut -d: -f1)"
    _le="$(printf '%s\n' "$_code" | grep -n 'platform/openwrt/env\.sh' | head -1 | cut -d: -f1)"
    _lu="$(printf '%s\n' "$_code" | grep -n 'utils\.sh' | head -1 | cut -d: -f1)"
    _la="$(printf '%s\n' "$_code" | grep -n 'auto_update\.sh' | head -1 | cut -d: -f1)"
    _b="$(basename "$_entry")"
    if [ -n "$_lp" ] && [ -n "$_le" ] && [ -n "$_lu" ] && [ -n "$_la" ] \
        && [ "$_lp" -lt "$_le" ] && [ "$_le" -lt "$_lu" ] && [ "$_lu" -lt "$_la" ]; then
        _t_ok
    else
        _t_bad "$_b: порядок нарушен (paths=$_lp env=$_le utils=$_lu auto_update=$_la)"
    fi
done

# функционально: defaults auto_update вычислены ПОСЛЕ env (канал t0fox)
_got="$( ( Z2K_ROOT=/r Z2K_ETC=/e Z2K_TMP=/t
    . "$REPO/platform/openwrt/paths.sh" >/dev/null
    . "$REPO/platform/openwrt/env.sh" >/dev/null
    . "$REPO/lib/utils.sh" >/dev/null 2>&1
    . "$REPO/lib/auto_update.sh" >/dev/null 2>&1
    printf '%s' "$Z2K_AU_MANIFEST_URL" ) 2>/dev/null )"
assert_eq "manifest URL из env-канала" "https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt/UPDATES.json" "$_got"

_t_done
