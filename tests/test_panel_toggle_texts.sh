#!/bin/sh
# tests/test_panel_toggle_texts.sh — подписи к режимам в панели говорят правду.
#
# ЗАЧЕМ. Люди сравнивали панель с README и говорили, что в README понятнее. При
# разборе выяснилось, что дело не в ясности: подпись к «Динамическому TTL»
# утверждала прямо противоположное устройству опции —
#
#   «инжекция ФИКСИРОВАННОГО TTL … обход обнаружения tethering»
#
# тогда как значение как раз ДИНАМИЧЕСКОЕ (в этом весь смысл), а раздача
# мобильного интернета — единственная причина опцию ВЫКЛЮЧИТЬ, а не её
# назначение. Подпись в панели читают чаще, чем README.
#
# POSIX sh.
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T="$ROOT/webpanel/www/js/pages/toggles.js"
CSS="$ROOT/webpanel/www/style.css"
[ -f "$T" ] || { printf '[FAIL] нет %s\n' "$T"; exit 1; }
[ -f "$CSS" ] || { printf '[FAIL] нет %s\n' "$CSS"; exit 1; }

# Подпись к динамическому TTL: берём строку описания целиком.
D=$(awk '/key: "dynamic_ttl"/{f=1} f{print} f&&/\},$/{exit}' "$T")

assert_eq "не называет значение фиксированным" "0" "$(printf '%s' "$D" | grep -ci 'фиксированн')"
assert_eq "не выдаёт раздачу за назначение"    "0" "$(printf '%s' "$D" | grep -ci 'обход обнаружения')"
if printf '%s' "$D" | grep -q 'подгоняет счётчик под настоящий'; then
    ok "объясняет, что делает опция"
else
    no "объясняет, что делает опция" "суть" "нет"
fi
if printf '%s' "$D" | grep -q 'Выключайте в одном случае'; then
    ok "раздача названа причиной ВЫКЛЮЧИТЬ"
else
    no "раздача названа причиной выключить" "оговорка" "нет"
fi
# Без англицизма: человек в панели не обязан знать слово tethering.
assert_eq "без слова tethering" "0" "$(printf '%s' "$D" | grep -ci 'tethering')"

# OpenWrt Selective FLOWOFFLOAD: человекочитаемый блок не должен возвращаться
# к сырому техническому представлению. Технические поля остаются в disclosure,
# поэтому проверяем одновременно пользовательские подписи и сохранённые факты.
if grep -q '<h3>Ускорение трафика</h3>' "$T" &&
   grep -q '<p class="desc">Управление ускорением соединений через zapret2</p>' "$T"; then
    ok "FLOWOFFLOAD имеет пользовательский заголовок и короткое описание"
else
    no "FLOWOFFLOAD имеет пользовательский заголовок и короткое описание" "новый текст" "нет"
fi
for label in "Выключено" "Программное ускорение" "Аппаратное ускорение"; do
    if grep -q "\"$label\"" "$T"; then
        ok "режим подписан: $label"
    else
        no "режим подписан: $label" "есть" "нет"
    fi
done
if grep -q 'Техническая диагностика' "$T" &&
   grep -q 'Диагностика обработки трафика' "$T" &&
   grep -q 'packet_visibility' "$T" && grep -q 'circular' "$T"; then
    ok "технические поля и диагностика обработки трафика вынесены в disclosure"
else
    no "технические поля и диагностика обработки трафика вынесены в disclosure" "есть" "нет"
fi
if grep -q 'state.textContent = s.toggles.flowoffload_status' "$T"; then
    no "raw FLOWOFFLOAD не назначается основному статусу" "структурированный статус" "raw string"
else
    ok "raw FLOWOFFLOAD не назначается основному статусу"
fi
if grep -q '\.flow-facts {' "$CSS" &&
   grep -q 'grid-template-columns: 1fr;' "$CSS" &&
   grep -q '\.flow-mode-field { max-width: none; }' "$CSS"; then
    ok "FLOWOFFLOAD сохраняет компактную раскладку на узком экране"
else
    no "FLOWOFFLOAD сохраняет компактную раскладку на узком экране" "адаптивные правила" "нет"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
