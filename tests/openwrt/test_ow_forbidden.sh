#!/bin/sh
# tests/openwrt/test_ow_forbidden.sh - Step 14: Keenetic-зависимостям нет места.
# Запрещены в platform/ + package/ + tests/openwrt/ (в docs/fixtures — можно):
# ndmc, /opt/etc/ndm, kmod_ndms, Entware-инит, Keenetic-PPE, S99/keenetic в коде.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-forbidden"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# NOTE: сам guard-файл исключён из скана — он содержит эти строки как образцы.
_hits="$(grep -rEin 'ndmc|/opt/etc/ndm|kmod_ndms|entware|-j PPE|ipset-exclude.*PPE' \
    "$REPO/platform/openwrt" "$REPO/package/openwrt" "$REPO/tests/openwrt" \
    | grep -v 'test_ow_forbidden\.sh' || true)"
[ -z "$_hits" ] && _t_ok || _t_bad "Keenetic-зависимости: $_hits"

# S99/keenetic/baggage — только в комментариях (атрибуция), не в коде.
# Список багажа: Keenetic-инит, PPE-правила, вотчдоги, tcp16-probe,
# ndm, /opt-пути. Имена z2k-warp ЛЕГИТИМНЫ с Stage 5 (слой приземлился:
# platform/openwrt/warp{,-proc,-check}.sh + проводка; контракт в docs/).
# TG/HTTP-tunnel убраны в Stage 3, RT — в Stage 4, WARP — в Stage 5
# (приземлились: platform/openwrt/{tg,rt,warp}.sh + проводка; контракты
# в docs/).
# Границы токенов — чтобы не ловить SHIPPED/tcp16_asn
# (легитимный lua-state plumbing ядра).
_bad=""
for _f in "$REPO"/platform/openwrt/*.sh \
          "$REPO"/package/openwrt/files/etc/init.d/z2k \
          "$REPO"/package/openwrt/files/etc/hotplug.d/iface/90-z2k; do
    # Исключение: дефолт Z2K_ZAPRET2_RUNTIME=/opt/zapret2 — canonical base
    # самого zapret2 (совпадает с его ZAPRET_BASE-дефолтом), не Keenetic-
    # предположение; переопределяется окружением. Всё остальное /opt/* — баг.
    _h="$(sed 's/#.*$//' "$_f" | grep -v 'Z2K_ZAPRET2_RUNTIME.*:-/opt/zapret2' \
        | grep -inE 'keenetic|S99|(^|[^a-zA-Z])PPE([^a-zA-Z]|$)|watchdog|tcp16-probe|Entware|/opt/|(^|[^a-zA-Z_])ndm([^a-zA-Z_]|$)' || true)"
    [ -n "$_h" ] && _bad="$_bad $(basename "$_f"):$_h"
done
[ -z "$_bad" ] && _t_ok || _t_bad "багаж в коде:$_bad"

# rm -rf по возможно-пустой переменной = rm -rf / (чуть не снесло /usr в WSL:
# $T без определения в lc_reseed-тесте). Каждая переменная в rm -rf обязана
# присваиваться в том же файле (mktemp/export/param) либо приходить из
# harness (LC_*, доказывается вызовом lc_init), иначе — провал guard.
# assert_contains-строки пропускаем: они цитируют чужой код как данные.
_rmbad=""
for _tf in "$REPO"/tests/openwrt/test_ow_*.sh "$REPO"/tests/openwrt/lc_harness.sh; do
    for _rv in $(grep -v 'assert_contains' "$_tf" 2>/dev/null | grep -oE 'rm -rf "?\$[A-Za-z_][A-Za-z0-9_]*' | grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' | sort -u); do
        _rn=${_rv#\$}
        case "$_rn" in
            LC_T|LC_SYS|LC_ORIGIN|LC_BIN|LC_REPO|LC_SEED_TARBALL) continue ;;
        esac
        if ! grep -qE "(^|[ ;])${_rn}=[^=]|export ${_rn}[ =]" "$_tf" 2>/dev/null; then
            _rmbad="$_rmbad $(basename "$_tf"):$_rn"
        fi
    done
done
[ -z "$_rmbad" ] && _t_ok || _t_bad "rm -rf по неприсвоенной переменной:$_rmbad"

_t_done
