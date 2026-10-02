#!/bin/sh
# Regression for r-86.3: convergence must not inherit a ref from a prior
# reinstall; a snapshot-provided full commit remains authoritative.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d) || exit 1; trap 'rm -rf "$SB"' EXIT
Z2K_AU_SOURCE_ONLY=1; export Z2K_AU_SOURCE_ONLY
. "$ROOT/lib/utils.sh" 2>/dev/null
. "$ROOT/lib/auto_update.sh" 2>/dev/null
z2k_platform_manifest_ref() {
    [ "${Z2K_OW_MANIFEST_MODE:-}" = snapshot ] || return 0
    printf '%s\n' "${Z2K_AU_TARGET_REF:-}"
}
Z2K_AU_TMP_DIR="$SB/tmp"; mkdir -p "$Z2K_AU_TMP_DIR"
ZAPRET2_DIR="$SB/zd"; mkdir -p "$ZAPRET2_DIR/lua"
_log="$SB/log"
au_log() { printf '%s\n' "$*" >> "$_log"; }

printf 'old\n' > "$ZAPRET2_DIR/lua/a.lua"
printf 'new\n' > "$SB/new.lua"
_sha=$(z2k_sha256_file "$SB/new.lua")
au_snapshot_for_patch() { return 0; }
au_rollback_patch() { return 0; }
au_converge_apply() { au_repo_base > "$SB/base"; return 1; }
manifest() {
    cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{
  "current": "p-85.10",
  "history": [
    $1
  ],
  "install_map": {"files/lua/a.lua": ["$ZAPRET2_DIR/lua/a.lua"]},
  "files_sha256": {"files/lua/a.lua": "$_sha"}
}
EOF
}
for _entry in \
    '{"v":"p-85.10","type":"patch","ref":"p-85.10","changed_files":[]}' \
    '{"v":"p-85.10","type":"patch","changed_files":[]}'; do
    Z2K_AU_TARGET_REF=stale-reinstall-ref; export Z2K_AU_TARGET_REF
    manifest "$_entry"
    case "$_entry" in *'"ref"'*) _want="$Z2K_AU_RAW_BASE/p-85.10" ;; *) _want="$Z2K_AU_REPO_RAW" ;; esac
    au_apply_converge p-85.10 >/dev/null 2>&1
    assert_eq "production ignores inherited ref (${_entry#*ref})" "$_want" "$(cat "$SB/base" 2>/dev/null)"
done

# OpenWrt CI snapshots pin a complete immutable SHA outside history refs. The
# r-86.3 fix must preserve that explicit pin through au_manifest_ref.
Z2K_OW_MANIFEST_MODE=snapshot
Z2K_AU_TARGET_REF=0123456789abcdef0123456789abcdef01234567
export Z2K_OW_MANIFEST_MODE Z2K_AU_TARGET_REF
manifest '{"v":"p-85.10","type":"patch","changed_files":[]}'
au_apply_converge p-85.10 >/dev/null 2>&1
assert_eq "snapshot convergence keeps embedded immutable ref" \
    "${Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/necronicle/z2k}/$Z2K_AU_TARGET_REF" \
    "$(cat "$SB/base" 2>/dev/null)"

printf '\nPASSED: %s, FAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
