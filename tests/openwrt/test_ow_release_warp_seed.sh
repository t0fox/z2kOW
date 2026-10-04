#!/bin/sh
# A successful canonical OpenWrt install seeds missing WARP game lists without
# turning an optional community feed into an install/healthcheck dependency.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-warp-seed"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REL="$REPO/platform/openwrt/release.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warp-seed.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

assert_contains "canonical installer starts the optional seed only after success and lock release" "$REL" \
    '[ "$_rc" -ne 0 ] || z2k_ow_seed_warp_games'

awk '/^z2k_ow_seed_warp_games\(\) \{/,/^}/' "$REL" > "$T/seed.sh"
assert_file "canonical release installer exposes first-run WARP seed" "$T/seed.sh"
. "$T/seed.sh"

mkdir -p "$T/root/lists/warp/games" "$T/log" "$T/adapter"
cat > "$T/root/z2k-update-lists.sh" <<'EOF'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$1" "$ZAPRET2_DIR" "$CONFIG_FILE" "$LOG_FILE" >> "$SEED_CALLS"
EOF
chmod +x "$T/root/z2k-update-lists.sh"
export Z2K_ROOT="$T/root" Z2K_ADAPTER_DIR="$T/adapter"
export Z2K_CONFIG="$T/etc/config" Z2K_LOG="$T/log" SEED_CALLS="$T/calls"

z2k_ow_seed_warp_games
_n=0
while [ ! -s "$T/calls" ] && [ "$_n" -lt 30 ]; do sleep 0.1; _n=$((_n + 1)); done
assert_contains "empty game directory starts the shared updater in background" "$T/calls" \
    "warp-games|$T/root|$T/etc/config|$T/log/z2k-warp-games.log"

printf '1.2.3.4\n' > "$T/root/lists/warp/games/Steam.txt"
rm -f "$T/calls"
z2k_ow_seed_warp_games
sleep 0.2
assert_eq "existing game data is not fetched again after successful install" \
    "0" "$(if [ -f "$T/calls" ]; then wc -l < "$T/calls"; else echo 0; fi)"

rm -f "$T/root/z2k-update-lists.sh"
z2k_ow_seed_warp_games
assert_eq "missing optional updater does not fail canonical release" "0" "$?"

_t_done
