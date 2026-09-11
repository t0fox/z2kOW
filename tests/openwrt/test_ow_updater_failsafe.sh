#!/bin/sh
# tests/openwrt/test_ow_updater_failsafe.sh - §3 router: безадресный файл
# НЕ двигает версию. Функционально на au_apply_patch с песочницей:
#   unmapped (не builds) -> rc 1, тег стоит;
#   builds/* без адреса -> skip, патч идёт дальше (ставит refresh-binaries).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-updater-failsafe"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-fs.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
export Z2K_AU_TMP_DIR="$T/au" Z2K_AU_LOG_FILE="$T/au.log"
export Z2K_AU_INSTALLED_TAG_FILE="$T/tag" ZAPRET2_DIR="$T/zd"
mkdir -p "$Z2K_AU_TMP_DIR" "$ZAPRET2_DIR/lib" "$T/zd/lua"
printf 'ENABLED=1\n' > "$T/zd/config"
printf 'p-1' > "$T/tag"
#stage "скачивает" всё мгновенно
au_download_repo_file() { printf 'x' > "$2"; return 0; }
# манифест: один маппленный файл + install_map с его адресом
_mk_manifest() {
    cat > "$Z2K_AU_TMP_DIR/UPDATES.json" <<EOF
{"current": "p-2",
 "install_map": {
  "files/lua/z2k-alert.lua": ["$T/zd/lua/z2k-alert.lua"]
 },
 "files_sha256": {},
 "history": [
  {"v": "p-2", "type": "patch", "changed_files": [$1]}
 ]}
EOF
}

# случай 1: чужой путь без адреса -> провал, тег стоит
_mk_manifest '"files/lua/z2k-alert.lua", "some/future-thing.bin"'
au_apply_patch "p-2" "files/lua/z2k-alert.lua
some/future-thing.bin" >/dev/null 2>&1
_rc=$?
[ "$_rc" != "0" ] && _t_ok || _t_bad "unmapped-файл не завалил патч (rc=$_rc)"
assert_eq "тег не двинулся" "p-1" "$(cat "$T/tag")"

# случай 2: builds/* без адреса -> законный skip, патч успешен
_mk_manifest '"files/lua/z2k-alert.lua", "z2k-detect/builds/z2k-detect-linux-arm64"'
au_apply_patch "p-2" "files/lua/z2k-alert.lua
z2k-detect/builds/z2k-detect-linux-arm64" >/dev/null 2>&1
_rc=$?
assert_eq "builds-skip не валит патч" "0" "$_rc"
assert_eq "тег двинулся" "p-2" "$(cat "$T/tag")"
assert_eq "маппленный файл встал" "x" "$(cat "$T/zd/lua/z2k-alert.lua" 2>/dev/null)"

_t_done
