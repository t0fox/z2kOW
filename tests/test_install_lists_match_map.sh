#!/bin/sh
# OpenWrt's clean install and update share one complete install_release payload.
# Check that mapped runtime lists actually make it into that payload instead of
# comparing the current release to Keenetic's retired per-file install map.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/z2k-openwrt-lists.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

# The release map remains a build input. Its OpenWrt targets must be inside the
# owned product tree, then stage-common-payload must copy the actual source bytes.
. "$ROOT/lib/release_map.sh"
for name in tcp16_targets.txt tcp16_nets.txt sni_wl_candidates.txt; do
    source="$ROOT/files/lists/$name"
    [ -s "$source" ] || { bad "$name source exists"; continue; }
    destination="$(z2k_install_paths_for openwrt "files/lists/$name")"
    expected="/usr/lib/z2k/lists/$name"
    [ "$destination" = "$expected" ] \
        && ok "$name maps under the OpenWrt product root" \
        || { bad "$name maps under the OpenWrt product root (got $destination)"; continue; }
done

if sh "$ROOT/scripts/openwrt/stage-common-payload.sh" "$ROOT" "$STAGE" >/dev/null; then
    ok "common files are materialized into the single release staging tree"
else
    bad "common payload staging succeeds"
fi

for name in tcp16_targets.txt tcp16_nets.txt sni_wl_candidates.txt; do
    source="$ROOT/files/lists/$name"
    staged="$STAGE/usr/lib/z2k/lists/$name"
    if [ -s "$staged" ] && cmp -s "$source" "$staged"; then
        ok "$name is present byte-for-byte in a fresh OpenWrt payload"
    else
        bad "$name is present byte-for-byte in a fresh OpenWrt payload"
    fi
done

if python3 - "$ROOT/UPDATES.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
artifact = m.get("artifact", {})
assert set(artifact) == {"filename", "url", "sha256", "size_bytes"}
assert artifact["filename"] == "openwrt-rootfs.tar.gz"
assert len(artifact["sha256"]) == 64
assert artifact["size_bytes"] > 0
assert not any(k in m for k in ("install_map", "files_sha256", "components", "package_versions"))
PY
then
    ok "UPDATES.json advertises one full artifact, with no component/file updater map"
else
    bad "UPDATES.json advertises exactly one complete OpenWrt release artifact"
fi

printf '\nPASSED: %s\nFAILED: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
