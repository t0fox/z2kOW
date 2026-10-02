#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/custom.d"
for script in 50-stun4all 50-discord-media 60-user; do
    printf 'zapret_custom_daemons() { echo "%s:$1"; }\n' "$script" > "$tmp/custom.d/$script"
done
# Disabled bundled scripts are skipped before they are sourced, so even
# top-level statements in a custom.d example cannot run behind the category gate.
printf 'echo sourced >> "%s/source.log"\nzapret_custom_daemons() { echo stun:$1; }\n' "$tmp" > "$tmp/custom.d/50-stun4all"
Z2K_CUSTOM_DIR="$tmp/custom.d"
Z2K_CUSTOM_PID_DIR="$tmp/run"
. "$ROOT/platform/openwrt/customd.sh"
existf() { command -v "$1" >/dev/null 2>&1; }
_z2k_ow_customd_install_category_runner

Z2K_CATEGORY_DISCORD_VOICE=0
out=$(custom_runner zapret_custom_daemons 1)
[ "$out" = '60-user:1' ] || { echo "FAIL: disabled category ran: $out" >&2; exit 1; }
[ ! -e "$tmp/source.log" ] || { echo 'FAIL: disabled category script was sourced' >&2; exit 1; }

Z2K_CATEGORY_DISCORD_VOICE=1
out=$(custom_runner zapret_custom_daemons 0)
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] || {
    echo "FAIL: enabled category did not run all custom.d files: $out" >&2
    exit 1
}

DISABLE_CUSTOM=1
out=$(custom_runner zapret_custom_daemons 1)
[ -z "$out" ] || { echo "FAIL: DISABLE_CUSTOM was ignored: $out" >&2; exit 1; }

# With voice disabled there are no custom daemons to wait for, and the
# postnat overlap guards must not be reinstalled for queues that do not exist.
DISABLE_CUSTOM=0
Z2K_CATEGORY_DISCORD_VOICE=0
z2k_ow_customd_runtime_ready || { echo 'FAIL: disabled voice category is not ready' >&2; exit 1; }
z2k_ow_custom_daemons 1 || { echo 'FAIL: disabled voice category requires customd prerequisites' >&2; exit 1; }
nft() {
    printf '%s\n' "$*" >> "$tmp/nft.calls"
    case "$*" in 'list chain inet zapret2 postnat') printf 'chain postnat {\n}\n' ;; esac
}
INIT_APPLY_FW=1
z2k_ow_customd_firewall_guards_apply || { echo 'FAIL: guard cleanup failed' >&2; exit 1; }
if grep -qE 'insert rule|add rule' "$tmp/nft.calls"; then
    echo 'FAIL: disabled voice category installed NFQUEUE guards' >&2
    exit 1
fi
echo 'SUITE[ow-customd-category]: pass=6 fail=0'
