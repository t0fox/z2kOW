#!/bin/sh
# Fresh OpenWrt install verifies one signed manifest and enters install_release(tag).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/luci_fixture.sh"
_t_plan "ow-installer"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO/scripts/openwrt/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-installer.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
BIN="$T/bin"; TMPDIR="$T/tmp"; SYS="$T/sys"
mkdir -p "$BIN" "$TMPDIR" "$SYS/etc/init.d" "$SYS/etc/z2k/state" "$SYS/www/luci-static"

command -v openssl >/dev/null 2>&1 || { _t_bad "openssl unavailable"; _t_done; exit $?; }
openssl genpkey -algorithm ED25519 -out "$T/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/test.key" -pubout -out "$T/test.pub" >/dev/null 2>&1 || exit 1

mkdir -p "$T/payload/usr/sbin" "$T/payload/usr/lib/z2k/lib" \
    "$T/payload/usr/lib/z2k/platform/openwrt"
cat > "$T/payload/usr/sbin/install_release" <<'ENGINE'
#!/bin/sh
[ "$#" = 1 ] || exit 2
printf '%s\n' "$1" > "$Z2K_TEST_INSTALL_CALL"
[ -s "$Z2K_OW_BOOTSTRAP_MANIFEST" ] && [ -s "$Z2K_OW_BOOTSTRAP_SIGNATURE" ] \
    && [ -s "$Z2K_OW_BOOTSTRAP_ARTIFACT" ] || exit 3
printf 'tag=%s\nseq=%s\n' "$1" 136 > "$Z2K_TEST_SYSROOT/etc/z2k/state/installed-release"
ENGINE
chmod 755 "$T/payload/usr/sbin/install_release"
for f in utils.sh auto_update.sh; do printf '#!/bin/sh\n' > "$T/payload/usr/lib/z2k/lib/$f"; done
for f in paths.sh env.sh manifest.sh release.sh bootstrap.sh; do
    printf '#!/bin/sh\n' > "$T/payload/usr/lib/z2k/platform/openwrt/$f"
done
printf '/usr/lib/z2k\n' > "$T/payload/usr/lib/z2k/platform/openwrt/owned-paths.txt"
tar -czf "$T/openwrt-rootfs.tar.gz" -C "$T/payload" \
    usr/sbin/install_release usr/lib/z2k/lib/utils.sh usr/lib/z2k/lib/auto_update.sh \
    usr/lib/z2k/platform/openwrt/paths.sh usr/lib/z2k/platform/openwrt/env.sh \
    usr/lib/z2k/platform/openwrt/manifest.sh usr/lib/z2k/platform/openwrt/release.sh \
    usr/lib/z2k/platform/openwrt/bootstrap.sh usr/lib/z2k/platform/openwrt/owned-paths.txt
ARTIFACT_SHA="$(sha256sum "$T/openwrt-rootfs.tar.gz" | awk '{print $1}')"
ARTIFACT_SIZE="$(wc -c < "$T/openwrt-rootfs.tar.gz" | tr -d ' \t\r\n')"
cat > "$T/UPDATES.json" <<EOF
{"schema":1,"branch":"main","platform":"openwrt","seq":136,"current":"p-86.13","upstream":{"repository":"necronicle/z2k","branch":"z2k-enhanced","tag":"p-86.13","commit":"7f630a9d459052b9c9c9eded06298f1b8f7f0a22"},"history":[{"v":"p-86.13","type":"patch","ts":"2026-10-02T06:39:48Z","ref":"p-86.13","desc":"fixture","changed_files":["files/z2k-warp.sh"]}],"artifact":{"filename":"openwrt-rootfs.tar.gz","url":"https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz","sha256":"$ARTIFACT_SHA","size_bytes":$ARTIFACT_SIZE}}
EOF
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" || exit 1

# Render the installer with an isolated fixture key. Production source keeps
# its real key pinned and has no test-key override.
python3 - "$INSTALLER" "$T/install.sh" "$T/test.pub" <<'PY' || exit 1
from pathlib import Path
import sys
source, output, fixture_key = map(Path, sys.argv[1:])
text = source.read_text(encoding="utf-8")
start = text.index("-----BEGIN PUBLIC KEY-----")
end = text.index("-----END PUBLIC KEY-----", start) + len("-----END PUBLIC KEY-----")
text = text[:start] + fixture_key.read_text(encoding="utf-8").strip() + text[end:]
output.write_text(text, encoding="utf-8")
PY
chmod 755 "$T/install.sh"

cat > "$BIN/id" <<'ID'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exit 2
ID
cat > "$BIN/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TEST_APK_LOG"
case "$1" in
    update) exit 0 ;;
    add)
        for arg in "$@"; do
            case "$arg" in z2k-*|packages.adb) echo "forbidden product package: $arg" >&2; exit 17 ;; esac
        done
        exit 0 ;;
    *) echo "unexpected apk command: $*" >&2; exit 18 ;;
esac
APK
cat > "$BIN/wget" <<'WGET'
#!/bin/sh
dest= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        -T) shift 2 ;;
        -O) dest="$2"; shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    https://raw.githubusercontent.com/t0fox/z2kOW/main/UPDATES.json) cp "$Z2K_TEST_MANIFEST" "$dest" ;;
    https://raw.githubusercontent.com/t0fox/z2kOW/main/UPDATES.json.sig)
        if [ "${Z2K_TEST_BAD_SIGNATURE:-0}" = 1 ]; then printf 'bad-signature' > "$dest"; else cp "$Z2K_TEST_SIGNATURE" "$dest"; fi ;;
    https://github.com/t0fox/z2kOW/releases/download/p-86.13/openwrt-rootfs.tar.gz)
        if [ "${Z2K_TEST_BAD_ARTIFACT:-0}" = 1 ]; then printf x > "$dest"; else cp "$Z2K_TEST_ARTIFACT" "$dest"; fi ;;
    *) echo "unexpected URL: $url" >&2; exit 19 ;;
esac
WGET
cat > "$BIN/jsonfilter" <<'JSONFILTER'
#!/bin/sh
exec python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
filename = expression = None
while args:
    arg = args.pop(0)
    if arg == "-i": filename = args.pop(0)
    elif arg == "-e": expression = args.pop(0).removeprefix("@.")
    else: raise SystemExit(2)
value = json.load(open(filename, encoding="utf-8"))
for key in expression.split("."):
    value = value[key]
if value is not None: print(value)
PY
JSONFILTER
chmod 755 "$BIN/id" "$BIN/apk" "$BIN/wget" "$BIN/jsonfilter"

cat > "$SYS/etc/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
RELEASE
printf 'LuCI assets\n' > "$SYS/www/luci-static/index"
luci_fixture_seed "$SYS" || exit 1
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
export PATH="$BIN:/usr/bin:/bin" TMPDIR Z2K_TEST_MANIFEST="$T/UPDATES.json" \
    Z2K_OPENWRT_RELEASE_FILE="$SYS/etc/openwrt_release" \
    Z2K_TEST_SIGNATURE="$T/UPDATES.json.sig" Z2K_TEST_ARTIFACT="$T/openwrt-rootfs.tar.gz" \
    Z2K_TEST_INSTALL_CALL="$T/install-call" Z2K_TEST_APK_LOG="$T/apk.log" \
    Z2K_TEST_SYSROOT="$SYS"

if sh "$T/install.sh" > "$T/out" 2>&1; then _t_ok; else _t_bad "fresh bootstrap failed: $(cat "$T/out")"; fi
assert_eq "bootstrap enters the unified installer once with controlled tag" p-86.13 "$(cat "$T/install-call" 2>/dev/null)"
assert_eq "fresh bootstrap writes the single installed release state" "tag=p-86.13
seq=136" "$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null)"
assert_eq "bootstrap installs only required OpenWrt system dependencies" \
    "update
add ca-bundle openssl-util jsonfilter" "$(cat "$T/apk.log" 2>/dev/null)"
assert_not_contains "bootstrap contains no z2kOW APK or feed installation" "$INSTALLER" 'z2k-(adapter|webpanel|zapret2-runtime|warp-runtime)|packages\.adb|repositories\.d|apk (add|del).*z2k'
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "fresh bootstrap preserves LuCI and uhttpd"

# A bad signature and a digest mismatch both fail before install_release is run.
rm -f "$T/install-call" "$SYS/etc/z2k/state/installed-release"
Z2K_TEST_BAD_SIGNATURE=1 sh "$T/install.sh" > "$T/bad-signature.out" 2>&1 && _t_bad "bad signature was accepted"
[ -f "$T/install-call" ] && _t_bad "bad signature reached install_release" || _t_ok
Z2K_TEST_BAD_SIGNATURE=0 Z2K_TEST_BAD_ARTIFACT=1 sh "$T/install.sh" > "$T/bad-artifact.out" 2>&1 && _t_bad "bad artifact was accepted"
[ -f "$T/install-call" ] && _t_bad "bad artifact reached install_release" || _t_ok

_t_done
