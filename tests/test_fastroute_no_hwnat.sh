#!/bin/sh
# tests/test_fastroute_no_hwnat.sh — программный fastpath (nf_conntrack_fastroute)
# гасится вместе с fastnat ТОЛЬКО там, где нет драйвера аппаратного NAT, и только
# пока тумблер Z2K_FASTROUTE_OFF не выставлен в 0. Полевой случай 18.09.2026:
# портированная KeeneticOS на Cudy WR3000U без /proc/driver/hw_nat — ротатор не
# видел отказов, fastroute=0 руками починил обход.
#
# Функции вытаскиваются из S99zapret2.new (extract_fn), каталог сисктлов и
# каталог драйвера подменяются через Z2K_NF_SYSCTL / Z2K_HWNAT_DIR.
HERE=$(cd "$(dirname "$0")/.." && pwd)
INIT="${Z2K_INIT:-$HERE/files/S99zapret2.new}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fastroute.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[ \t]*$" { inf=1 }
        inf { print }
        inf && /^}/ { exit }
    ' "$2"
}
FNS="$TMP/fns.sh"
{
    extract_fn z2k_no_hwnat            "$INIT"; echo
    extract_fn z2k_fastroute_wanted    "$INIT"; echo
    extract_fn z2k_conntrack_tune_start "$INIT"; echo
    extract_fn z2k_conntrack_tune_stop  "$INIT"; echo
} > "$FNS"
for f in z2k_no_hwnat z2k_fastroute_wanted z2k_conntrack_tune_start z2k_conntrack_tune_stop; do
    grep -q "^$f()" "$FNS" && ok "extracted $f()" || no "extracted $f()" "a definition" "none"
done

# Имитация /proc/sys/net/netfilter: все пять сисктлов на заводских значениях.
mk_sysctl() {
    rm -rf "$TMP/nf"; mkdir -p "$TMP/nf"
    echo 0 > "$TMP/nf/nf_conntrack_tcp_be_liberal"
    echo 1 > "$TMP/nf/nf_conntrack_checksum"
    echo 1 > "$TMP/nf/nf_conntrack_fastnat"
    echo 1 > "$TMP/nf/nf_conntrack_fastnat_xfrm"
    echo 1 > "$TMP/nf/nf_conntrack_fastroute"
}
val() { cat "$TMP/nf/$1"; }

# run <flag> <hwnat_present 0|1> <fn>
run() {
    local flag="$1" hw="$2" fn="$3" hwdir="$TMP/hw_nat_absent"
    [ "$hw" = "1" ] && { hwdir="$TMP/hw_nat"; mkdir -p "$hwdir"; }
    ( Z2K_NF_SYSCTL="$TMP/nf" Z2K_HWNAT_DIR="$hwdir" Z2K_FASTROUTE_OFF="$flag" sh -c ". \"$FNS\"; $fn" ) >"$TMP/out" 2>&1
}

# 1. Без драйвера, флаг по умолчанию: fastroute гасится вместе с fastnat.
mk_sysctl; run "" 0 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "нет hw_nat, флаг пуст: fastroute -> 0" || no "нет hw_nat: fastroute" 0 "$(val nf_conntrack_fastroute)"
[ "$(val nf_conntrack_fastnat)" = 0 ]   && ok "fastnat -> 0 как раньше"               || no "fastnat" 0 "$(val nf_conntrack_fastnat)"
grep -q "fastroute=0" "$TMP/out" && ok "старт печатает, что fastpath выключен" || no "лог старта" "fastroute=0" "$(cat "$TMP/out")"

# 2. Тот же случай, stop: заводская единица возвращается.
run "" 0 z2k_conntrack_tune_stop
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "stop без hw_nat: fastroute -> 1" || no "stop: fastroute" 1 "$(val nf_conntrack_fastroute)"

# 3. Драйвер есть: fastroute не трогается ни на старте, ни на стопе.
mk_sysctl; run "" 1 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "есть hw_nat: fastroute не тронут на старте" || no "hw_nat start" 1 "$(val nf_conntrack_fastroute)"
[ "$(val nf_conntrack_fastnat)" = 0 ]   && ok "есть hw_nat: fastnat всё равно 0"             || no "hw_nat fastnat" 0 "$(val nf_conntrack_fastnat)"
echo 0 > "$TMP/nf/nf_conntrack_fastroute"; run "" 1 z2k_conntrack_tune_stop
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "есть hw_nat: stop не возвращает чужое значение" || no "hw_nat stop" 0 "$(val nf_conntrack_fastroute)"

# 4. Тумблер выключен: без драйвера fastroute остаётся 1.
mk_sysctl; run 0 0 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 1 ] && ok "Z2K_FASTROUTE_OFF=0: fastroute не тронут" || no "flag 0" 1 "$(val nf_conntrack_fastroute)"
grep -q "fastroute=0" "$TMP/out" && no "flag 0: лог молчит" "" "$(cat "$TMP/out")" || ok "flag 0: старт не рапортует о выключении"

# 5. Тумблер явно 1 — как по умолчанию.
mk_sysctl; run 1 0 z2k_conntrack_tune_start
[ "$(val nf_conntrack_fastroute)" = 0 ] && ok "Z2K_FASTROUTE_OFF=1: fastroute -> 0" || no "flag 1" 0 "$(val nf_conntrack_fastroute)"

# 6. Файла сисктла нет (старое ядро): старт не падает и ничего не печатает.
rm -f "$TMP/nf/nf_conntrack_fastroute"; run "" 0 z2k_conntrack_tune_start
[ $? -eq 0 ] && ok "нет файла fastroute: старт возвращает 0" || no "нет файла" 0 "$?"
[ ! -e "$TMP/nf/nf_conntrack_fastroute" ] && ok "нет файла fastroute: не создан" || no "файл создан" "absent" "present"

# Панель: исполняем настоящий обработчик с подменными путями sysctl.
. "$HERE/lib/utils.sh"
. "$HERE/webpanel/cgi/actions.sh"
Z2K_NF_SYSCTL="$TMP/nf"
Z2K_HWNAT_DIR="$TMP/absent"
CONFIG_FILE="$TMP/config"
is_running() { [ "$panel_running" = 1 ]; }
# BSD sed требует пустой суффикс для -i; код записи конфига остаётся боевым.
sed() {
    if [ "$1" = -i ] && [ "$(uname)" = Darwin ]; then
        shift; command sed -i '' "$@"
    else
        command sed "$@"
    fi
}
panel_running=1
mk_sysctl
printf 'Z2K_FASTROUTE_OFF=0\n' > "$CONFIG_FILE"
toggle_fastroute 1 > "$TMP/out" 2>&1
[ "$?" = 0 ] && [ "$(val nf_conntrack_fastroute)" = 0 ] && grep -q '=1' "$CONFIG_FILE" && ok "панель выключает кэш и сохраняет флаг" || no "панель on" success failed
toggle_fastroute 0 > "$TMP/out" 2>&1
[ "$?" = 0 ] && [ "$(val nf_conntrack_fastroute)" = 1 ] && ok "панель возвращает кэш без рестарта" || no "панель off" 1 failed
CONFIG_FILE="$TMP/missing-config"
toggle_fastroute 1 > "$TMP/out" 2>&1
[ "$?" != 0 ] && [ "$(val nf_conntrack_fastroute)" = 1 ] && ok "отказ записи конфига возвращает кэш" || no "rollback" 1 failed
CONFIG_FILE="$TMP/config"
rm "$TMP/nf/nf_conntrack_fastroute"
toggle_fastroute 1 > "$TMP/out" 2>&1
[ "$?" != 0 ] && grep -q '=0' "$CONFIG_FILE" && ok "нет sysctl: ошибка, флаг прежний" || no "missing sysctl" error success
mk_sysctl
panel_running=0
toggle_fastroute 1 > "$TMP/out" 2>&1
[ "$?" != 0 ] && [ "$(val nf_conntrack_fastroute)" = 1 ] && grep -q '=0' "$CONFIG_FILE" && ok "остановленный обход: изменение отклонено" || no "stopped" rejected failed
panel_running=1
Z2K_HWNAT_DIR="$TMP/hw_nat"; mkdir -p "$Z2K_HWNAT_DIR"
toggle_fastroute 1 > "$TMP/out" 2>&1
[ "$?" != 0 ] && [ "$(val nf_conntrack_fastroute)" = 1 ] && grep -q 'Не применяется' "$TMP/out" && ok "драйвер найден: изменение отклонено" || no "hw nat" rejected failed
# Ядро может принять запись без изменения значения: readback обязан отвергнуть.
(cat() { printf '1\n'; }; fastroute_write "$TMP/nf/nf_conntrack_fastroute" 0) > "$TMP/out" 2>&1
[ "$?" != 0 ] && ok "неподтверждённая запись отвергается" || no "readback" error success
fastroute_write "$TMP/absent-dir/value" 0 > "$TMP/out" 2>&1
[ "$?" != 0 ] && ok "ошибка записи не скрывается" || no "write failure" error success
echo 0 > "$TMP/nf/nf_conntrack_fastroute"
fastroute_status > "$TMP/out"
grep -q 'сейчас выключен' "$TMP/out" && ok "статус читает ядро, а не флаг" || no "status" actual flag

# The UI state comes from the kernel and applicability, not the saved flag.
printf 'Z2K_FASTROUTE_OFF=1\n' > "$CONFIG_FILE"
fastroute_snapshot
[ "$fastroute:$fastroute_available" = 0:0 ] && ok "с hardware NAT тумблер выключен и недоступен даже при flag=1/cache=0" || no "hardware snapshot" 0:0 "$fastroute:$fastroute_available"
Z2K_HWNAT_DIR="$TMP/absent"
fastroute_snapshot
[ "$fastroute:$fastroute_available" = 1:1 ] && ok "без hardware NAT cache=0 показывает включённое отключение" || no "active snapshot" 1:1 "$fastroute:$fastroute_available"
echo 1 > "$TMP/nf/nf_conntrack_fastroute"
fastroute_snapshot
[ "$fastroute:$fastroute_available" = 0:1 ] && ok "cache=1 показывает выключенный тумблер вопреки flag=1" || no "inactive snapshot" 0:1 "$fastroute:$fastroute_available"
panel_running=0
fastroute_snapshot
[ "$fastroute:$fastroute_available" = 0:0 ] && ok "остановленный сервис: off/disabled" || no "stopped snapshot" 0:0 "$fastroute:$fastroute_available"
panel_running=1
rm "$TMP/nf/nf_conntrack_fastroute"
fastroute_snapshot
[ "$fastroute:$fastroute_available" = 0:0 ] && ok "неизвестное состояние: off/disabled" || no "unknown snapshot" 0:0 "$fastroute:$fastroute_available"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
