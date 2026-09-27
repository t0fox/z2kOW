#!/bin/sh
# Fetch and verify the upstream release tags whose payloads form the OpenWrt
# p-86.1 payload and the p-85.16 WARP runtime source baseline. Expected commit
# IDs pin both source content and signatures for each semantic boundary.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
PUBKEY="${Z2K_UPSTREAM_PUBKEY:-$ROOT/files/etc/z2k-update-pub.pem}"
[ -s "$PUBKEY" ] || { echo "verify-upstream-tags: missing public key: $PUBKEY" >&2; exit 1; }

for _ref in p-85.10 p-85.11 r-85.12 p-85.13 p-85.14 p-85.15 p-85.16 p-86 p-86.1; do
    if ! git rev-parse --verify -q "refs/tags/$_ref^{tag}" >/dev/null; then
        git fetch --no-tags https://github.com/necronicle/z2k.git \
            "refs/tags/$_ref:refs/tags/$_ref"
    fi
done

_signers=$(mktemp)
trap 'rm -f "$_signers"' EXIT HUP INT TERM
python3 - "$PUBKEY" "$_signers" <<'PYEOF'
import base64, struct, subprocess, sys
der = subprocess.run(
    ["openssl", "pkey", "-pubin", "-in", sys.argv[1], "-outform", "DER"],
    capture_output=True, check=True,
).stdout
def ssh_string(value):
    return struct.pack(">I", len(value)) + value
blob = ssh_string(b"ssh-ed25519") + ssh_string(der[-32:])
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write("z2k-release ssh-ed25519 " + base64.b64encode(blob).decode() + "\n")
PYEOF

for _pair in \
    'p-85.10 c141373cf783cc9ffea3f1ae83b1b957b64e7437' \
    'p-85.11 493f63d17407f38916c6044c43af556a95b773e2' \
    'r-85.12 0cc9207fde8aa60ba0b170a918f66643af7e364b' \
    'p-85.13 53cd74466094c60219b875073efbee50d058ddf3' \
    'p-85.14 fad8b8aaae3674e8c7f6c40129c21f364bdd8a2c' \
    'p-85.15 75bf2fcf42ea866c986e2e9f042b8a18ebe63603' \
    'p-85.16 2c1dc58d961e51d1845039c6741e4629f4e77be6' \
    'p-86 abd92d2ad5d5a4032eaf4dd8e67d08106e9031cd' \
    'p-86.1 950928ee615431f3442640b08a9a1cb877641900'; do
    set -- $_pair
    _tag=$1
    _expected=$2
    _actual=$(git rev-parse "$_tag^{commit}")
    [ "$_actual" = "$_expected" ] || {
        printf 'verify-upstream-tags: %s resolved to %s, expected %s\n' "$_tag" "$_actual" "$_expected" >&2
        exit 1
    }
    git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$_signers" verify-tag "$_tag"
    printf 'verified upstream tag %s (%s)\n' "$_tag" "$_actual"
done
