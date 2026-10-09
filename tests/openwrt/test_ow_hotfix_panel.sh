#!/bin/sh
# WebPanel показывает хотфикс с прежним tag + seq как доступное обновление.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-hotfix-panel"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
export Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_STATE="$T/state" Z2K_RELEASE_STATE_LIB="$REPO/platform/openwrt/release_state.sh"
export Z2K_OW_INSTALLED_RELEASE_FILE="$T/state/installed-release"
mkdir -p "$Z2K_STATE"
AU_MANIFEST_CACHE="$T/UPDATES.json"
cp "$REPO/UPDATES.json" "$AU_MANIFEST_CACHE"
TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' "$AU_MANIFEST_CACHE")"
DIGEST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"]["sha256"])' "$AU_MANIFEST_CACHE")"
jsonfilter() {
    local _jf_file _jf_expr
    while [ "$#" -gt 0 ]; do
        case "$1" in -i) _jf_file="$2"; shift 2 ;; -e) _jf_expr="${2#@.}"; shift 2 ;; *) return 2 ;; esac
    done
    python3 - "$_jf_file" "$_jf_expr" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    value = value[key]
if value is not None:
    print(value)
PY
}
. "$REPO/webpanel/cgi/actions.sh"
. "$REPO/platform/openwrt/manifest.sh"
. "$REPO/platform/openwrt/webpanel.sh"
assert_eq "неизвестный digest требует обновления в панели" 1 "$(update_behind_count "$TAG")"
printf '%s\n' "$DIGEST" > "$Z2K_STATE/installed-artifact-sha256"
assert_eq "тот же проверенный архив не считается новым обновлением" 0 "$(update_behind_count "$TAG")"
printf 'повреждено\n' > "$Z2K_STATE/installed-artifact-sha256"
assert_eq "повреждённый digest не скрывает доступный релиз" 1 "$(update_behind_count "$TAG")"
printf '%s\n' "$DIGEST" > "$Z2K_STATE/installed-artifact-sha256"
python3 - "$AU_MANIFEST_CACHE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest['artifact']['sha256'] = 'f' * 64
path.write_text(json.dumps(manifest, indent=2))
PY
assert_eq "новый SHA-256 при том же tag + seq отображается как хотфикс" 1 "$(update_behind_count "$TAG")"
_t_done
