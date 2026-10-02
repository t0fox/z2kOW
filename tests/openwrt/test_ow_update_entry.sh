#!/bin/sh
# OpenWrt auto-update preserves upstream decision semantics and dispatches all
# approved releases through the canonical full-payload installer.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-update-entry"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
UPD="$REPO/platform/openwrt/update.sh"
AU="$REPO/lib/auto_update.sh"

assert_contains "controlled manifest drives release decision" "$UPD" 'z2k_ow_release_decision'
assert_contains "patch and reinstall both reach one installer command" "$UPD" 'install_release'
assert_contains "update invokes the full installer with current tag" "$UPD" 'exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" "$2"'
assert_contains "check reports the same full release without another engine" "$UPD" 'Доступен полный выпуск %s'
assert_not_contains "OpenWrt has no second patch/reinstall deployment engine" "$UPD" 'au_apply_patch|au_apply_reinstall|stack-update|product-update'

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-update-entry.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
cat > "$T/update.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OW_UPDATE_CALLS"
EOF
chmod +x "$T/update.sh"
export Z2K_PLATFORM=openwrt Z2K_OW_UPDATE_BIN="$T/update.sh" OW_UPDATE_CALLS="$T/calls"
. "$AU" || exit 1
( au_run_apply p-86.11 ) || _t_bad "OpenWrt updater dispatch failed"
assert_eq "common updater delegates to one OpenWrt update entry" 'apply p-86.11' "$(cat "$T/calls")"

_t_done
