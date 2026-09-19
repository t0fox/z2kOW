#!/bin/sh
# tests/openwrt/test_ow_lifecycle.sh - Step 10: WAN-события без рестарта демона.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lifecycle"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HP="$REPO/package/openwrt/files/etc/hotplug.d/iface/90-z2k"
SVC="$REPO/package/openwrt/files/etc/init.d/z2k"

assert_contains "hotplug: ifset-reload" "$HP" "reload_ifsets"
assert_contains "hotplug: ready-gate" "$HP" "z2k_ow_core_ready"
if grep -Eiq 'restart|start_daemons|procd|nfqws' "$HP"; then
    _t_bad "hotplug трогает демона (должен только обновлять ifsets)"
else
    _t_ok
fi
assert_contains "hotplug: только ifup/ifdown" "$HP" "ifdown"
assert_contains "hotplug: уважает enabled" "$HP" "enabled"

assert_contains "service: fw apply на старте" "$SVC" "z2k_ow_fw_apply"
assert_contains "service: fw verify на старте" "$SVC" "z2k_ow_fw_verify"
assert_contains "service: core-ready LAST" "$SVC" "Z2K_CORE_READY"
assert_contains "service: rollback" "$SVC" "z2k_ow_start_rollback"
assert_contains "service: stop verify" "$SVC" "z2k_ow_stop_verify"
assert_contains "service: fw remove на стопе" "$SVC" "z2k_ow_fw_remove"
assert_contains "service: custom.d на старте" "$SVC" "z2k_ow_custom_daemons 1"
assert_contains "service: custom.d на стопе" "$SVC" "z2k_ow_custom_daemons 0"
assert_contains "service: master-гейт ENABLED" "$SVC" "ENABLED"
assert_contains "service: procd" "$SVC" "USE_PROCD=1"
assert_contains "service: START" "$SVC" "START=22"
assert_contains "service: core bounded respawn" "$SVC" "procd_set_param respawn 3600 5 5"
assert_contains "service: shared NFQUEUE owner check" "$SVC" "z2k_ow_nfqws_consumer_ready"
assert_contains "service: intentional stop fence" "$SVC" "stopping"

_t_done
