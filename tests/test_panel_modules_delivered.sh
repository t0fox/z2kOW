#!/bin/sh
# tests/test_panel_modules_delivered.sh — добавленный модуль обязан доехать.
#
# ЗАЧЕМ. 2026-08-14 монолит app.js (4262 строки) разрезан на 21 модуль. Разрез
# сам по себе безопасен — линтер держит ссылки, — но опасна ДОСТАВКА: у
# raw.githubusercontent нет листинга каталога, поэтому z2k.sh качает файлы
# панели поимённым списком. Добавил модуль, не вписал строку — панель приедет
# без него, точка входа упадёт на первом же import, и человек увидит пустую
# страницу. Молча: в логе установки ничего не будет, все остальные файлы
# доехали.
#
# Ровно такой риск в соседнем месте уже принят осознанно и описан комментарием:
# список шрифтов тоже поимённый, и при расхождении «браузер молча откатится на
# системный шрифт». Для шрифта это косметика. Для модуля — мёртвая панель,
# поэтому здесь риск не принимается, а закрывается проверкой.
#
# ЧТО ОХРАНЯЕТСЯ:
#   1. Каждый модуль с диска есть в списке загрузки z2k.sh.
#   2. В списке нет лишнего — путей к модулям, которых больше не существует
#      (иначе загрузка будет спотыкаться о 404 при каждой установке).
#   3. Каталоги под модули создаются до загрузки, иначе запись в них не пройдёт.
#   4. Установщик копирует модули ДЕРЕВОМ и падает при недокомплекте, а не
#      мягко пропускает, как шрифты.
#
# POSIX sh.

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
Z2K="$ROOT/z2k.sh"
WPINST="$ROOT/webpanel/install.sh"
JSDIR="$ROOT/webpanel/www/js"

for f in "$Z2K" "$WPINST"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done
[ -d "$JSDIR" ] || { printf '[FAIL] нет каталога модулей %s\n' "$JSDIR"; exit 1; }

# --- 1. Каждый модуль с диска есть в списке загрузки --------------------------
_absent=""
_count=0
for _m in $(cd "$ROOT/webpanel" && find www/js -name '*.js' | sort); do
    _count=$((_count + 1))
    grep -q "[[:space:]]${_m}[[:space:]]*\\\\*\$" "$Z2K" || _absent="$_absent $_m"
done
if [ "$_count" -eq 0 ]; then
    no "модули найдены" ">0" "0 — каталог пуст"
elif [ -z "$_absent" ]; then
    ok "все $_count модулей вписаны в список загрузки z2k.sh"
else
    no "модули в списке загрузки" "все $_count" "не вписаны:$_absent — приедут не все, панель не откроется"
fi

# --- 2. В списке нет исчезнувших ----------------------------------------------
_ghost=""
for _m in $(grep -oE 'www/js/[A-Za-z0-9_/-]+\.js' "$Z2K" | sort -u); do
    [ -f "$ROOT/webpanel/$_m" ] || _ghost="$_ghost $_m"
done
if [ -z "$_ghost" ]; then
    ok "в списке загрузки нет путей к несуществующим модулям"
else
    no "список без призраков" "только существующие" "нет на диске:$_ghost — установка будет ловить 404"
fi

# --- 3. Каталоги создаются до загрузки ----------------------------------------
#
# Загрузчик пишет файл по пути; без каталога запись не пройдёт, и модуль молча
# не доедет — тот же исход, что и пропуск в списке.
# mkdir -p создаёт и родителей, поэтому каталог покрыт, если в списке есть он
# сам ИЛИ любой его потомок. Проверять буквальное совпадение — значит краснеть
# на верном коде.
_dirs=$(cd "$ROOT/webpanel" && find www/js -type d | sort)
_mk=$(grep -oE 'webpanel_dir/www/js[A-Za-z0-9_/-]*' "$Z2K" | sed 's|.*webpanel_dir/||' | sort -u)
_nodir=""
for _d in $_dirs; do
    _hit=0
    for _m in $_mk; do
        case "$_m" in "$_d"|"$_d"/*) _hit=1 ;; esac
    done
    [ "$_hit" = "1" ] || _nodir="$_nodir $_d"
done
if [ -z "$_nodir" ]; then
    ok "каталоги под модули создаются до загрузки"
else
    no "mkdir для каталогов модулей" "все" "нет для:$_nodir"
fi

# --- 4. Установщик копирует дерево и падает при недокомплекте -----------------
_code=$(grep -v '^[[:space:]]*#' "$WPINST")
if printf '%s' "$_code" | grep -q 'cp -R "\$SRC_DIR/www/js/\." "\$STAGE_WWW/js/"'; then
    ok "установщик копирует модули деревом, а не поимённо"
else
    no "копирование деревом" "cp -R www/js/." "поимённо — список разойдётся с деревом"
fi
if printf '%s' "$_code" | grep -q '_js_src.*-ne.*_js_dst\|_js_dst.*-ne.*_js_src'; then
    ok "недокомплект модулей обрывает установку, а не проходит мягко"
else
    no "пересчёт скопированного" "сравнение количеств" \
       "нет — частичная копия проедет молча, как шрифты, но панель умрёт"
fi

# --- 5. Недокомплект, ПРИЕХАВШИЙ уже неполным ---------------------------------
#
# Ревью 08-15 показало дыру, которую пункт 4 не закрывает. Пересчёт «исходных
# против скопированных» ловит порчу при копировании, но если из сети приехало
# 20 файлов из 21, обе стороны равны двадцати и проверка проходит. Панель при
# этом мертва: точка входа падает на первом же import, браузер рисует пустую
# страницу, а установка рапортует успех.
#
# Закрыто с двух концов, и оба конца проверяются здесь.

# Конец первый: загрузчик не считает модуль опциональным.
_dl=$(awk '/опциональный компонент/{print NR": "$0}' "$Z2K" | head -1)
if grep -q 'www/fonts/\*|www/favicon.svg' "$Z2K"; then
    ok "загрузчик отличает необязательное (шрифты, значок) от модулей"
else
    no "модуль обязателен при загрузке" "отдельная ветка для шрифтов и значка" \
       "отказ любого файла — предупреждение: недокачанный модуль проедет молча ($_dl)"
fi

# Конец второй: установщик сверяет граф импортов с диском.
if printf '%s' "$_code" | grep -q "sed -n 's/\^import .\* from"; then
    ok "установщик проверяет, что каждый импорт разрешается на диске"
else
    no "проверка графа импортов" "разбор import и проверка файла" \
       "нет — приехавший неполным комплект пройдёт: пересчёт src/dst против него бессилен"
fi

# Exercise the real menu action and bootstrap artifact downloader against an
# old /tmp cache. Network and the destructive install are the only boundaries.
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
WORK_DIR="$TMP/work"; GITHUB_RAW="https://fixture.invalid/repo"
mkdir -p "$WORK_DIR/webpanel/www/js/pages"
printf 'OLD_PANEL\n' > "$WORK_DIR/webpanel/www/js/pages/toggles.js"
extract() { awk -v n="$1" '$0 ~ "^"n"\\(\\)" {p=1} p {print} p && /^[})]$/ {exit}' "$2"; }
eval "$(extract menu_install_fresh "$ROOT/lib/menu.sh")"
eval "$(extract menu_install "$ROOT/lib/menu.sh")"
eval "$(extract download_init_script "$Z2K")"
print_info() { :; }; print_success() { :; }; print_warning() { :; }
eval "$(extract print_header "$ROOT/lib/utils.sh")"
clear_screen() { :; }; pause() { :; }
die() { exit 1; }
z2k_fetch_manifest_hashes() { :; }
download_modules() { :; }; source_modules() { :; }
download_strategies_source() { :; }; download_fake_blobs() { :; }
generate_strategies_database() { :; }
z2k_fetch() {
    local rel="${1#"$GITHUB_RAW/"}"
    if [ "$rel" = webpanel/www/js/pages/toggles.js ] && [ "${FAIL_FETCH:-0}" = 1 ]; then return 1; fi
    mkdir -p "$(dirname "$2")"
    if [ -f "$ROOT/$rel" ]; then cp "$ROOT/$rel" "$2"; else printf 'fixture\n' > "$2"; fi
}
run_full_install() { cp "$WORK_DIR/webpanel/www/js/pages/toggles.js" "$TMP/installed.js"; }
eval "$(extract is_zapret2_installed "$ROOT/lib/utils.sh")"
ZAPRET2_DIR="$TMP/installed"
mkdir -p "$ZAPRET2_DIR/nfq2"
touch "$ZAPRET2_DIR/nfq2/nfqws2"
chmod +x "$ZAPRET2_DIR/nfq2/nfqws2"
read_input() { answer=y; }
menu_install >/dev/null 2>&1
if cmp -s "$TMP/installed.js" "$ROOT/webpanel/www/js/pages/toggles.js"; then
    ok "menu reinstall replaces stale cached panel with fresh sources"
else
    no "menu reinstall uses fresh panel" "current toggles.js" "stale cache copied"
fi
printf 'KEEP_INSTALLED\n' > "$TMP/installed.js"
FAIL_FETCH=1
if menu_install_fresh >/dev/null 2>&1; then
    no "failed refresh aborts reinstall" "non-zero" "success"
else
    ok "failed refresh aborts reinstall"
fi
if grep -qx KEEP_INSTALLED "$TMP/installed.js"; then
    ok "failed refresh preserves installed panel"
else
    no "failed refresh preserves installed panel" "unchanged" "overwritten"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
