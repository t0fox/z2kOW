#!/bin/sh
# The controlled manifest approves one complete OpenWrt release artifact.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "UPDATES.json").read_text(encoding="utf-8"))
assert set(manifest) == {
    "schema", "branch", "platform", "seq", "current", "upstream", "history", "artifact", "signing"
}
assert manifest["schema"] == 1
assert manifest["branch"] == "main" and manifest["platform"] == "openwrt"
assert manifest["history"] and manifest["history"][-1]["v"] == manifest["current"]
assert all("seq" not in entry for entry in manifest["history"])

artifact = manifest["artifact"]
assert set(artifact) == {"filename", "url", "sha256", "size_bytes"}
assert artifact["filename"] == "openwrt-rootfs.tar.gz"
assert artifact["url"] == (
    "https://github.com/t0fox/z2kOW/releases/download/"
    + manifest["current"] + "/openwrt-rootfs.tar.gz"
)
assert re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
assert isinstance(artifact["size_bytes"], int) and artifact["size_bytes"] > 0
assert not {
    "files_sha256", "install_map", "components", "package_versions"
} & set(manifest)
signing = manifest["signing"]
assert set(signing) == {"key_id"}
assert re.fullmatch(r"[0-9a-f]{64}", signing["key_id"])
assert (root / "scripts/openwrt/release-keys" / f"{signing['key_id']}.pub").is_file()
assert not (root / "UPSTREAM.json").exists()

update = (root / "platform/openwrt/update.sh").read_text(encoding="utf-8")
installer = (root / "scripts/openwrt/install_release.sh").read_text(encoding="utf-8")
builder = (root / "scripts/openwrt/build-release.sh").read_text(encoding="utf-8")
assert "Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release" in update
assert "install_release <release-tag>" in installer
assert "install_release --reinstall <installed-release-tag>" in installer
assert "stage-rootfs.sh" in builder
print(
    f"controlled {manifest['current']} seq {manifest['seq']}: "
    "one full rootfs, install_release(tag)"
)
PY
