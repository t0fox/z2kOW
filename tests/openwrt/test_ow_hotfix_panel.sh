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
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
mkdir -p "$Z2K_STATE"
AU_MANIFEST_CACHE="$T/UPDATES.json"
cp "$REPO/UPDATES.json" "$AU_MANIFEST_CACHE"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["current"])' "$AU_MANIFEST_CACHE")"
DIGEST="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get("artifacts",{}).get("arm64",m.get("artifact",{}))["sha256"])' "$AU_MANIFEST_CACHE")"
jsonfilter() {
    local _jf_file _jf_expr _jf_type=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _jf_file="$2"; shift 2 ;;
            -e) _jf_expr="${2#@.}"; shift 2 ;;
            -t) _jf_expr="${2#@.}"; _jf_type=1; shift 2 ;;
            *) return 2 ;;
        esac
    done
    python3 - "$_jf_file" "$_jf_expr" "$_jf_type" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
try:
    for key in sys.argv[2].split('.'):
        value = value[key]
except (KeyError, TypeError, IndexError):
    raise SystemExit(1)
if sys.argv[3] == '1':
    print('object' if isinstance(value, dict) else 'array' if isinstance(value, list) else 'string')
elif value is not None:
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
manifest.get('artifacts', {}).get('arm64', manifest.get('artifact', {}))['sha256'] = 'f' * 64
path.write_text(json.dumps(manifest, indent=2))
PY
assert_eq "новый SHA-256 при том же tag + seq отображается как хотфикс" 1 "$(update_behind_count "$TAG")"

# The OpenWrt panel must compare the digest selected for its local architecture
# when a signed release uses per-architecture records and has no legacy field.
python3 - "$AU_MANIFEST_CACHE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
base = 'https://github.com/t0fox/z2kOW/releases/download/openwrt-' + 'a' * 40 + '/'
manifest.pop('artifact', None)
manifest['artifacts'] = {
    'arm64': {
        'filename': 'openwrt-rootfs-arm64.tar.gz',
        'url': base + 'openwrt-rootfs-arm64.tar.gz',
        'sha256': 'a' * 64,
        'size_bytes': 1200,
        'unpacked_size_bytes': 3400,
    },
    'x86_64': {
        'filename': 'openwrt-rootfs-x86_64.tar.gz',
        'url': base + 'openwrt-rootfs-x86_64.tar.gz',
        'sha256': 'b' * 64,
        'size_bytes': 1300,
        'unpacked_size_bytes': 3500,
    },
}
path.write_text(json.dumps(manifest, indent=2))
PY
printf '%s\n' "$(printf 'a%.0s' $(seq 1 64))" > "$Z2K_STATE/installed-artifact-sha256"
assert_eq "per-arch hotfix receipt uses arm64 digest on arm64 device" 0 "$(update_behind_count "$TAG")"
printf '%s\n' "$(printf 'b%.0s' $(seq 1 64))" > "$Z2K_STATE/installed-artifact-sha256"
assert_eq "x86_64 digest cannot hide an arm64 hotfix" 1 "$(update_behind_count "$TAG")"
_t_done
