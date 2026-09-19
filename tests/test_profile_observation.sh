#!/bin/sh
# Generate real shipped pools in an isolated install tree, then inspect the
# effective per-instance filters and run their Lua verdicts without networking.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export ZAPRET2_DIR="$TMP/install"
mkdir -p "$ZAPRET2_DIR/lua" "$ZAPRET2_DIR/lists" "$ZAPRET2_DIR/extra_strats"
cp -R files/lists/extra_strats/TCP files/lists/extra_strats/UDP "$ZAPRET2_DIR/extra_strats/"
cp files/lua/*.lua "$ZAPRET2_DIR/lua/"
for spec in 'rkn RKN' 'yt YT' 'gv YT_GV'; do
    set -- "${spec% *}" "${spec#* }"
    awk -v prefix="manual_autocircular_$1 " 'index($0,prefix)==1 {sub(/^.* : nfqws2 /, ""); print; exit}' strats_new2.txt > "$ZAPRET2_DIR/extra_strats/TCP/$2/Strategy.txt"
done
awk '/^\[quic_autocircular\]/{active=1;next} active && /^args=/{sub(/^args=/,"--filter-udp=443 --filter-l7=quic ");print;exit}' quic_strats.ini > "$ZAPRET2_DIR/extra_strats/UDP/YT/Strategy.txt"
. ./lib/utils.sh
. ./lib/config_official.sh
for reset in 1 0; do
    printf 'ENABLED=1\nZ2K_CIRCULAR_RESET=%s\n' "$reset" > "$ZAPRET2_DIR/config"
    generate_nfqws2_opt_from_strategies > "$TMP/raw"
    awk -f tests/lib/nfqws2_flatten.awk "$TMP/raw" > "$TMP/flat-$reset"
done
printf 'ENABLED=1\nZ2K_DISCORD_UPDATE_TLS_TIMEOUT=0\n' > "$ZAPRET2_DIR/config"
generate_nfqws2_opt_from_strategies > "$TMP/raw"
awk -f tests/lib/nfqws2_flatten.awk "$TMP/raw" > "$TMP/timeout-off"
export Z2K_PROFILE_FIXTURE="$TMP/flat-1" Z2K_PROFILE_NO_RESET="$TMP/flat-0" Z2K_PROFILE_TIMEOUT_OFF="$TMP/timeout-off"
mkdir -p "$TMP/state" "$TMP/fallback"
export Z2K_STATE_DIR_OVERRIDE="$TMP/state" Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="$TMP/fallback"
"${LUA:-lua}" tests/test_profile_observation.lua
