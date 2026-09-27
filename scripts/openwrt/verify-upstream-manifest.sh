#!/bin/sh
# Verify the immutable upstream release manifest retained by the OpenWrt
# product branch. Adapted common source files intentionally need not match the
# hashes in this historical upstream manifest.
set -eu

ROOT=${Z2K_MANIFEST_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
PIN="$ROOT/tests/openwrt/MANIFEST_BASELINE"
MANIFEST="$ROOT/UPDATES.json"
SIGNATURE="$ROOT/UPDATES.json.sig"
PUBKEY="$ROOT/files/etc/z2k-update-pub.pem"

fail() {
    printf 'verify-upstream-manifest: %s\n' "$1" >&2
    exit 1
}

[ -s "$PIN" ] || fail "missing immutable pin: $PIN"
[ -s "$MANIFEST" ] || fail "missing upstream manifest: $MANIFEST"
[ -s "$SIGNATURE" ] || fail "missing upstream signature: $SIGNATURE"
[ -s "$PUBKEY" ] || fail "missing upstream public key: $PUBKEY"

BASELINE=$(tr -d '\r\n' < "$PIN")
case "$BASELINE" in
    ''|*[!0-9a-f]*) fail "invalid manifest baseline: $BASELINE" ;;
esac
[ "${#BASELINE}" -eq 40 ] || fail "manifest baseline must be a 40-character commit"
git -C "$ROOT" cat-file -e "$BASELINE^{commit}" 2>/dev/null \
    || fail "manifest baseline commit is unavailable: $BASELINE"

for file in UPDATES.json UPDATES.json.sig; do
    git -C "$ROOT" cat-file -e "$BASELINE:$file" 2>/dev/null \
        || fail "baseline does not contain $file"
    git -C "$ROOT" diff --quiet "$BASELINE" HEAD -- "$file" \
        || fail "$file differs from immutable baseline $BASELINE"
    git -C "$ROOT" show "$BASELINE:$file" | cmp -s - "$ROOT/$file" \
        || fail "working-tree $file differs from immutable baseline $BASELINE"
done

openssl pkeyutl -verify -rawin -pubin -inkey "$PUBKEY" \
    -in "$MANIFEST" -sigfile "$SIGNATURE" >/dev/null 2>&1 \
    || fail "upstream manifest signature does not verify with the pinned key"

printf 'UPSTREAM_MANIFEST_PIN: unchanged and signature verified (%s)\n' "$BASELINE"
