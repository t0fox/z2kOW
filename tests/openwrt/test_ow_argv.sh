#!/bin/sh
# tests/openwrt/test_ow_argv.sh - Step 8/9: полный argv демона из двух половин.
# OPT_BASE (optbase.sh) + NFQWS2_OPT (сгенерированный конфиг): доказывает, что
# демон стартует с z2k lua/blobs и что --qnum совпадает с конфигом firewall.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-argv"
ow_fixture_init || { echo "FAIL[ow-argv]: fixture" >&2; exit 1; }
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
. "$AD/optbase.sh"

z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 || exit 1
z2k_ow_bootstrap >/dev/null 2>&1 || exit 1
z2k_ow_generate >/dev/null 2>&1 || exit 1
# shellcheck disable=SC1090
. "$Z2K_CONFIG" || exit 1

BASE="$(z2k_ow_optbase)" || { echo "FAIL[ow-argv]: optbase" >&2; exit 1; }
FULL="--qnum=${QNUM:-200} $BASE $NFQWS2_OPT"

# --- OPT_BASE: z2k-начинка ---
echo "$BASE" | grep -q -- '--bind-fix4 --bind-fix6' && _t_ok || _t_bad "нет bind-fix"
echo "$BASE" | grep -q -- '--ipcache-hostname=1' && _t_ok || _t_bad "нет ipcache-hostname"
echo "$BASE" | grep -q -- '--user=nobody' && _t_ok || _t_bad "нет --user"
echo "$BASE" | grep -q -- '--fwmark=0x40000000' && _t_ok || _t_bad "нет fwmark"
for _lua in z2k-alert z2k-quic-silence z2k-tcp16 z2k-fooling-ext \
            z2k-range-rand z2k-modern-core z2k-state-persist; do
    echo "$BASE" | grep -qF -- "--lua-init=@$T/root/lua/$_lua.lua" \
        && _t_ok || _t_bad "нет lua-init $_lua"
done
echo "$BASE" | grep -q -- '--blob=quic_google:@' && _t_ok || _t_bad "нет blob quic_google"
echo "$BASE" | grep -q -- '--blob=tls_max_ru:@' && _t_ok || _t_bad "нет blob tls_max_ru"

# --- связи: qnum демона = qnum конфига (firewall строит очередь с тем же номером) ---
assert_eq "qnum консистентен" "$QNUM" "200"
echo "$FULL" | grep -q -- '--qnum=200' && _t_ok || _t_bad "argv без --qnum=200"

# --- каждый payload --lua-init указывает на существующий файл ---
# (fork-lua из zapret2 runtime в фикстуре нет — это зависимость пакета,
#  bootstrap о ней предупреждает; здесь сверяем только форму пути).
echo "$FULL" | grep -oE -- '--lua-init=@[^ ]+' | sed 's/^--lua-init=@//' >"$T/luainits"
_n=0; _miss=""; _fork=0; _z2k=0
while IFS= read -r _f; do
    _n=$((_n + 1))
    case "$_f" in
        "$T"/root/lua/*) _z2k=$((_z2k + 1)); [ -f "$_f" ] || _miss="$_miss $_f" ;;
        *) _fork=$((_fork + 1)); echo "$_f" | grep -q "^$Z2K_ZAPRET2_RUNTIME/lua/zapret-" \
               || _miss="$_miss(fork-path) $_f" ;;
    esac
done <"$T/luainits"
# fork: lib+antidpi безусловно (как S99), auto — только при наличии файла
assert_eq "fork lua-init: lib+antidpi" "2" "$_fork"
assert_eq "z2k lua-init: все 7" "7" "$_z2k"
[ -z "$_miss" ] && _t_ok || _t_bad "lua-init в никуда:$_miss"

_t_done
