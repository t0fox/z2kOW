#!/bin/sh
# tests/openwrt/test_ow_materialize.sh - Step 9a: цепочка манифесты -> Strategy.txt
# на РЕАЛЬНОМ upstream-конвейере (generate_*_conf + create_default_strategy_files).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-materialize"
ow_fixture_init || { echo "FAIL[ow-materialize]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" || { echo "FAIL[ow-materialize]: utils.sh" >&2; exit 1; }
. "$Z2K_LIB/strategies.sh" || { echo "FAIL[ow-materialize]: strategies.sh" >&2; exit 1; }
. "$AD/materialize.sh"

z2k_ow_materialize "$Z2K_MANIFESTS_DIR" >/dev/null 2>&1 \
    || { echo "FAIL[ow-materialize]: materialize rc!=0" >&2; exit 1; }
_t_ok  # materialize отработал

assert_file "strategies.conf" "$Z2K_CONF_DIR/strategies.conf"
assert_file "quic_strategies.conf" "$Z2K_CONF_DIR/quic_strategies.conf"
for _p in TCP/YT TCP/YT_GV TCP/RKN UDP/YT; do
    assert_file "Strategy $_p" "$Z2K_EXTRA_STRATS_DIR/$_p/Strategy.txt"
done

# боевые пулы, а не заглушки: ротация и десинхронизация на месте
assert_contains "rkn rotator" "$Z2K_EXTRA_STRATS_DIR/TCP/RKN/Strategy.txt" "circular"
assert_contains "rkn desync" "$Z2K_EXTRA_STRATS_DIR/TCP/RKN/Strategy.txt" "lua-desync"
assert_contains "yt desync" "$Z2K_EXTRA_STRATS_DIR/TCP/YT/Strategy.txt" "lua-desync"
assert_contains "quic rotator" "$Z2K_EXTRA_STRATS_DIR/UDP/YT/Strategy.txt" "circular"

# манифест trio (RKN=1, YT=2, GV=3): все три пула разрешились
_n=$(grep -c '^[0-9]*|' "$Z2K_CONF_DIR/strategies.conf")
[ "$_n" -eq 3 ] && _t_ok || _t_bad "strategies.conf: ожидалось 3 пула, получено $_n"
for _pool in 1 2 3; do
    [ -n "$(get_strategy "$_pool" 2>/dev/null)" ] && _t_ok || _t_bad "пул #$_pool не разрешается"
done

_t_done
