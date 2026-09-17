#!/bin/sh
# Generated-config convergence: unchanged starts reuse the published artifact;
# semantic input changes force one atomic regeneration and backup pruning stays
# bounded.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-config-convergence"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-cfgconv.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root/lib" "$T/root/extra_strats/TCP/RKN" "$T/root/lists" \
         "$T/etc/state" "$T/etc/conf" "$T/tmp"
printf '%s\n' '# generator input' > "$T/root/lib/config_official.sh"
printf '%s\n' '# strategy input' > "$T/root/lib/strategies.sh"
printf '%s\n' '# utility input' > "$T/root/lib/utils.sh"
printf '%s\n' 'strategy=1' > "$T/root/strats_new2.txt"
printf '%s\n' 'strategy=1' > "$T/root/extra_strats/TCP/RKN/Strategy.txt"
printf '%s\n' 'ENABLED=1' 'GAME_WARP_ENABLED=0' > "$T/etc/config"
ln -s "$T/etc/config" "$T/root/config"

export Z2K_ROOT="$T/root" Z2K_LIB="$T/root/lib" Z2K_ETC="$T/etc"
export Z2K_CONFIG="$T/etc/config" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp"
export Z2K_CONF_DIR="$T/etc/conf" Z2K_EXTRA_STRATS_DIR="$T/root/extra_strats"
export Z2K_LISTS_DIR="$T/root/lists" Z2K_USER_LISTS="$T/etc/user-lists"
export Z2K_CONFIG_GENERATION_MARKER="$T/etc/state/config.generation"
export Z2K_AU_DIRTY_TREE_FILE="$T/etc/state/dirty-tree"
mkdir -p "$Z2K_USER_LISTS"

create_official_config() {
    _cfg="$1"
    _n=$(cat "$T/generations" 2>/dev/null || echo 0)
    _n=$((_n + 1)); printf '%s\n' "$_n" > "$T/generations"
    printf 'ENABLED=%s\nGAME_WARP_ENABLED=%s\n' \
        "$(sed -n 's/^ENABLED=//p' "$_cfg" | head -1)" \
        "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$_cfg" | head -1)" > "$_cfg.new"
    printf 'NFQWS2_OPT="\n--filter-tcp=443 --lua-desync=fake\n"\n' >> "$_cfg.new"
    mv -f "$_cfg.new" "$_cfg"
}
. "$REPO/platform/openwrt/generate.sh" || exit 1

z2k_ow_generate >/dev/null 2>&1 || _t_bad "initial generation rc"
assert_eq "initially generated once" "1" "$(cat "$T/generations")"
_cfg_hash=$(sha256sum "$Z2K_CONFIG" | awk '{print $1}')
z2k_ow_generate >/dev/null 2>&1 || _t_bad "unchanged convergence rc"
assert_eq "unchanged skips generator" "1" "$(cat "$T/generations")"
assert_eq "unchanged config bytes" "$_cfg_hash" "$(sha256sum "$Z2K_CONFIG" | awk '{print $1}')"

printf '%s\n' 'ENABLED=1' 'GAME_WARP_ENABLED=1' > "$T/etc/config.new"
sed -n '/^NFQWS2_OPT="/,$p' "$Z2K_CONFIG" >> "$T/etc/config.new"
mv -f "$T/etc/config.new" "$Z2K_CONFIG"
z2k_ow_generate >/dev/null 2>&1 || _t_bad "dirty generation rc"
assert_eq "semantic change regenerates" "2" "$(cat "$T/generations")"

for _i in 1 2 3 4 5; do
    : > "$Z2K_CONFIG.backup.20260917_00000$_i"
done
Z2K_CONFIG_BACKUP_KEEP=3 z2k_ow_config_backup_prune
assert_eq "backup retention bounded" "3" "$(find "$Z2K_ETC" -maxdepth 1 -name 'config.backup.*' | wc -l | tr -d ' ')"

_t_done
