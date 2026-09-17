#!/bin/sh
# tests/openwrt/test_ow_warp_games_flow.sh - the OpenWrt gaming-list refresh
# reaches the package-owned root, canonical config, and platform WARP reload.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-games-flow"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-games-flow.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root" "$T/etc" "$T/bin"
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
cat > "$T/index.json" <<'EOF'
{"game_map":{"Steam":[],"Other_Games":[]}}
EOF
cat > "$T/bin/warp.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_WARP_FLOW_CALLS"
EOF
chmod +x "$T/bin/warp.sh"

export Z2K_UL_SOURCE_ONLY=1 ZAPRET2_DIR="$T/root" CONFIG_FILE="$T/etc/config"
export LOG_FILE="$T/update.log" Z2K_WARP_IPSET_SCRIPT="$T/bin/warp.sh"
export Z2K_WARP_FLOW_CALLS="$T/calls"

# shellcheck disable=SC1090,SC1091
. "$REPO/files/z2k-update-lists.sh" || exit 1
z2k_fetch() {
    case "$1" in
        */sources.json) cp "$T/index.json" "$2"; return 0 ;;
        *) return 1 ;;
    esac
}
update_list() {
    printf '1.2.3.0/24\n' > "$3"
    return 2
}
log_msg() { printf '%s\n' "$*" >> "$LOG_FILE"; }

update_warp_game_list >/dev/null 2>&1
assert_eq "OpenWrt gaming refresh succeeds" "0" "$?"
assert_contains "game list materialized under OpenWrt root" "$T/root/lists/warp/games/Steam.txt" '1.2.3.0/24'
if [ ! -e "$T/root/lists/warp/games/Other_Games.txt" ]; then
    _t_ok
else
    _t_bad "catch-all game is never materialized"
fi
assert_contains "enabled state is read from canonical OpenWrt config" "$T/calls" 'ipset'

_t_done
