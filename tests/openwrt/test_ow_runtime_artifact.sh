#!/bin/sh
# The trusted builder must validate the exact engine payload before staging it.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-runtime-artifact"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${Z2K_RUNTIME_ARCHIVE:-${Z2K_RT_TARBALL:-}}"
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "FAIL[ow-runtime-artifact]: Z2K_RUNTIME_ARCHIVE is required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/z2k-runtime-artifact.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

_url="$(sed -n 's/^URL=//p' "$ROOT/platform/openwrt/runtime-pin" | head -1)"
_sha="$(sed -n 's/^SHA256=//p' "$ROOT/platform/openwrt/runtime-pin" | head -1)"
assert_eq "official upstream archive URL" \
    "https://github.com/necronicle/zapret2-z2k/releases/download/v1.0.5.2-z2k-r0/zapret2-v1.0.5.2-z2k-r0-openwrt-embedded.tar.gz" \
    "$_url"
assert_eq "verified upstream archive SHA-256" \
    "02eec373b093083b426c27191bb6af260ac51e4e2739c51270270a351d2a1a16" "$_sha"
assert_eq "pinned archive bytes match the digest" "$_sha" "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
assert_eq "pinned archive exact length" "4339405" "$(wc -c < "$ARCHIVE" | tr -d ' ')"

_root='zapret2-v1.0.5.2-z2k-r0'
for _arch in arm arm64 mips mipsel riscv64 x86 x86_64; do
    for _binary in nfqws2 ip2net mdig; do
        tar -tzf "$ARCHIVE" | grep -Fxq "$_root/binaries/linux-$_arch/$_binary" \
            && _t_ok || _t_bad "runtime omits linux-$_arch/$_binary"
    done
done

tar -xOzf "$ARCHIVE" "$_root/install_bin.sh" > "$TMP/install_bin.sh" || exit 1
assert_eq "root-run installer digest remains verified" \
    "524321c662d5f77feae034208e52a404bdc4286d2b779616e60f420b3b0d93f6" \
    "$(sha256sum "$TMP/install_bin.sh" | awk '{print $1}')"
tar -xOzf "$ARCHIVE" "$_root/binaries/linux-x86_64/nfqws2" > "$TMP/nfqws2" || exit 1
chmod 0755 "$TMP/nfqws2"
_version="$("$TMP/nfqws2" --version 2>&1)"
case "$_version" in *"v1.0.5.2-z2k-r0"*) _t_ok ;; *) _t_bad "host engine reports pinned version: $_version" ;; esac
"$TMP/nfqws2" --dry-run --qnum=200 --filter-tcp=443 --filter-l7=tls > "$TMP/dry-run" 2>&1 \
    && grep -q 'command line parameters verified' "$TMP/dry-run" \
    && _t_ok || _t_bad "pinned engine accepts a TLS profile in dry-run mode"

# OpenWrt keeps zapret2's default TLS reassembly enabled in the argv adapter.
(
    . "$ROOT/platform/openwrt/paths.sh" || exit 1
    . "$ROOT/platform/openwrt/env.sh" || exit 1
    . "$ROOT/platform/openwrt/optbase.sh" || exit 1
    Z2K_ROOT="$ROOT" Z2K_LUA_DIR="$ROOT/files/lua" Z2K_FAKE_DIR="$ROOT/files/fake" \
        Z2K_ZAPRET2_RUNTIME="$TMP/runtime" z2k_ow_optbase
) > "$TMP/optbase" || exit 1
if grep -q -- '--reasm-disable' "$TMP/optbase"; then
    _t_bad "OpenWrt engine argv leaves TLS reassembly enabled"
else
    _t_ok
fi

_t_done
