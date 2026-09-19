#!/bin/sh
# tests/test_quic_pool_general.sh — QUIC перестал быть ютубовским.
#
# ЧТО БЫЛО. QUIC-профиль нёс ровно один список — ютубовский. Заблокированные
# сайты по HTTP/3 не обрабатывались НИ ОДНИМ профилем: браузер уходил в QUIC,
# получал тишину и откатывался на TCP (лишние секунды на каждом соединении), а
# приложения, которые так не умеют, просто не работали. Замер на роутере
# владельца 16.09.2026: через минуты после включения ркн-списка в этот профиль
# в пуле появились facebook, instagram, cdninstagram, whatsapp — трафик там был
# всегда, просто мимо нас.
#
# ЧТО ОХРАНЯЕТСЯ ЗДЕСЬ:
#   * профиль несёт и ютубовский список, и весь набор РКН — иначе половина
#     флота молча вернётся к «QUIC не обходится»;
#   * ключ пула называется quic, а не yt_quic: на ключ завязаны состояние
#     ротации, детектор молчания, панель и сводка статистики;
#   * Discord в QUIC-профиль НЕ попал: его UDP живёт на своих портах и
#     разбирается отдельным профилем, а общий хостлист сломал бы фильтр;
#   * перенос ключа в state.tsv работает и делается ровно один раз. Без него
#     каждый роутер теряет сошедшуюся ротацию и сутки подбирает заново — молча,
#     то есть для человека «после обновления сломался ютуб».
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
GEN="$HERE/lib/config_official.sh"
INIT="$HERE/files/S99zapret2.new"
INI="$HERE/quic_strats.ini"
ACTIONS="$HERE/webpanel/cgi/actions.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

for f in "$GEN" "$INIT" "$INI" "$ACTIONS"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/quicpool.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 1. Строка QUIC-профиля в сгенерированном конфиге.
# ---------------------------------------------------------------------------
# Берём ту же строку, что уедет на роутер: генератор вызывается как в бою,
# грепом по исходнику такое не проверить — списки склеиваются в трёх местах.
ROOT="$T/opt"
mkdir -p "$ROOT/lists" "$ROOT/extra_strats/TCP/RKN" "$ROOT/extra_strats/TCP/YT" \
         "$ROOT/extra_strats/TCP/YT_GV" "$ROOT/extra_strats/UDP/YT" "$ROOT/ipset"
printf 'rutracker.org\n'  > "$ROOT/extra_strats/TCP/RKN/List.txt"
printf 'youtube.com\n'    > "$ROOT/extra_strats/TCP/YT/List.txt"
printf 'googlevideo.com\n'> "$ROOT/extra_strats/TCP/YT_GV/List.txt"
printf 'youtube.com\n'    > "$ROOT/extra_strats/UDP/YT/List.txt"
printf 'example.org\n'    > "$ROOT/lists/extra-domains.txt"
: > "$ROOT/lists/whitelist.txt"
printf 'discord.com\n'    > "$ROOT/extra_strats/TCP_Discord.txt"
printf 'ENABLED=1\n'      > "$ROOT/config"

OUT="$T/generated"
# Генератор зовём так же, как боевой установщик: utils.sh, затем сам генератор,
# затем create_official_config с корнем-подделкой. Проверять строку профиля
# грепом по исходнику нельзя — списки склеиваются в трёх разных местах файла.
(
    # shellcheck disable=SC1090
    . "$HERE/lib/utils.sh"
    # shellcheck disable=SC1090
    . "$GEN"
    ZAPRET2_DIR="$ROOT" create_official_config "$ROOT/config" >/dev/null 2>&1
    cat "$ROOT/config"
) > "$OUT" 2>/dev/null

QLINE=$(grep -F -- '--filter-udp=443 --filter-l7=quic' "$OUT" | head -1)
if [ -z "$QLINE" ]; then
    no "QUIC-профиль найден в сгенерированном конфиге" "строка профиля" "нет"
else
    ok "QUIC-профиль найден в сгенерированном конфиге"
    case "$QLINE" in *"UDP/YT/List.txt"*) ok "QUIC несёт ютубовский список" ;;
        *) no "QUIC несёт ютубовский список" "--hostlist=…UDP/YT/List.txt" "нет" ;; esac
    case "$QLINE" in *"TCP/RKN/List.txt"*) ok "QUIC несёт список РКН" ;;
        *) no "QUIC несёт список РКН" "--hostlist=…TCP/RKN/List.txt" "нет" ;; esac
    case "$QLINE" in *"extra-domains.txt"*) ok "QUIC несёт дополнительные домены" ;;
        *) no "QUIC несёт дополнительные домены" "--hostlist=…extra-domains.txt" "нет" ;; esac
    case "$QLINE" in *"discovered-domains.txt"*) no "QUIC не подключает retired discovery" "absent" "$QLINE" ;;
        *) ok "QUIC не подключает retired discovery" ;; esac
    # Discord — отдельный профиль на своих портах: его список здесь только
    # раздул бы сопоставление и ничего не дал.
    case "$QLINE" in *TCP_Discord*) no "Discord-список в QUIC не попал" "без него" "есть" ;;
        *) ok "Discord-список в QUIC не попал" ;; esac
    case "$QLINE" in *key=quic:*) ok "ключ пула — quic" ;;
        *) no "ключ пула — quic" "key=quic" "$(printf '%s' "$QLINE" | grep -o 'key=[a-z_]*' | head -1)" ;; esac
    case "$QLINE" in *key=yt_quic*) no "старого ключа в конфиге нет" "без yt_quic" "есть" ;;
        *) ok "старого ключа в конфиге нет" ;; esac
    # Порог детектора обязан остаться ниже окна перехвата — инвариант не
    # связан с переименованием, но ломается ровно теми же правками.
    case "$QLINE" in *udp_in=1:udp_out=5*) ok "пороги детектора не поехали" ;;
        *) no "пороги детектора" "udp_in=1:udp_out=5" "$(printf '%s' "$QLINE" | grep -o 'udp_in=[0-9]*:udp_out=[0-9]*' | head -1)" ;; esac
fi

# База стратегий и панель обязаны звать пул тем же именем.
eq "секция в quic_strats.ini переименована" "1" "$(grep -c '^\[quic_autocircular\]' "$INI")"
eq "ключ в quic_strats.ini переименован"    "1" "$(grep -c 'key=quic:' "$INI")"
eq "панель знает пул quic" "1" \
    "$(grep -c 'STRATEGY_POOLS="rkn_tcp yt_tcp gv_tcp quic discord_udp"' "$ACTIONS")"
# Своя строка человека лежала в файле со старым именем — читать его мы обязаны
# и дальше, иначе настройка исчезает молча.
eq "старый custom-strategies/yt_quic.txt всё ещё читается" "1" \
    "$(grep -c 'z2k_custom_strategy yt_quic' "$GEN")"

# ---------------------------------------------------------------------------
# 2. Перенос ключа в состоянии ротации (init, до старта демона).
# ---------------------------------------------------------------------------
awk '/^_z2k_migrate_quic_pool_key\(\)/,/^}/' "$INIT" > "$T/mig.sh"
if [ ! -s "$T/mig.sh" ]; then
    no "в init есть функция переноса ключа" "функция" "не найдена"
else
    B="$T/base"
    mkdir -p "$B/extra_strats/cache/autocircular" "$B/state"
    ST="$B/extra_strats/cache/autocircular/state.tsv"
    mk_state() {
        printf '# z2k autocircular state\n' > "$ST"
        printf 'yt_quic\tyoutube.com|4\t3\t1789000000\tauto\t\n' >> "$ST"
        printf 'rkn_tcp\trutracker.org|4\t7\t1789000001\tauto\t\n' >> "$ST"
        printf 'yt_quic\ti.instagram.com|6\t2\t1789000002\tfrozen\t\n' >> "$ST"
    }
    run_mig() { ZAPRET_BASE="$B" sh -c ". $T/mig.sh; _z2k_migrate_quic_pool_key" 2>&1; }

    mk_state
    run_mig >/dev/null
    eq "строки пула переехали на quic" "2" "$(awk -F'\t' '$1=="quic"' "$ST" | wc -l | tr -d ' ')"
    eq "старого ключа не осталось"     "0" "$(awk -F'\t' '$1=="yt_quic"' "$ST" | wc -l | tr -d ' ')"
    eq "чужой пул не тронут"           "1" "$(awk -F'\t' '$1=="rkn_tcp"' "$ST" | wc -l | tr -d ' ')"
    # Заморозка оператора — пятое поле — обязана пережить перенос: это его
    # решение, а не наш кэш.
    eq "заморозка сохранилась" "frozen" \
        "$(awk -F'\t' '$1=="quic" && $2=="i.instagram.com|6" {print $5}' "$ST")"
    eq "шапка файла на месте" "1" "$(grep -c '^# z2k autocircular state' "$ST")"
    eq "отметка «сделано» поставлена" "1" \
        "$([ -f "$B/state/quic-pool-key.done" ] && echo 1 || echo 0)"

    # Второй запуск: файл уже переписан, но отметка обязана держать нас в
    # стороне даже если кто-то вернёт старые строки руками.
    mk_state
    out2=$(run_mig)
    eq "повторный запуск ничего не делает" "2" "$(awk -F'\t' '$1=="yt_quic"' "$ST" | wc -l | tr -d ' ')"
    eq "и молчит" "" "$out2"

    # Замок занят (демон или панель пишут прямо сейчас) — не лезем и НЕ
    # ставим отметку: перенос повторится на следующем старте.
    rm -f "$B/state/quic-pool-key.done"
    mk_state
    : > "$ST.lock"
    run_mig >/dev/null
    eq "под замком состояние не тронуто" "2" "$(awk -F'\t' '$1=="yt_quic"' "$ST" | wc -l | tr -d ' ')"
    eq "под замком отметка не ставится" "0" \
        "$([ -f "$B/state/quic-pool-key.done" ] && echo 1 || echo 0)"
    rm -f "$ST.lock"

    # Запасной дом состояния в tmpfs — тот же перенос.
    rm -f "$B/state/quic-pool-key.done"
    FB="/tmp/z2k-autocircular-state.tsv"
    if [ ! -e "$FB" ]; then
        printf 'yt_quic\tyoutube.com|4\t3\t1789000000\tauto\t\n' > "$FB"
        mk_state
        run_mig >/dev/null
        eq "запасной файл состояния тоже переехал" "1" \
            "$(awk -F'\t' '$1=="quic"' "$FB" | wc -l | tr -d ' ')"
        rm -f "$FB"
    else
        printf '[SKIP] запасной файл состояния (на машине лежит настоящий %s)\n' "$FB"
    fi
fi

# Вызов обязан стоять ДО подъёма демона: правка файла под работающим демоном —
# гонка с его собственным снимком, и выигрывает её он.
_call=$(grep -n '_z2k_migrate_quic_pool_key$' "$INIT" | tail -1 | cut -d: -f1)
_start=$(grep -n 'if ! start_daemons; then' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$_call" ] && [ -n "$_start" ] && [ "$_call" -lt "$_start" ]; then
    ok "перенос вызывается до start_daemons"
else
    no "перенос вызывается до start_daemons" "вызов выше" "вызов=${_call:-нет} start=${_start:-нет}"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
