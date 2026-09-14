#!/bin/sh
# tests/test_quic_strats_delivery.sh — правка QUIC-плеч доезжает патчем.
#
# ЧТО БЫЛО. quic_strats.ini не значился в карте доставки вовсе: изменение
# QUIC-плеч на роутер патчем не приезжало. Чинилось это только полной
# переустановкой, а она случается далеко не каждый выпуск — то есть правка
# могла молча пролежать в репозитории неделями, и никто бы не заметил: версия
# на роутере новая, плечи QUIC старые.
#
# Вторая половина той же дыры: quic_strategies.conf собирается из
# quic_strats.ini, а читает его create_default_strategy_files. Шаг пересборки
# стратегий трогал только TCP-манифест, поэтому даже доставленный ini не
# менял ничего — ровно тот случай, что уже ловили на TCP в r-84.1.
# POSIX sh.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

# shellcheck disable=SC1091
. "$ROOT/lib/release_map.sh" 2>/dev/null || { printf '[FAIL] нет lib/release_map.sh\n'; exit 1; }

# --- 1. адрес доставки есть -------------------------------------------------
_dst=$(ZAPRET2_DIR=/opt/zapret2 z2k_install_paths quic_strats.ini 2>/dev/null)
case "$_dst" in
    */quic_strats.ini) ok "quic_strats.ini доставляется в $_dst" ;;
    '') no "quic_strats.ini есть в карте доставки" "путь" "пусто — патчем не приедет" ;;
    *)  no "quic_strats.ini доставляется в дерево z2k" "*/quic_strats.ini" "$_dst" ;;
esac

# Файл в репозитории и правда есть — иначе проверка выше стережёт пустоту.
[ -s "$ROOT/quic_strats.ini" ] \
    && ok "quic_strats.ini лежит в репозитории" \
    || no "quic_strats.ini в репозитории" "непустой файл" "нет"

# --- 2. последствия объявлены -----------------------------------------------
_steps=$(z2k_steps_for quic_strats.ini 2>/dev/null | tr '\n' ' ')
case "$_steps" in
    *regen-strategies*) ok "правка QUIC объявляет пересборку стратегий" ;;
    *) no "правка QUIC объявляет regen-strategies" "regen-strategies" "${_steps:-ничего}" ;;
esac
case "$_steps" in
    *restart-service*) ok "правка QUIC объявляет перезапуск" ;;
    *) no "правка QUIC объявляет restart-service" "restart-service" "${_steps:-ничего}" ;;
esac

# --- 3. шаг пересборки действительно трогает QUIC ----------------------------
# Иначе доставленный ini ничего не изменит: плечи материализуются из
# quic_strategies.conf, а его никто не пересоберёт.
_fn=$(awk '/^au_step_regen_strategies\(\) \{/,/^\}/' "$ROOT/lib/auto_update.sh")
case "$_fn" in
    *generate_quic_strategies_conf*) ok "шаг пересборки собирает quic_strategies.conf" ;;
    *) no "шаг пересборки трогает QUIC" "вызов generate_quic_strategies_conf" "его нет" ;;
esac
case "$_fn" in
    *quic_strats.ini*) ok "шаг пересборки читает quic_strats.ini" ;;
    *) no "шаг читает quic_strats.ini" "есть" "нет" ;;
esac

# Порядок: QUIC собирается ДО create_default_strategy_files, который его читает.
_quic_at=$(printf '%s\n' "$_fn" | grep -n 'generate_quic_strategies_conf' | head -1 | cut -d: -f1)
_defaults_at=$(printf '%s\n' "$_fn" | grep -n 'create_default_strategy_files' | tail -1 | cut -d: -f1)
if [ -n "$_quic_at" ] && [ -n "$_defaults_at" ] && [ "$_quic_at" -lt "$_defaults_at" ]; then
    ok "QUIC собирается раньше, чем его читают"
else
    no "порядок внутри шага" "quic раньше create_default_strategy_files" \
       "quic=${_quic_at:-нет} defaults=${_defaults_at:-нет}"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
