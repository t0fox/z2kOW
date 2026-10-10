#!/bin/sh
# OpenWrt accepts only a manifest signature from its installed release keyring.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-manifest-signing"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/lib/auto_update.sh"
. "$REPO/platform/openwrt/manifest.sh"

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/keys"
openssl genpkey -algorithm Ed25519 -out "$T/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/test.key" -pubout -out "$T/test.pub" >/dev/null 2>&1 || exit 1
KEY_ID="$(openssl pkey -pubin -in "$T/test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
case "$KEY_ID" in *[!0-9a-f]*|'') echo 'FAIL[ow-manifest-signing]: could not derive test key id' >&2; exit 1 ;; esac
[ "${#KEY_ID}" -eq 64 ] || { echo 'FAIL[ow-manifest-signing]: malformed test key id' >&2; exit 1; }
cp "$T/test.pub" "$T/keys/$KEY_ID.pub"
cat > "$T/UPDATES.json" <<EOF
{"signing":{"key_id":"$KEY_ID"},"current":"p-86.13"}
EOF
openssl pkeyutl -sign -rawin -inkey "$T/test.key" -in "$T/UPDATES.json" -out "$T/UPDATES.json.sig" >/dev/null 2>&1 || exit 1

jsonfilter() {
    _file="" _expr="" _type=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _file="$2"; shift 2 ;;
            -e) _expr="$2"; shift 2 ;;
            -t) _expr="$2"; _type=1; shift 2 ;;
            *) return 2 ;;
        esac
    done
    python3 - "$_file" "${_expr#@.}" "$_type" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    for item in sys.argv[2].split("."):
        value = value[item]
except (KeyError, TypeError, IndexError):
    raise SystemExit(1)
if sys.argv[3] == "1":
    if isinstance(value, dict):
        print("object")
    elif isinstance(value, list):
        print("array")
    elif isinstance(value, bool):
        print("boolean")
    elif isinstance(value, int):
        print("int")
    elif isinstance(value, float):
        print("double")
    elif isinstance(value, str):
        print("string")
    else:
        print("null")
elif value is None:
    raise SystemExit(1)
else:
    print(value if isinstance(value, (str, int, float)) else "")
PY
}

Z2K_ROOT="$T/root"
Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
Z2K_OW_RELEASE_KEYS="$T/keys"
export Z2K_ROOT Z2K_ADAPTER_DIR Z2K_OW_RELEASE_KEYS

z2k_ow_manifest_verify_signature "$T/UPDATES.json" "$T/UPDATES.json.sig" \
    && _t_ok || _t_bad "valid Ed25519 signature verifies using signing.key_id"

cp "$T/UPDATES.json" "$T/modified.json"
sed 's/p-86.13/p-86.14/' "$T/UPDATES.json" > "$T/modified.json"
z2k_ow_manifest_verify_signature "$T/modified.json" "$T/UPDATES.json.sig" \
    && _t_bad "modified manifest was rejected" || _t_ok

openssl genpkey -algorithm Ed25519 -out "$T/wrong.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/wrong.key" -pubout -out "$T/wrong.pub" >/dev/null 2>&1 || exit 1
mkdir -p "$T/wrong-keys"
cp "$T/wrong.pub" "$T/wrong-keys/$KEY_ID.pub"
Z2K_OW_RELEASE_KEYS="$T/wrong-keys" \
    z2k_ow_manifest_verify_signature "$T/UPDATES.json" "$T/UPDATES.json.sig" \
    && _t_bad "wrong public key was rejected" || _t_ok

z2k_ow_manifest_verify_signature "$T/UPDATES.json" "$T/missing.sig" \
    && _t_bad "missing signature was rejected" || _t_ok

sed "s/$KEY_ID/..\\/outside/" "$T/UPDATES.json" > "$T/traversal.json"
z2k_ow_manifest_verify_signature "$T/traversal.json" "$T/UPDATES.json.sig" \
    && _t_bad "path traversal key id was rejected" || _t_ok

# Runtime records have one legacy shape, a one-release bridge shape, and the
# new architecture map. The selected digest and download URL must follow the
# requested target; a present map never falls back to the complete archive.
python3 - "$T" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
base = "https://github.com/t0fox/z2kOW/releases/download/openwrt-" + "a" * 40 + "/"
arches = ("arm64", "arm", "x86_64", "x86", "mips", "mipsel", "riscv64")
records = {}
for i, arch in enumerate(arches, 1):
    filename = f"openwrt-rootfs-{arch}.tar.gz"
    records[arch] = {
        "filename": filename,
        "url": base + filename,
        "sha256": str(i) * 64,
        "size_bytes": 1000 + i,
        "unpacked_size_bytes": 2000 + i,
    }
legacy = {
    "filename": "openwrt-rootfs.tar.gz",
    "url": base + "openwrt-rootfs.tar.gz",
    "sha256": "f" * 64,
    "size_bytes": 9000,
}
manifest = {
    "schema": 1,
    "branch": "main",
    "platform": "openwrt",
    "current": "p-86.13",
    "seq": 135,
    "upstream": {
        "repository": "necronicle/z2k",
        "branch": "z2k-enhanced",
        "tag": "p-86.13",
        "commit": "b" * 40,
    },
    "signing": {"key_id": "c" * 64},
}
for name, document in (
    ("legacy", {**manifest, "artifact": legacy}),
    ("transition", {**manifest, "artifact": legacy, "artifacts": records}),
    ("per-arch", {**manifest, "artifacts": records}),
    ("incomplete", {**manifest, "artifact": legacy, "artifacts": {"x86_64": records["x86_64"]}}),
):
    (root / f"{name}.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY

if z2k_ow_manifest_select_artifact "$T/legacy.json" arm64; then
    assert_eq "legacy manifest selects legacy mode" legacy "$Z2K_OW_ARTIFACT_MODE"
    assert_eq "legacy manifest keeps the old full archive URL" \
        "https://github.com/t0fox/z2kOW/releases/download/openwrt-$(printf 'a%.0s' $(seq 1 40))/openwrt-rootfs.tar.gz" \
        "$Z2K_OW_ARTIFACT_URL"
    assert_eq "legacy digest is normalized once by the selector" "$(printf 'f%.0s' $(seq 1 64))" "$Z2K_OW_ARTIFACT_SHA256"
else
    _t_bad "legacy-only signed manifest selects its full archive"
fi
if z2k_ow_manifest_select_artifact "$T/transition.json" arm64; then
    assert_eq "transition manifest prefers per-architecture mode" per-arch "$Z2K_OW_ARTIFACT_MODE"
    assert_eq "transition manifest selects only arm64 asset" \
        "https://github.com/t0fox/z2kOW/releases/download/openwrt-$(printf 'a%.0s' $(seq 1 40))/openwrt-rootfs-arm64.tar.gz" \
        "$Z2K_OW_ARTIFACT_URL"
    assert_eq "selected architecture digest is exact" "$(printf '1%.0s' $(seq 1 64))" "$Z2K_OW_ARTIFACT_SHA256"
    assert_eq "selected unpacked size is available to preflight" 2001 "$Z2K_OW_ARTIFACT_UNPACKED_SIZE_BYTES"
else
    _t_bad "transition manifest selects the target per-architecture asset"
fi
if z2k_ow_manifest_select_artifact "$T/per-arch.json" x86_64; then
    assert_eq "per-arch-only manifest selects x86_64" \
        "https://github.com/t0fox/z2kOW/releases/download/openwrt-$(printf 'a%.0s' $(seq 1 40))/openwrt-rootfs-x86_64.tar.gz" \
        "$Z2K_OW_ARTIFACT_URL"
    assert_eq "x86_64 selected size is independent of the legacy asset" 1003 "$Z2K_OW_ARTIFACT_SIZE_BYTES"
else
    _t_bad "per-arch-only manifest selects its requested record"
fi
if z2k_ow_manifest_select_artifact "$T/incomplete.json" arm64 2>/dev/null; then
    _t_bad "incomplete per-architecture map cannot fall back to valid legacy artifact"
else
    _t_ok
fi
python3 - "$T/transition.json" "$T/invalid-selected.json" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
document = json.loads(source.read_text(encoding="utf-8"))
document["artifacts"]["arm64"]["sha256"] = "bad-digest"
target.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
if z2k_ow_manifest_select_artifact "$T/invalid-selected.json" arm64 2>/dev/null; then
    _t_bad "invalid selected per-architecture record cannot fall back to valid legacy artifact"
else
    _t_ok
fi
if z2k_ow_manifest_select_artifact "$T/per-arch.json" unsupported 2>/dev/null; then
    _t_bad "unsupported architecture cannot select any asset"
else
    _t_ok
fi
if rg -n 'artifact\.sha256' "$REPO/platform/openwrt/release.sh" "$REPO/platform/openwrt/release_state.sh" >/dev/null; then
    _t_bad "release/state consumers do not parse artifact.sha256 outside the centralized selector"
else
    _t_ok
fi
python3 - "$T/legacy.json" "$T/local.json" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
document = json.loads(source.read_text(encoding="utf-8"))
document["artifact"]["url"] = "http://127.0.0.1:17777/openwrt-rootfs.tar.gz"
target.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
PY
assert_eq "bootstrap-bound receipt digest keeps its verified local artifact URL" \
    "$(printf 'f%.0s' $(seq 1 64))" \
    "$(z2k_ow_manifest_artifact_sha256 "$T/local.json" arm64 http://127.0.0.1:17777/openwrt-rootfs.tar.gz 2>/dev/null)"

_t_done
