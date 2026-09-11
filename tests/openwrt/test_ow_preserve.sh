#!/bin/sh
# tests/openwrt/test_ow_preserve.sh - §5: пользовательское не перетирается.
#   bootstrap дважды: второй прогон не трогает config/state/user-lists;
#   generate сохраняет пользовательские флаги (saved_*-механика генератора).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-preserve"
ow_fixture_init || { echo "FAIL[ow-preserve]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" >/dev/null 2>&1 || exit 1
. "$Z2K_LIB/strategies.sh" >/dev/null 2>&1 || exit 1
. "$Z2K_LIB/config_official.sh" >/dev/null 2>&1 || exit 1
. "$AD/materialize.sh"
. "$AD/bootstrap.sh"
. "$AD/generate.sh"

z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 || exit 1
z2k_ow_bootstrap >/dev/null 2>&1 || exit 1

# пользователь меняет config и кладёт своё в state/user-lists
printf '\nZ2K_DYNAMIC_TTL=0\n' >>"$Z2K_CONFIG"
echo "my whitelisted domain" >"$Z2K_USER_LISTS/whitelist.txt"
echo "custom state" >"$Z2K_STATE/discovered-domains.txt"
_sum_cfg="$(cksum "$Z2K_CONFIG")"
_sum_wl="$(cksum "$Z2K_USER_LISTS/whitelist.txt")"
_sum_st="$(cksum "$Z2K_STATE/discovered-domains.txt")"

# повторный bootstrap (upgrade/reboot) — руки прочь от пользовательского
z2k_ow_bootstrap >/dev/null 2>&1 || { echo "FAIL[ow-preserve]: re-bootstrap" >&2; exit 1; }
assert_eq "config не перезаписан" "$_sum_cfg" "$(cksum "$Z2K_CONFIG")"
assert_eq "whitelist цел" "$_sum_wl" "$(cksum "$Z2K_USER_LISTS/whitelist.txt")"
assert_eq "state цел" "$_sum_st" "$(cksum "$Z2K_STATE/discovered-domains.txt")"

# generate сохраняет флаг (saved_Z2K_DYNAMIC_TTL) и не трогает чужие файлы
z2k_ow_generate >/dev/null 2>&1 || { echo "FAIL[ow-preserve]: generate" >&2; exit 1; }
assert_contains "флаг пережил генерацию" "$Z2K_CONFIG" "Z2K_DYNAMIC_TTL=0"
assert_eq "whitelist цел после generate" "$_sum_wl" "$(cksum "$Z2K_USER_LISTS/whitelist.txt")"
assert_eq "state цел после generate" "$_sum_st" "$(cksum "$Z2K_STATE/discovered-domains.txt")"

# init/hotplug — package-owned код БЕЗ conffiles: при upgrade пакет их
# заменяет (менеджеру нечего сохранять); user-config пакет не поставляет
# вовсе — ему нечего сохранять/затирать: ни одного $(1)/etc/z2k в install.
# Проверяем STANZA (слово conffiles живёт в комментарии-обосновании).
if grep -q 'define Package/z2k-adapter/conffiles' "$REPO/package/openwrt/Makefile"; then
    _t_bad "conffiles present (init/hotplug обновляются с пакетом)"
else
    _t_ok
fi
# а /etc/z2k/* пакет НЕ поставляет (ему нечего сохранять/затирать): ни одного
# упоминания $(1)/etc/z2k в install-цели
if grep -A30 'define Package/z2k-adapter/install' "$REPO/package/openwrt/Makefile" \
    | grep -q '$(1)/etc/z2k'; then
    _t_bad "пакет ставит файлы в /etc/z2k (должен только bootstrap)"
else
    _t_ok
fi

_t_done
