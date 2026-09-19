#!/bin/sh
# tests/openwrt/test_ow_updater_state.sh - §5-6: состояние updater без /opt.
# env выставляет всё ДО source auto_update.sh (все дефолты там условные).
# Проверяем и значения, и что Keenetic-дефолты без env не изменились.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-updater-state"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# --- OpenWrt-контекст ---
_got="$( ( unset Z2K_AU_INSTALLED_TAG_FILE Z2K_AU_LOCK_FILE Z2K_AU_LOG_FILE Z2K_AU_TMP_DIR \
    Z2K_AU_TRUST_PIN Z2K_AU_PUBKEY ZAPRET2_DIR Z2K_AU_SBIN \
    Z2K_AU_FAILS_FILE Z2K_AU_DIRTY_TREE_FILE
  Z2K_ROOT=/r Z2K_ETC=/e Z2K_TMP=/t
  . "$REPO/platform/openwrt/paths.sh" >/dev/null
  . "$REPO/platform/openwrt/env.sh" >/dev/null
  . "$REPO/lib/utils.sh" >/dev/null 2>&1
  . "$REPO/lib/auto_update.sh" >/dev/null 2>&1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$Z2K_AU_INSTALLED_TAG_FILE" "$Z2K_AU_LOCK_FILE" "$Z2K_AU_LOG_FILE" \
    "$Z2K_AU_TMP_DIR" "$Z2K_AU_TRUST_PIN" "$Z2K_AU_PUBKEY" \
    "$Z2K_AU_FAILS_FILE" "$Z2K_AU_DIRTY_TREE_FILE" ) 2>/dev/null )"
assert_eq "state paths" "/e/state/installed-tag
/t/locks/update.lock
/t/logs/z2k-auto-update.log
/t/update
/e/.trust/pinned
/r/etc/z2k-update-pub.pem
/e/state/au-delivery-fails
/e/state/dirty-tree" "$_got"
case "$_got" in
    */opt/*) _t_bad "в путях остался /opt" ;;
    *) _t_ok ;;
esac

# --- Keenetic-дефолты без env ---
_got2="$( ( unset Z2K_AU_INSTALLED_TAG_FILE Z2K_AU_LOCK_FILE Z2K_AU_LOG_FILE Z2K_AU_TMP_DIR \
    Z2K_AU_TRUST_PIN Z2K_AU_PUBKEY ZAPRET2_DIR
  . "$REPO/lib/auto_update.sh" >/dev/null 2>&1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$Z2K_AU_INSTALLED_TAG_FILE" "$Z2K_AU_LOCK_FILE" "$Z2K_AU_LOG_FILE" \
    "$Z2K_AU_TMP_DIR" "$Z2K_AU_TRUST_PIN" "$Z2K_AU_PUBKEY" ) 2>/dev/null )"
assert_eq "keenetic defaults" "/opt/zapret2/.z2k-installed-tag
/opt/zapret2/.update.lock
/opt/var/log/z2k-auto-update.log
/tmp/z2k_au
/opt/etc/z2k/.trust/pinned
/opt/zapret2/etc/z2k-update-pub.pem" "$_got2"

# VERIFY_BIN: дефолт идёт через ZAPRET2_DIR/bin (static — функция локальная)
if grep -q 'Z2K_AU_VERIFY_BIN:-\${ZAPRET2_DIR:-[^}]*}/bin/z2k-verify' "$REPO/lib/auto_update.sh"; then
    _t_ok
else
    _t_bad "VERIFY_BIN дефолт не через ZAPRET2_DIR/bin"
fi

assert_contains "OpenWrt updater has platform nfqws predicate" "$REPO/platform/openwrt/env.sh" 'z2k_platform_nfqws_alive'
assert_contains "common updater calls platform predicate" "$REPO/lib/auto_update.sh" 'au_nfqws_alive'
assert_contains "Keenetic fallback stays isolated" "$REPO/lib/auto_update.sh" 'pgrep -f nfqws2'

_t_done
