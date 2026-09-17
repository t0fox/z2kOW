#!/bin/sh
# A package upgrade must add a newly introduced payload entrypoint without
# re-extracting or overwriting the rest of the updater-owned payload.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-seed-additive"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/usr/lib/z2k" "$T/seed/usr/lib/z2k" "$T/tmp"
printf 'new-helper\n' > "$T/seed/usr/lib/z2k/z2k-update-lists.sh"
tar -czf "$T/seed.tar.gz" -C "$T/seed" usr

. "$REPO/platform/openwrt/bootstrap.sh"
Z2K_ROOT="$T/root/usr/lib/z2k"
Z2K_SEED_TARBALL="$T/seed.tar.gz"
Z2K_TMP="$T/tmp"
Z2K_PAYLOAD_ADDITIVE=z2k-update-lists.sh

z2k_ow_seed_additive
assert_file "additive helper installed" "$Z2K_ROOT/z2k-update-lists.sh"
assert_eq "additive helper content" "new-helper" "$(cat "$Z2K_ROOT/z2k-update-lists.sh" | tr -d '\r\n')"

printf 'operator-version\n' > "$Z2K_ROOT/z2k-update-lists.sh"
z2k_ow_seed_additive
assert_eq "existing payload is preserved" "operator-version" "$(cat "$Z2K_ROOT/z2k-update-lists.sh" | tr -d '\r\n')"

_t_done
