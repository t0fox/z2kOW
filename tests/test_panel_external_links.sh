#!/bin/sh
# tests/test_panel_external_links.sh — ссылки наружу в боковом меню (issue #59).
#
# Панель открывается на роутере без интернета: шрифты, значки и скрипты лежат на
# нём же, наружу она не ходит НИ ОДНИМ запросом. Ссылка этого не нарушает —
# переход делает человек, — но соблазн «взять значок бренда с CDN» появляется
# ровно здесь, поэтому запрет проверяется тестом, а не памятью.
#
# Что охраняется:
#   * обе ссылки на месте и ведут туда же, куда README (расхождение адресов
#     заметно только тому, кто кликнул);
#   * открываются новой вкладкой и с rel=noopener — без него открытая страница
#     получает доступ к window.opener панели;
#   * подвал стоит ВЫШЕ кнопки свёртывания: иначе «Свернуть» перестаёт быть
#     последней строкой, к которой привыкли;
#   * ни одного внешнего файла в разметке (значки, шрифты, скрипты).
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
H="$HERE/webpanel/www/index.html"
C="$HERE/webpanel/www/style.css"
R="$HERE/README.md"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

for f in "$H" "$C" "$R"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

GH="https://github.com/necronicle/z2k"
TG="https://t.me/zapret2keenetic"

eq "ссылка на исходники в разметке" "1" "$(grep -c "href=\"$GH\"" "$H")"
eq "ссылка на чат в разметке"       "1" "$(grep -c "href=\"$TG\"" "$H")"

# Тот же адрес, что в README. Два места — два шанса разойтись.
eq "адрес чата совпадает с README" "yes" \
    "$(grep -q "$TG" "$R" && echo yes || echo no)"
eq "адрес репозитория совпадает с README" "yes" \
    "$(grep -q "necronicle/z2k" "$R" && echo yes || echo no)"

# Новая вкладка + noopener у КАЖДОЙ внешней ссылки.
_ext=$(grep -c 'href="https://' "$H")
_safe=$(grep 'href="https://' "$H" | grep -c 'target="_blank" rel="noopener noreferrer"')
eq "все внешние ссылки открываются новой вкладкой с noopener" "$_ext" "$_safe"

# Подвал — внутри меню и ВЫШЕ кнопки свёртывания.
_nav_open=$(grep -n '<nav id="nav"' "$H" | head -1 | cut -d: -f1)
_nav_close=$(grep -n '</nav>' "$H" | head -1 | cut -d: -f1)
_ext_ln=$(grep -n 'class="nav-external"' "$H" | head -1 | cut -d: -f1)
_col_ln=$(grep -n 'class="sidebar-collapse"' "$H" | head -1 | cut -d: -f1)
if [ -n "$_ext_ln" ] && [ -n "$_col_ln" ] && [ -n "$_nav_open" ] && [ -n "$_nav_close" ]; then
    [ "$_ext_ln" -gt "$_nav_open" ] && [ "$_ext_ln" -lt "$_nav_close" ] \
        && ok "подвал ссылок внутри бокового меню" \
        || no "подвал внутри меню" "между $_nav_open и $_nav_close" "$_ext_ln"
    [ "$_ext_ln" -lt "$_col_ln" ] \
        && ok "«Свернуть» осталась последней строкой меню" \
        || no "порядок подвала" "ссылки выше кнопки" "$_ext_ln/$_col_ln"
else
    no "подвал и кнопка найдены" "обе строки" "ext=$_ext_ln collapse=$_col_ln"
fi

# Прижат книзу: auto-отступ переехал с кнопки на подвал, иначе подвал встанет
# сразу под пунктами меню, а кнопка — в самый низ, и линия разделит не то.
eq "подвал прижат книзу" "1" \
    "$(awk '/^#nav \.nav-external \{/,/^\}/' "$C" | grep -c 'margin-top: auto;')"
eq "auto-отступ снят с кнопки свёртывания" "0" \
    "$(awk '/^#nav \.sidebar-collapse \{/,/\}/' "$C" | grep -c 'margin-top: auto')"

# В свёрнутом меню строка — один значок: стрелка «новая вкладка» прячется.
eq "в свёрнутом меню стрелка скрыта" "1" \
    "$(grep -c 'body\[data-sidebar="collapsed"\] #nav .nav-out { display: none; }' "$C")"

# НИ ОДНОГО внешнего файла: значки, шрифты и скрипты — только свои.
_remote=$(grep -oE '(src|href)="https?://[^"]+"' "$H" \
    | grep -vE "^href=\"$GH\"$|^href=\"$TG\"$" | head -5)
if [ -z "$_remote" ]; then
    ok "панель не тянет наружу ни одного файла"
else
    no "внешних файлов нет" "только ссылки" "$(printf '%s' "$_remote" | tr '\n' ' ')"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
