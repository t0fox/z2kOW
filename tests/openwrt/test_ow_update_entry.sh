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
assert_contains "manual reinstall resolves the installed tag before canonical install" "$UPD" 'exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" --reinstall "$installed"'
assert_contains "update adapter accepts an explicit manual reinstall action" "$UPD" 'check|apply|reinstall)'
assert_contains "reinstall action rejects requests without an explicit manual flag" "$UPD" '[ "$AU_MANUAL" != 1 ]'
assert_contains "reinstall reports a manifest race as update_available" "$UPD" 'Z2KOW_REINSTALL_UPDATE_AVAILABLE:'
assert_contains "check reports the same full release without another engine" "$UPD" 'Доступен полный выпуск %s'
assert_not_contains "OpenWrt has no second patch/reinstall deployment engine" "$UPD" 'au_apply_patch|au_apply_reinstall|stack-update|product-update'
assert_not_contains "nightly updater never dispatches same-version reinstall" "$AU" 'install_release.*--reinstall|update\.sh reinstall'
python3 - "$UPD" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text(encoding="utf-8")
fresh_manifest = source.index('z2k_ow_manifest_prepare_production "$MANIFEST"')
reinstall_branch = source.index('if [ "$ACTION" = reinstall ]; then')
current_tag = source.index('current=$(z2k_ow_manifest_value "$MANIFEST" current)', reinstall_branch)
tag_seq_guard = source.index('if [ "$installed" != "$current" ] || [ "$installed_seq" != "$current_seq" ]; then', current_tag)
canonical_call = source.index('exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" --reinstall "$installed"', tag_seq_guard)
assert fresh_manifest < reinstall_branch < current_tag < tag_seq_guard < canonical_call
assert ' --reinstall "$2"' not in source
PY
_rc=$?
[ "$_rc" -eq 0 ] && _t_ok || _t_bad "manual reinstall fetches the production manifest and checks installed tag+seq before canonical install"

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
