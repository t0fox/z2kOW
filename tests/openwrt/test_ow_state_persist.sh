#!/bin/sh
# tests/openwrt/test_ow_state_persist.sh - §9D: strategy persistence на OW-путях.
# p-84.17: подобранная/закреплённая стратегия переживает regen/restart/reload.
# Перевод путей: lua primary = $Z2K_STATE/state.tsv (persistent /etc/z2k/state),
# lua fallback = $Z2K_TMP/z2k-autocircular-state.tsv, shell STATE_FILE — тот же
# файл, reset-state чистит оба через Z2K_AU_STATE_FALLBACK-hook.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-state-persist"
ow_fixture_init || { echo "FAIL[ow-state-persist]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" || { echo "FAIL[ow-state-persist]: utils" >&2; exit 1; }
. "$Z2K_LIB/strategies.sh" || { echo "FAIL[ow-state-persist]: strategies" >&2; exit 1; }
. "$AD/materialize.sh"
. "$REPO/lib/auto_update.sh" || { echo "FAIL[ow-state-persist]: au" >&2; exit 1; }

LUA="$REPO/files/lua/z2k-state-persist.lua"

# 1. seed везёт persist-слой (иначе нечего сохранять).
_seed_list="$(sh "$REPO/package/openwrt/make-seed.sh" --list "$REPO" 2>/dev/null)"
if printf '%s\n' "$_seed_list" | grep -qF "files/lua/z2k-state-persist.lua" \
    && printf '%s\n' "$_seed_list" | grep -qF "/usr/lib/z2k/lua/z2k-state-persist.lua"; then _t_ok
else _t_bad "seed не везёт files/lua/z2k-state-persist.lua"; fi

# 2. lua и shell смотрят в один и тот же primary-файл.
assert_contains "lua primary override" "$LUA" 'Z2K_STATE_DIR_OVERRIDE'
assert_contains "lua fallback override" "$LUA" 'Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE'
assert_contains "lua primary file" "$LUA" 'state.tsv'
assert_eq "shell STATE_FILE == state dir + state.tsv" "$Z2K_STATE/state.tsv" "$STATE_FILE"
assert_eq "shell dir override == state dir" "$Z2K_STATE" "$Z2K_STATE_DIR_OVERRIDE"
assert_eq "shell fallback hook == tmp fallback file" \
    "$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv" "$Z2K_AU_STATE_FALLBACK"

# 3. state persistent: выводится из $Z2K_ETC, прод-дефолт — /etc/z2k/state.
assert_eq "Z2K_STATE derived from ETC" "$Z2K_ETC/state" "$Z2K_STATE"
_prod_state="$(env -i sh -c '. "$0/platform/openwrt/paths.sh" >/dev/null 2>&1; printf "%s" "$Z2K_STATE"' "$REPO" 2>/dev/null)"
assert_eq "prod Z2K_STATE" "/etc/z2k/state" "$_prod_state"

# 4. regen (materialize) НЕ трогает state: подобранное живёт через пересборку.
mkdir -p "$Z2K_STATE" || exit 1
printf 'rkn_tcp\texample.com\t7\t1700000000\tauto\n' > "$STATE_FILE"
_before="$(cksum "$STATE_FILE")"
z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 \
    || { echo "FAIL[ow-state-persist]: materialize" >&2; exit 1; }
assert_eq "regen не трогает state.tsv" "$_before" "$(cksum "$STATE_FILE")"

# 5. reset-state чистит primary И fallback (оба OW-пути), лишний мусор — нет.
mkdir -p "$Z2K_TMP" || exit 1
printf 'x\n' > "$Z2K_AU_STATE_FALLBACK"
printf 'keep\n' > "$Z2K_STATE/keep.txt"
ZAPRET2_DIR="$Z2K_ROOT" au_step_reset_state >/dev/null 2>&1
[ -e "$STATE_FILE" ] && _t_bad "reset-state не снял primary" || _t_ok
[ -e "$Z2K_AU_STATE_FALLBACK" ] && _t_bad "reset-state не снял fallback" || _t_ok
[ -f "$Z2K_STATE/keep.txt" ] && _t_ok || _t_bad "reset-state снёс чужое"

_t_done
