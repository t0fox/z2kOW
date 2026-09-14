#!/bin/sh
# tests/openwrt/test_ow_quic_regen.sh - §9C: QUIC source change -> delivery -> regen.
# Доказывает p-84.16-семантику на OW-конвейере: правка quic_strats.ini
# реально меняет generated quic_strategies.conf (а не лежит мёртвой до полной
# переустановки, как до p-84.16), и change classification зовёт правильный
# regen с restart (consequences в release_map).
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-quic-regen"
ow_fixture_init || { echo "FAIL[ow-quic-regen]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
# shellcheck disable=SC1090,SC1091
. "$Z2K_LIB/utils.sh" || { echo "FAIL[ow-quic-regen]: utils.sh" >&2; exit 1; }
. "$Z2K_LIB/strategies.sh" || { echo "FAIL[ow-quic-regen]: strategies.sh" >&2; exit 1; }
. "$AD/materialize.sh"
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" || { echo "FAIL[ow-quic-regen]: release_map" >&2; exit 1; }

# 1. ini входит в delivery map (адрес под openwrt-корнем).
if [ -n "$(Z2K_PLATFORM=openwrt z2k_install_paths quic_strats.ini 2>/dev/null)" ]; then _t_ok
else _t_bad "quic_strats.ini без openwrt-назначения (не доставляется)"; fi

# 2. consequences: regen-strategies + restart-service (не молча, не partial).
_steps="$(z2k_steps_for quic_strats.ini 2>/dev/null)"
for _s in regen-strategies regen-config restart-service; do
    if printf '%s\n' "$_steps" | grep -qxF "$_s"; then _t_ok
    else _t_bad "нет consequence $_s для quic_strats.ini"; fi
done

# 3. change -> regen proof: мутация ini меняет generated conf.
M="$T/manifests"; mkdir -p "$M" || exit 1
cp -f "$REPO/quic_strats.ini" "$M/quic_strats.ini" || exit 1
cp -f "$REPO/strats_new2.txt" "$M/strats_new2.txt" || exit 1
z2k_ow_materialize "$M" >/dev/null 2>&1 || { echo "FAIL[ow-quic-regen]: materialize#1" >&2; exit 1; }
_before="$(cksum "$CONFIG_DIR/quic_strategies.conf" 2>/dev/null)"
# Маркер, которого нет в текущем ini (доказательство: grep по дереву).
if grep -q "Z2K_QUIC_REGEN_PROBE_77" "$REPO/quic_strats.ini" 2>/dev/null; then
    _t_bad "маркер уже в ini (тест невалиден)"
else
    _t_ok
fi
# Мутация: repeats=11 -> repeats=77 в yt_quic-плече (первое вхождение).
sed -i 's/repeats=11/repeats=77/' "$M/quic_strats.ini" 2>/dev/null || \
    { echo "FAIL[ow-quic-regen]: sed" >&2; exit 1; }
grep -q "repeats=77" "$M/quic_strats.ini" || { echo "FAIL[ow-quic-regen]: мутация не встала" >&2; exit 1; }
z2k_ow_materialize "$M" >/dev/null 2>&1 || { echo "FAIL[ow-quic-regen]: materialize#2" >&2; exit 1; }
_after="$(cksum "$CONFIG_DIR/quic_strategies.conf" 2>/dev/null)"
if [ -n "$_before" ] && [ "$_before" != "$_after" ]; then _t_ok
else _t_bad "quic_strategies.conf не изменился после правки ini (p-84.16 дыра)"; fi
if grep -q "repeats=77" "$CONFIG_DIR/quic_strategies.conf" 2>/dev/null; then _t_ok
else _t_bad "мутация не доехала в generated conf"; fi
if grep -q "repeats=77" "$Z2K_EXTRA_STRATS_DIR/UDP/YT/Strategy.txt" 2>/dev/null; then _t_ok
else _t_bad "мутация не доехала в UDP/YT/Strategy.txt"; fi

_t_done
