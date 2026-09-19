#!/bin/sh
# p-85.2 OpenWrt adapter boundary and provenance contract.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-p852-contract"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

_current="$(sed -n 's/^[[:space:]]*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO/UPDATES.json" | head -1)"
_seq="$(sed -n 's/^[[:space:]]*"seq"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\),.*/\1/p' "$REPO/UPDATES.json" | head -1)"
assert_eq "p-85.2 current" "p-85.2" "$_current"
assert_eq "p-85.2 sequence" "110" "$_seq"

. "$REPO/lib/release_map.sh" || exit 1
_ow() { Z2K_PLATFORM=openwrt z2k_install_paths "$1" 2>/dev/null; }
assert_eq "Keenetic installer absent from OpenWrt payload" "" "$(_ow lib/install.sh)"
assert_eq "Instagram helper absent from OpenWrt payload" "" "$(_ow files/z2k-insta-ip-refresh.sh)"

assert_eq "common manifest is not a regular OpenWrt payload target" "" "$(_ow UPDATES.json)"
assert_not_contains "OpenWrt package does not ship common manifest signature" "$REPO/package/openwrt/Makefile" 'UPDATES\.json\.sig'
assert_contains "OpenWrt production path verifies its channel signature" "$REPO/platform/openwrt/manifest.sh" 'au_fetch_pair "$_base/UPDATES.json" "$_base/UPDATES.json.sig"'
assert_contains "snapshot path is explicit and separate" "$REPO/platform/openwrt/manifest.sh" 'snapshot-manifest.json'

_seed="$(mktemp -d /tmp/z2k-p852-seed.XXXXXX)" || exit 1
trap 'rm -rf "$_seed"' EXIT
sh "$REPO/package/openwrt/make-seed.sh" "$REPO" "$_seed/seed.tar.gz" >/dev/null 2>&1 || {
    _t_bad "p-85.2 seed builds"; _t_done; exit 1
}
_meta="$(tar -xzOf "$_seed/seed.tar.gz" usr/lib/z2k/share/seed.meta 2>/dev/null)"
assert_eq "seed tag follows p-85.2 current" "p-85.2" "$(printf '%s\n' "$_meta" | sed -n 's/^tag=//p')"
if tar -tzf "$_seed/seed.tar.gz" 2>/dev/null | grep -q 'UPDATES\.json\.sig'; then
    _t_bad "seed не содержит Keenetic UPDATES.json.sig как OpenWrt signature"
else
    _t_ok
fi

_manifest="$_seed/openwrt-UPDATES.json"
if sh "$REPO/scripts/openwrt/gen-openwrt-manifest.sh" \
       --source-manifest "$REPO/UPDATES.json" --tree "$REPO" --ref p-85.2 \
       --api-min 1 --allow-dirty --refresh-stale-hashes --out "$_manifest" \
       >/dev/null 2>&1 && ! grep -q 'UPDATES\.json\.sig' "$_manifest"; then
    _t_ok
else
    _t_bad "snapshot не использует Keenetic UPDATES.json.sig как OpenWrt signature"
fi

_t_done
