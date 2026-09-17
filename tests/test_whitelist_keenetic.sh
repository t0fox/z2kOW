#!/bin/sh
# tests/test_whitelist_keenetic.sh — домены Keenetic доезжают до УЖЕ стоящих
# установок, а не только до новых.
#
# ЛОВУШКА, РАДИ КОТОРОЙ ТЕСТ. Белый список заводит create_base_config
# (lib/config.sh), а её зовёт ТОЛЬКО полная установка (lib/install.sh). Патч её
# не запускает — значит правка списка, сделанная в config.sh, у всех, кто уже
# стоит, не появится никогда. Дозапись живёт в init: он приезжает вместе с
# обновлением и стартует сразу после него.
#
# Второе, что здесь охраняется: решение человека. Белый список правят руками, и
# если строки СНЯЛИ — возвращать их значит переспорить владельца роутера.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="$HERE/files/S99zapret2.new"
CFG="$HERE/lib/config.sh"
AUTH="$HERE/webpanel/cgi/auth.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wlkeen.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lists"

awk '/^_z2k_whitelist_keenetic\(\)/,/^}/' "$INIT" > "$T/fn.sh"
if [ ! -s "$T/fn.sh" ]; then
    no "в init есть дозапись доменов Keenetic" "функция" "не найдена"
else
    run() { LISTS_DIR="$T/lists" sh -c ". $T/fn.sh; _z2k_whitelist_keenetic" 2>&1; }

    printf '# белый список\ngosuslugi.ru\nkeenetic.net\n' > "$T/lists/whitelist.txt"
    out=$(run)
    case "$out" in *Keenetic*) ok "дозапись сообщает о себе" ;;
        *) no "дозапись сообщает о себе" "строка про Keenetic" "$out" ;; esac
    for d in keenetic.name mykeenetic.com mykeenetic.net mykeenetic.ru netcraze.net crazedns.ru; do
        eq "домен $d дописан" "1" "$(grep -c "^$d\$" "$T/lists/whitelist.txt")"
    done
    eq "чужие строки не тронуты" "1" "$(grep -c '^gosuslugi.ru$' "$T/lists/whitelist.txt")"

    # Второй старт: ни дублей, ни вывода.
    out2=$(run)
    eq "повторный старт молчит" "" "$out2"
    eq "дублей не появилось" "1" "$(grep -c '^crazedns.ru$' "$T/lists/whitelist.txt")"

    # Человек снял домены сам — возвращать нельзя.
    printf 'gosuslugi.ru\ncrazedns.ru\n' > "$T/lists/whitelist.txt"
    run >/dev/null
    eq "снятые вручную домены не возвращаются" "0" \
        "$(grep -c '^keenetic.name$' "$T/lists/whitelist.txt")"

    # Списка нет вовсе (сервис поднимают до установки списков) — не падаем.
    rm -f "$T/lists/whitelist.txt"
    run >/dev/null 2>&1
    eq "без файла списка выходим тихо" "0" \
        "$([ -f "$T/lists/whitelist.txt" ] && echo 1 || echo 0)"
fi

# Вызов обязан стоять ДО подъёма демона: список читается по mtime при старте.
_call=$(grep -n '_z2k_whitelist_keenetic$' "$INIT" | tail -1 | cut -d: -f1)
_start=$(grep -n 'if ! start_daemons; then' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$_call" ] && [ -n "$_start" ] && [ "$_call" -lt "$_start" ]; then
    ok "дозапись идёт до старта демона"
else
    no "дозапись идёт до старта демона" "вызов выше" "вызов=${_call:-нет} старт=${_start:-нет}"
fi

# Новые установки берут домены из генератора списка, а панель обязана принимать
# те же имена как свои — иначе на этом адресе каждое действие получит 403.
# Имён в config.sh ровно ДВА вхождения на домен, и это не дубль: первое — в
# списке для новой установки, второе — в дозаписи для тех, кто уже стоит. Обе
# ветки нужны, и обе проверяются.
for d in keenetic.name mykeenetic.com mykeenetic.net mykeenetic.ru netcraze.net crazedns.ru; do
    eq "config.sh знает $d в обеих ветках" "2" "$(grep -c "^$d\$" "$CFG")"
done
eq "страж панели знает keenetic.name" "1" "$(grep -c 'keenetic.name|\*.keenetic.name' "$AUTH")"
eq "страж панели знает mykeenetic"    "1" "$(grep -c 'mykeenetic.com|\*.mykeenetic.net|\*.mykeenetic.ru' "$AUTH")"
eq "страж панели знает crazedns.ru"   "1" "$(grep -c 'crazedns.ru) return 0' "$AUTH")"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
