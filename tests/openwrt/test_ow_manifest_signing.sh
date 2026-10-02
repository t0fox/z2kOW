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
    _file="" _expr=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _file="$2"; shift 2 ;;
            -e) _expr="$2"; shift 2 ;;
            *) return 2 ;;
        esac
    done
    python3 - "$_file" "${_expr#@.}" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for item in sys.argv[2].split("."):
    value = value[item]
print(value if isinstance(value, (str, int)) else "")
PY
}

Z2K_ROOT="$T/root"
Z2K_OW_RELEASE_KEYS="$T/keys"
export Z2K_ROOT Z2K_OW_RELEASE_KEYS

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

_t_done
