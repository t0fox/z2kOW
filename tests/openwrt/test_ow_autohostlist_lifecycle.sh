#!/bin/sh
# test_ow_autohostlist_lifecycle.sh - persistent ledger and engine file stay
# separate while discoveries survive stop/start and payload update.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-autohostlist-lifecycle"
ow_fixture_init || { echo "FAIL[ow-autohostlist-lifecycle]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh" || exit 1
. "$AD/env.sh" || exit 1
. "$AD/autohostlist.sh" || exit 1

mkdir -p "$Z2K_STATE" "$Z2K_USER_LISTS" "$Z2K_LISTS_DIR"
printf 'Z2K_AUTOHOSTLIST=1\n' > "$Z2K_CONFIG"
printf 'persistent.example\n' > "$AUTOHOSTLIST_DOMAINS_FILE"
printf 'discovered.example\n' > "$Z2K_AUTOHOSTLIST_FILE"
printf 'payload-only.example\n' > "$Z2K_LISTS_DIR/autohostlist-domains.txt"

z2k_ow_autohostlist_sync || _t_bad "sync live discoveries"
assert_contains "discovery copied to persistent ledger" "$AUTOHOSTLIST_DOMAINS_FILE" "discovered.example"
assert_contains "existing ledger preserved" "$AUTOHOSTLIST_DOMAINS_FILE" "persistent.example"
[ ! -s "$Z2K_AUTOHOSTLIST_FILE" ] && _t_ok || _t_bad "live engine file drained after sync"
assert_not_contains "payload list is not an input" "$AUTOHOSTLIST_DOMAINS_FILE" "payload-only.example"

# Simulate update/restart: runtime file disappears, the persistent ledger does
# not. prepare must recreate only the engine file from the ledger.
rm -f "$Z2K_AUTOHOSTLIST_FILE"
z2k_ow_autohostlist_prepare || _t_bad "prepare after restart"
assert_contains "ledger restored to engine file" "$Z2K_AUTOHOSTLIST_FILE" "discovered.example"
assert_contains "ledger remains separate" "$AUTOHOSTLIST_DOMAINS_FILE" "persistent.example"

# Disabling the feature must not create a new engine file or import payload
# data, while the user-owned ledger remains intact for a later re-enable.
printf 'Z2K_AUTOHOSTLIST=0\n' > "$Z2K_CONFIG"
rm -f "$Z2K_AUTOHOSTLIST_FILE"
z2k_ow_autohostlist_prepare || _t_bad "prepare disabled"
[ ! -e "$Z2K_AUTOHOSTLIST_FILE" ] && _t_ok || _t_bad "disabled mode created live file"
assert_contains "disabled mode preserves ledger" "$AUTOHOSTLIST_DOMAINS_FILE" "discovered.example"

# A disabled service with only a retained ledger must not materialize a new
# engine input during stop/update.
rm -f "$Z2K_AUTOHOSTLIST_FILE"
z2k_ow_autohostlist_sync || _t_bad "sync disabled without live file"
[ ! -e "$Z2K_AUTOHOSTLIST_FILE" ] && _t_ok || _t_bad "disabled sync created live file"

_t_done
