#!/bin/sh
# tests/openwrt/test_ow_reinstall_guard.sh - §7-9: reinstall fail-closed.
# Функционально на au_apply_reinstall с песочницей:
#   executor=hook -> НЕТ скачивания z2k.sh (sentinel), тег стоит, payload цел;
#   executor missing -> тоже провал без скачивания;
#   без hook (Keenetic) -> legacy-путь качает и исполняет (control).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-reinstall-guard"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
export Z2K_AU_TMP_DIR="$T/au" Z2K_AU_LOG_FILE="$T/au.log"
export Z2K_AU_INSTALLED_TAG_FILE="$T/tag" ZAPRET2_DIR="$T/zd"
unset Z2K_AU_REINSTALL_EXECUTOR Z2K_AU_TARGET_REF
mkdir -p "$Z2K_AU_TMP_DIR" "$T/zd"
printf 'ENABLED=1\n' > "$T/zd/config"
printf 'p-1' > "$T/tag"
printf 'payload' > "$T/zd/canary.txt"
au_log() { :; }
cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<'EOF'
{"current": "p-2", "install_map": {}, "files_sha256": {},
 "history": [{"v": "p-2", "type": "reinstall", "ref": "deadbeef",
 "changed_files": [], "steps": [], "full_install": true}]}
EOF
# legacy-скачивание: sentinel доказывает, что его пытались выполнить
au_download_reinstall_script() { echo "download-attempted" >> "$T/calls"; return 1; }

# --- A. executor-hook: ни скачивания, ни тега, ни payload-правок ---
test_executor() { echo "executor:$1:$2" >> "$T/calls"; return 1; }
Z2K_AU_REINSTALL_EXECUTOR=test_executor; export Z2K_AU_REINSTALL_EXECUTOR
: > "$T/calls"
au_apply_reinstall "p-2" "" >/dev/null 2>&1
_rc=$?
[ "$_rc" != "0" ] && _t_ok || _t_bad "executor fail-closed не вернул ошибку"
assert_contains "executor вызван с тегом" "$T/calls" "executor:p-2:"
if grep -q "download-attempted" "$T/calls"; then
    _t_bad "z2k.sh скачивали при executor-hook"
else
    _t_ok
fi
assert_eq "тег стоит" "p-1" "$(cat "$T/tag")"
assert_eq "payload цел" "payload" "$(cat "$T/zd/canary.txt")"

# --- B. executor missing: тоже провал без скачивания ---
Z2K_AU_REINSTALL_EXECUTOR=no-such-function; export Z2K_AU_REINSTALL_EXECUTOR
: > "$T/calls"
au_apply_reinstall "p-2" "" >/dev/null 2>&1
_rc=$?
[ "$_rc" != "0" ] && _t_ok || _t_bad "missing executor не провал"
if grep -q "download-attempted" "$T/calls"; then
    _t_bad "z2k.sh скачивали при missing executor"
else
    _t_ok
fi
assert_eq "тег стоит (2)" "p-1" "$(cat "$T/tag")"

# --- C. control без hook: legacy качает и исполняет (Keenetic unchanged) ---
unset Z2K_AU_REINSTALL_EXECUTOR
au_download_reinstall_script() {
    echo "download-attempted" >> "$T/calls"
    printf '#!/bin/sh\necho "legacy-executed" >> "%s/calls"\nexit 0\n' "$T" > "$1"
    return 0
}
: > "$T/calls"
au_apply_reinstall "p-2" "" >/dev/null 2>&1
assert_contains "legacy скачал" "$T/calls" "download-attempted"
assert_contains "legacy исполнил" "$T/calls" "legacy-executed"
assert_eq "тег двинулся (legacy ok)" "p-2" "$(cat "$T/tag")"

_t_done
