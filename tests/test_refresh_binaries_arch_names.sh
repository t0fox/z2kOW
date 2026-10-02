#!/bin/sh
# Keep the legacy Keenetic binary-name resolver covered with a synthetic map;
# OpenWrt installs the same binaries inside its one complete rootfs artifact.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-binary-map.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
FIXTURE="$TMP/legacy-binaries.json"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

# This fixture exercises the old Keenetic name lookup without adding a second
# binary-updater authority to OpenWrt's controlled UPDATES.json.
{
    printf '{\n  "files_sha256": {\n'
    for file in "$ROOT"/mtproxy-client/builds/*-linux-* "$ROOT"/z2k-detect/builds/*-linux-*; do
        [ -f "$file" ] || continue
        printf '    "%s": "%064d",\n' "${file#"$ROOT"/}" 0
    done
    printf '    "sentinel": "%064d"\n  }\n}\n' 0
} > "$FIXTURE"

. "$ROOT/lib/utils.sh" >/dev/null 2>&1
. "$ROOT/lib/auto_update.sh" >/dev/null 2>&1
command -v au_bin_goarch >/dev/null 2>&1 || { echo "missing au_bin_goarch"; exit 1; }
command -v au_bin_manifest_paths >/dev/null 2>&1 || { echo "missing au_bin_manifest_paths"; exit 1; }

for hw in aarch64 armv7l x86_64 i686 mips mipsel mips64el ppc riscv64; do
    goarch=$(HW="$hw" sh -c '
        . "$1/lib/utils.sh" >/dev/null 2>&1
        . "$1/lib/auto_update.sh" >/dev/null 2>&1
        get_arch() { echo "$HW"; }
        au_bin_goarch
    ' sh "$ROOT")
    [ -n "$goarch" ] || { bad "$hw: architecture mapping exists"; continue; }
    paths=$(au_bin_manifest_paths "$FIXTURE" "$goarch")
    miss=""
    for component in tg-mtproxy-client z2k-detect; do
        printf '%s\n' "$paths" | grep -q "/${component}-linux-" || miss="$miss $component"
    done
    [ -z "$miss" ] \
        && ok "$hw (goarch=$goarch): legacy resolver finds expected binaries" \
        || bad "$hw (goarch=$goarch): missing:$miss"
done

if python3 - "$ROOT/UPDATES.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["platform"] == "openwrt"
assert m["artifact"]["filename"] == "openwrt-rootfs.tar.gz"
assert not any(key in m for key in ("files_sha256", "install_map", "components", "package_versions"))
PY
then
    ok "OpenWrt manifest has one full artifact and no component/file updater map"
else
    bad "OpenWrt manifest has one full artifact and no component/file updater map"
fi

grep -q 'exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" "$2"' \
    "$ROOT/platform/openwrt/update.sh" \
    && ok "OpenWrt updates converge through install_release(tag)" \
    || bad "OpenWrt updates converge through install_release(tag)"

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
