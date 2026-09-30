#!/bin/sh
# The existing signed package updater runs before the upstream API gate/payload
# and hands off once so the new adapter implementation is reloaded.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-unified-update"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$REPO/platform/openwrt/stack-update.sh"
UPD="$REPO/platform/openwrt/update.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-stack-update.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

if [ ! -s "$STACK" ]; then
    _t_bad "unified OpenWrt stack coordinator exists"
    _t_done
    exit 1
fi
. "$STACK"

mkdir -p "$T/bin"
cat > "$T/bin/z2kow" <<'EOF'
#!/bin/sh
case "${1:-} ${2:-}" in
    'status --json')
        printf 'status\n' >> "$STACK_CALLS"
        if [ -n "${STACK_PRODUCT_STATUS:-}" ]; then
            printf '%s\n' "$STACK_PRODUCT_STATUS"
        else
            printf '%s\n' '{"ok":true,"state":"up-to-date"}'
        fi
        [ "${STACK_STATUS_RC:-0}" -eq 0 ] || exit "$STACK_STATUS_RC"
        ;;
    'update --non-interactive')
        printf 'packages\n' >> "$STACK_CALLS"
        [ "${STACK_PACKAGE_RC:-0}" -eq 0 ] || exit "$STACK_PACKAGE_RC"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/z2kow"
export STACK_CALLS="$T/calls" Z2K_PRODUCT_UPDATE_BIN="$T/bin/z2kow"
export STACK_PRODUCT_STATUS STACK_STATUS_RC STACK_PACKAGE_RC
export Z2K_AU_TMP_DIR="$T/update" Z2K_AU_INSTALLED_TAG_FILE="$T/installed-tag"
printf 'p-86.1\n' > "$Z2K_AU_INSTALLED_TAG_FILE"

au_fetch_manifest() {
    printf 'upstream\n' >> "$STACK_CALLS"
    [ "${STACK_FETCH_RC:-0}" -eq 0 ] || return "$STACK_FETCH_RC"
    mkdir -p "$Z2K_AU_TMP_DIR"
    printf '{"current":"p-86.2"}\n' > "$Z2K_AU_TMP_DIR/UPDATES.json"
}
au_decide() { printf '%s\n' "${STACK_DECISION:-patch p-86.2}"; }

_run_stage() {
    if z2k_ow_prepare_stack_apply >"$T/output" 2>&1; then _rc=0; else _rc=$?; fi
}

# Stable package releases are installed first and request a launcher reload.
: > "$STACK_CALLS"
unset STACK_PRODUCT_STATUS STACK_STATUS_RC STACK_PACKAGE_RC
unset STACK_FETCH_RC STACK_DECISION
_run_stage
assert_eq "production package stage requests a one-time reload" "10" "$_rc"
assert_eq "signed upstream update gates the package transaction" "upstream status packages" "$(tr '\n' ' ' < "$STACK_CALLS" | sed 's/ $//')"

# The re-entered launcher consumes the marker and proceeds to its API gate.
: > "$STACK_CALLS"
export Z2K_OW_PACKAGE_STAGE_DONE=1
_run_stage
assert_eq "re-entry proceeds without repeating package update" "0" "$_rc"
assert_eq "re-entry does not call package updater again" "" "$(cat "$STACK_CALLS")"

# CI snapshots do not enter the production package channel.
: > "$STACK_CALLS"
unset Z2K_OW_PACKAGE_STAGE_DONE
STACK_PRODUCT_STATUS=$(printf '%s' '{"ok":true,"state":"snapshot","build":"private"}')
export STACK_PRODUCT_STATUS
_run_stage
assert_eq "internal snapshot skips production package stage" "0" "$_rc"
assert_eq "snapshot only reads local package state" "upstream status" "$(tr '\n' ' ' < "$STACK_CALLS" | sed 's/ $//')"
assert_not_contains "snapshot identifiers stay out of updater output" "$T/output" 'private'
assert_not_contains "snapshot status stays out of updater output" "$T/output" 'snapshot'

# A broken snapshot pair is rejected before payload apply can begin.
: > "$STACK_CALLS"
STACK_PRODUCT_STATUS=$(printf '%s' '{"ok":true,"state":"snapshot-inconsistent","build":"private"}')
export STACK_PRODUCT_STATUS
_run_stage
assert_eq "inconsistent snapshot fails closed" "1" "$_rc"
assert_eq "inconsistent snapshot never enters package updater" "upstream status" "$(tr '\n' ' ' < "$STACK_CALLS" | sed 's/ $//')"
assert_not_contains "inconsistent details stay internal" "$T/output" 'private'

# Failed production package installation blocks the later payload stage.
: > "$STACK_CALLS"
unset STACK_PRODUCT_STATUS
export STACK_PACKAGE_RC=9
_run_stage
assert_eq "package failure propagates" "9" "$_rc"
assert_eq "failed package stage stops before payload handoff" "upstream status packages" "$(tr '\n' ' ' < "$STACK_CALLS" | sed 's/ $//')"
assert_not_contains "package error output has no product version" "$T/output" 'z2kOW'

# A missing CLI or unreadable state cannot silently turn into payload-only apply.
export Z2K_PRODUCT_UPDATE_BIN="$T/bin/absent"
_run_stage
assert_eq "missing package updater fails before upstream payload" "1" "$_rc"
assert_not_contains "missing updater output is generic" "$T/output" 'SNAPSHOT'

# Package-only drift is hidden when no upstream p-release is available.
: > "$STACK_CALLS"
export Z2K_PRODUCT_UPDATE_BIN="$T/bin/z2kow" STACK_DECISION=none
unset STACK_PRODUCT_STATUS STACK_PACKAGE_RC
_run_stage
assert_eq "current upstream release does not start an independent package update" "0" "$_rc"
assert_eq "current upstream release checks only the upstream manifest" "upstream" "$(cat "$STACK_CALLS")"

# A failed signed upstream check fails closed before package status or mutation.
: > "$STACK_CALLS"
export STACK_FETCH_RC=1
_run_stage
assert_eq "upstream manifest failure blocks package update" "1" "$_rc"
assert_eq "manifest failure performs no package calls" "upstream" "$(cat "$STACK_CALLS")"

# The package stage must precede both adapter compatibility and payload apply.
_prepare_line=$(grep -n 'z2k_ow_prepare_stack_apply ||' "$UPD" | cut -d: -f1)
_gate_line=$(grep -n 'z2k_ow_adapter_gate apply' "$UPD" | cut -d: -f1)
_payload_line=$(grep -n 'au_run_apply' "$UPD" | tail -1 | cut -d: -f1)
[ -n "$_prepare_line" ] && [ -n "$_gate_line" ] && [ -n "$_payload_line" ] \
    && [ "$_prepare_line" -lt "$_gate_line" ] && [ "$_gate_line" -lt "$_payload_line" ] \
    && _t_ok || _t_bad "package -> adapter gate -> upstream payload ordering"

_t_done
