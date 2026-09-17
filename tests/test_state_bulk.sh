#!/bin/sh
# tests/test_state_bulk.sh — пакетная операция над группой строк ротатора.
#
# ЗАЧЕМ ПАКЕТОМ. Группа fbcdn.net на роутере владельца — 74 строки. Поштучно это
# 74 захвата общего с Lua замка и 74 перезаписи файла состояния на флешке, и
# между ними демон успевает положить свой снимок — часть правок теряется. Здесь
# один замок и одна перезапись на файл.
#
# ЧЕМ ОПАСНО. Операция трогает чужие строки по построению: один домен живёт в
# нескольких пулах, у каждого свой арсенал. Промах по пулу — снесённый подбор
# там, где человек ничего не просил. Поэтому здесь проверяется прежде всего то,
# чего операция НЕ должна делать.
#
# Тест исполняет настоящие функции из webpanel/cgi/actions.sh на поддельном
# состоянии — грепом такое не проверяется.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
ACTIONS="$HERE/webpanel/cgi/actions.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

[ -f "$ACTIONS" ] || { printf '[FAIL] нет %s\n' "$ACTIONS"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/bulk.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

ZAPRET2_DIR="$T/opt";                       export ZAPRET2_DIR
CONFIG_FILE="$ZAPRET2_DIR/config";          export CONFIG_FILE
LISTS_DIR="$ZAPRET2_DIR/lists";             export LISTS_DIR
STATE_FILE="$T/state.tsv";                  export STATE_FILE
STATE_FILE_FALLBACK="$T/fallback.tsv";      export STATE_FILE_FALLBACK
INIT_SCRIPT="$T/S99-stub";                  export INIT_SCRIPT
mkdir -p "$LISTS_DIR"
printf 'ENABLED=1\n' > "$CONFIG_FILE"
printf '#!/bin/sh\nexit 0\n' > "$INIT_SCRIPT"; chmod +x "$INIT_SCRIPT"

# shellcheck disable=SC1090
. "$ACTIONS" 2>/dev/null

mk_state() {
    for _f in "$STATE_FILE" "$STATE_FILE_FALLBACK"; do
        {
            printf '# key\thost\tstrategy\tts\tmode\tsni\n'
            printf 'rkn_tcp\ta.discord.media|4\t2\t100\tauto\t\n'
            printf 'rkn_tcp\tb.discord.media|4\t3\t101\tfrozen\t\n'
            printf 'rkn_tcp\tc.discord.media|6\t1\t102\tauto\t\n'
            printf 'quic\ta.discord.media|4\t5\t103\tauto\t\n'
            printf 'rkn_tcp\tkeep.example.com|4\t7\t104\tauto\t\n'
        } > "$_f"
    done
}
rows() { awk -F'\t' -v k="$1" -v h="$2" '$1==k && $2==h' "$STATE_FILE" | wc -l | tr -d ' '; }
field() { awk -F'\t' -v k="$1" -v h="$2" -v n="$3" '$1==k && $2==h {print $n; exit}' "$STATE_FILE"; }
fallback_rows() { awk -F'\t' -v k="$1" -v h="$2" '$1==k && $2==h' "$STATE_FILE_FALLBACK" | wc -l | tr -d ' '; }

# --- 1. Удаление группы -----------------------------------------------------
mk_state
out=$(printf 'a.discord.media|4\nb.discord.media|4\nc.discord.media|6\n' | state_bulk delete rkn_tcp 2>&1)
eq "удаление отчитывается «сделано всего»" "3 3" "$out"
eq "строки пула удалены"                   "0" "$(rows rkn_tcp a.discord.media\|4)"
eq "и во втором файле состояния тоже"      "0" "$(fallback_rows rkn_tcp a.discord.media\|4)"
eq "тот же домен в ДРУГОМ пуле не тронут"  "1" "$(rows quic a.discord.media\|4)"
eq "чужой домен того же пула не тронут"    "1" "$(rows rkn_tcp keep.example.com\|4)"
eq "шапка файла на месте" "1" "$(grep -c '^# key' "$STATE_FILE")"

# --- 2. Заморозка группы ----------------------------------------------------
mk_state
out=$(printf 'a.discord.media|4\nc.discord.media|6\n' | state_bulk freeze rkn_tcp 2>&1)
eq "заморозка отчитывается" "2 2" "$out"
eq "первая строка заморожена"  "frozen" "$(field rkn_tcp a.discord.media\|4 5)"
eq "вторая строка заморожена"  "frozen" "$(field rkn_tcp c.discord.media\|6 5)"
# Стратегия у каждой своя — общей у группы нет, и подменять её мы не вправе.
eq "стратегия первой сохранена"  "2" "$(field rkn_tcp a.discord.media\|4 3)"
eq "стратегия второй сохранена"  "1" "$(field rkn_tcp c.discord.media\|6 3)"
eq "метка времени не переписана" "100" "$(field rkn_tcp a.discord.media\|4 4)"
eq "строка соседнего пула осталась авто" "auto" "$(field quic a.discord.media\|4 5)"

# --- 3. Разморозка ----------------------------------------------------------
out=$(printf 'a.discord.media|4\nb.discord.media|4\n' | state_bulk unfreeze rkn_tcp 2>&1)
eq "разморозка отчитывается" "2 2" "$out"
eq "своя заморозка снята"    "auto" "$(field rkn_tcp a.discord.media\|4 5)"
eq "чужая заморозка снята только у названных" "auto" "$(field rkn_tcp b.discord.media\|4 5)"

# --- 4. Частичный результат -------------------------------------------------
# Хост, которого в состоянии нет (демон успел убрать сам): операция не падает,
# но и не врёт «готово» — в отчёте видно, что сделано меньше запрошенного.
mk_state
out=$(printf 'a.discord.media|4\nghost.discord.media|4\n' | state_bulk delete rkn_tcp 2>&1)
eq "частичный результат виден в отчёте" "1 2" "$out"

# --- 5. Отказы --------------------------------------------------------------
mk_state
printf 'a.discord.media|4\n' | state_bulk wipe rkn_tcp >/dev/null 2>&1 \
    && no "неизвестное действие отвергнуто" "отказ" "приняли" \
    || ok "неизвестное действие отвергнуто"
printf 'a.discord.media|4\n' | state_bulk delete 'rkn tcp' >/dev/null 2>&1 \
    && no "пул с пробелом отвергнут" "отказ" "приняли" \
    || ok "пул с пробелом отвергнут"
printf '\n\n' | state_bulk delete rkn_tcp >/dev/null 2>&1 \
    && no "пустой список отвергнут" "отказ" "приняли" \
    || ok "пустой список отвергнут"
eq "после отказов состояние целое" "5" "$(grep -vc '^#' "$STATE_FILE")"

# Негодное имя пропускается, а остальные обрабатываются: одна кривая строка не
# должна отменять операцию над остальными семьюдесятью.
mk_state
out=$(printf 'a.discord.media|4\nbad host;rm\n' | state_bulk delete rkn_tcp 2>&1)
eq "кривое имя отброшено, годное сделано" "1 1" "$out"
eq "годная строка удалена" "0" "$(rows rkn_tcp a.discord.media\|4)"

# --- 5a. Тело без перевода строки в конце ------------------------------------
# Замер на живом роутере: из десяти хостов обработались девять — последняя
# строка без \n терялась в read. Панель перевод шлёт, курл и прочие клиенты —
# как получится, и молча терять хост нельзя.
mk_state
out=$(printf 'a.discord.media|4\nc.discord.media|6' | state_bulk delete rkn_tcp 2>&1)
eq "последняя строка без перевода не теряется" "2 2" "$out"
eq "обе строки удалены" "0" "$(rows rkn_tcp c.discord.media\|6)"

# --- 6. Замок ---------------------------------------------------------------
#
# Замок ВРЕМЕННОЙ: держатель пишет в файл метку, и старше десяти секунд она
# считается брошенной — иначе убитый CGI вешал бы правку состояния навсегда.
# Поэтому «занятый замок» проверяется не отказом (свежий замок функция честно
# ждёт, и на роутере с usleep это две секунды, а на машине разработчика, где
# usleep нет, — полторы минуты: набору такое ожидание не нужно), а тем, что
# брошенный замок не мешает работать и что свой замок снимается за собой.
mk_state
printf '%s' "$(( $(date +%s) - 3600 ))" > "$STATE_FILE.lock"   # брошен час назад
out=$(printf 'a.discord.media|4\n' | state_bulk delete rkn_tcp 2>&1)
eq "брошенный замок не мешает" "1 1" "$out"
eq "строка удалена, несмотря на старый замок" "0" "$(rows rkn_tcp a.discord.media\|4)"
rm -f "$STATE_FILE.lock"

# Замок за собой снят — иначе следующая правка встанет намертво.
mk_state
printf 'a.discord.media|4\n' | state_bulk delete rkn_tcp >/dev/null 2>&1
eq "замок снят после операции" "0" "$([ -e "$STATE_FILE.lock" ] && echo 1 || echo 0)"

# --- 7. Временные файлы за собой ---------------------------------------------
eq "временный список хостов убран" "0" "$(ls /tmp/z2k-state-bulk.* 2>/dev/null | wc -l | tr -d ' ')"

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
