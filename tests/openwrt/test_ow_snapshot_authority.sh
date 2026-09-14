#!/bin/sh
# tests/openwrt/test_ow_snapshot_authority.sh - audit L: snapshot-пакет ставит
# embedded immutable truth ДАЖЕ если production channel онлайн и новее.
# Фикстура: embedded snapshot (commit a) + "канал", отдающий манифест новее (b).
# au_fetch_manifest стаб: зовут — пишем вызов (его звать НЕ должны).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-snapshot-authority"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-snapauth.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/share" "$T/bin"
export Z2K_ROOT="$T/root" Z2K_BIN="$T/bin" Z2K_TMP="$T/tmp"
export Z2K_AU_TMP_DIR="$T/tmp/update"
mkdir -p "$T/bin" "$T/tmp/update"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/binaries.sh" || exit 1
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" || exit 1

# Настоящий au недоступен изолированно — стабы именно точек ветвления:
# fetch (канал) обязан НЕ вызываться; platform_ok и refresh — вызываются.
au_fetch_manifest() { echo "FETCH-CALLED" >> "$T/calls"; printf '{"current":"p-99.99"}\n' > "$Z2K_AU_TMP_DIR/UPDATES.json"; return 0; }
au_manifest_platform_ok() { echo "platform-ok:$1" >> "$T/calls"; return 0; }
au_step_refresh_binaries() { echo "refresh" >> "$T/calls"; return 0; }
au_log() { echo "aulog:$*" >> "$T/calls"; }

printf '{"current":"p-84.17","snapshot":true}\n' > "$T/root/share/snapshot-manifest.json"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$T/root/share/snapshot-commit"

: > "$T/calls"
z2k_ow_ensure_binaries >/dev/null 2>&1
assert_eq "ensure rc" "0" "$?"
if grep -q "FETCH-CALLED" "$T/calls"; then
    _t_bad "канал опрошен при наличии snapshot (reproducibility нарушена)"
else
    _t_ok
fi
assert_contains "TMP манифест == snapshot" "$T/tmp/update/UPDATES.json" '"snapshot":true'
assert_eq "TARGET_REF == snapshot-commit" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$Z2K_AU_TARGET_REF"
assert_contains "refresh вызван" "$T/calls" "refresh"

# Без embedded snapshot — канальный путь как раньше (fetch вызывается).
rm -f "$T/root/share/snapshot-manifest.json" "$T/root/share/snapshot-commit"
rm -f "$T/tmp/update/UPDATES.json"
: > "$T/calls"
z2k_ow_ensure_binaries >/dev/null 2>&1
assert_eq "channel rc" "0" "$?"
assert_contains "без snapshot канал опрашивается" "$T/calls" "FETCH-CALLED"

_t_done
