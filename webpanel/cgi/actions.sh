Warning: truncated output (original token count: 65516)
Total output lines: 4858

#!/bin/sh
# z2k webpanel — action handlers.
# Each function mirrors exactly what the corresponding menu_* function in
# lib/menu.sh does, minus the interactive printf/read/pause layer.
# Sourced from api.sh. All functions return 0 on success, non-zero on error
# and write a single-line error to stderr (captured by the caller into JSON).

# Package/update delivery seam. The byte payload remains updater-owned; this
# marker lets the OpenWrt package refuse a stale executable CGI instead of
# reporting a false-success install.
Z2K_OPENWRT_PANEL_CONTRACT=1

ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
CONFIG_DIR="${CONFIG_DIR:-/opt/etc/zapret2}"
LISTS_DIR="${LISTS_DIR:-$ZAPRET2_DIR/lists}"
INIT_SCRIPT="${INIT_SCRIPT:-/opt/etc/init.d/S99zapret2}"
CONFIG_FILE="${CONFIG_FILE:-$ZAPRET2_DIR/config}"
Z2K_JOB_DIR="${Z2K_JOB_DIR:-/tmp}"
WHITELIST_FILE="${WHITELIST_FILE:-$LISTS_DIR/whitelist.txt}"
EXTRA_DOMAINS_FILE="${EXTRA_DOMAINS_FILE:-$LISTS_DIR/extra-domains.txt}"
WARP_SCRIPT="${WARP_SCRIPT:-$ZAPRET2_DIR/z2k-warp.sh}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-$LISTS_DIR/warp}"
# Списки в $WARP_LISTS_DIR — целиком пользовательские, их не трогает никто, кроме
# панели. Автоматически обновляются только per-game списки в подкаталоге games/
# (z2k-update-lists.sh перезаписывает их целиком), и панель в них не пишет вовсе —
# выбор хранится именами в .enabled. Никакого 3-way-merge, baseline'ов (.<name>.base)
# и tombstone'ов (.<name>.removed) в дереве нет: они существовали для сводного
# game-warp-ips.txt, который снят, а его остатки разово подчищает
# files/z2k-warp.sh (warp_lists_migrate).

# --- read helpers (POSIX sh, no sourcing of lib/utils.sh required) ---

read_flag() {
    # read_flag <key> <file> [default]
    local key="$1" file="$2" def="${3:-0}"
    [ -f "$file" ] || { printf '%s' "$def"; return 0; }
    local raw val
    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -1)
    if [ -z "$raw" ]; then
        printf '%s' "$def"
        return 0
    fi
    # Кавычки снимаем оба вида: генератор пишет значение в двойных
    # (config_official.sh), set_flag — в одинарных. Разворачивать shell-эскейп
    # апострофа ('\'') здесь НЕЛЬЗЯ: safe_config_read из lib/utils.sh его тоже не
    # разворачивает, и панель показывала бы не то имя политики, с которым реально
    # работает сервис.
    val=$(printf '%s' "$raw" | cut -d'=' -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')
    # An empty value (e.g. `DROP_DPI_RST=` with nothing after the equals)
    # must fall back to the default, not propagate as "" — otherwise the
    # caller's printf emits `"key":,` which breaks JSON. Caught in the wild
    # on Владислав's router 2026-04-15 after a reinstall left DROP_DPI_RST
    # with no value.
    [ -z "$val" ] && val="$def"
    printf '%s' "$val"
}

# set_flag живёт в lib/utils.sh — там же, где его видит и меню.
# Здесь оставлен только запасной вариант на случай, когда utils.sh не
# подгрузился (_gen_libs_source ищет его в двух местах и может не найти):
# CGI не должен падать целиком из-за отсутствия одной библиотеки.
if ! command -v set_flag >/dev/null 2>&1; then
set_flag() {
    # set_flag <key> <value> <file>
    local key="$1" val="$2" file="$3"
    [ -f "$file" ] || { echo "file not found: $file" >&2; return 1; }
    # Конфиг ИСПОЛНЯЕТСЯ как скрипт (files/S99zapret2.new: `. "$ZAPRET_CONFIG"`),
    # поэтому голое POLICY_NAME=Через ВПН уводит второе слово на исполнение как
    # команду. Всё, что не является голым безопасным словом, пишем в ОДИНАРНЫХ
    # кавычках: двойные оставили бы работающими $ и обратную кавычку. Внутренний
    # апостроф закрывается и вставляется отдельно ('\''), как это делает shell.
    #
    # Значения из [A-Za-z0-9_.-] (то есть все флаги 0/1) остаются голыми
    # намеренно: ровно так их пишет генератор (lib/config_official.sh), и на этот
    # вид завязаны проверки вида `grep -q "^ENABLED=1"` в files/000-zapret2.sh и
    # z2k-nfqueue-selfheal.sh. Один ключ не должен выглядеть в конфиге
    # по-разному в зависимости от того, кто его последним трогал.
    local _val _esc
    case "$val" in
        ''|*[!A-Za-z0-9_.-]*) _val="'$(printf '%s' "$val" | sed "s/'/'\\\\''/g")'" ;;
        *) _val="$val" ;;
    esac
    # Второй слой — для sed: разделитель здесь слэш, & в замене означает «весь
    # совпавший текст», а обратный слэш мог прийти из экранирования апострофа.
    _esc=$(printf '%s' "$_val" | sed 's/[&/\\]/\\&/g')
    if grep -q "^${key}=" "$file"; then
        sed -i "s/^${key}=.*/${key}=${_esc}/" "$file"
    else
        printf '%s=%s\n' "$key" "$_val" >> "$file"
    fi
}
fi

# --- запись в файлы-списки -------------------------------------------------
#
# Общая часть для whitelist / extra-domains / nozapret / state.tsv. mod_cgi
# выполняет запросы ПАРАЛЛЕЛЬНО, поэтому имя временного файла обязано быть
# уникальным: две вкладки панели делили один "$file.z2k-new", и запись одной
# уезжала в файл другой.

# Сериализация правок одного списка.
#
# Это не про «много пользователей» — пользователь один. Кнопки удаления в панели
# не блокируются на время запроса, поэтому два быстрых клика подряд (обычная
# чистка списка) уходят двумя запросами, а lighttpd выполняет CGI ПАРАЛЛЕЛЬНО.
# Оба процесса читают файл целиком, и второй mv затирает результат первого:
# запись показывает «Удалено», а после перезагрузки страницы возвращается.
# Проверено на роутере — теряется 5 раз из 5, то есть это не редкая гонка.
#
# flock на Entware нет, дробного sleep в busybox тоже. Каталог — атомарный
# примитив на любой ФС, паузы даёт usleep (он есть); без него деградируем на
# посекундный sleep.
_list_lock() {
    local d="$1.z2k-lock" n=0
    while ! mkdir "$d" 2>/dev/null; do
        # Держатель мог уйти вместе с убитым CGI. Лок старше минуты — битый:
        # любая наша критическая секция это единицы миллисекунд.
        if [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$d" 2>/dev/null
            continue
        fi
        n=$((n + 1))
        [ "$n" -gt 100 ] && return 1
        usleep 20000 2>/dev/null || sleep 1
    done
    return 0
}

_list_unlock() { rmdir "$1.z2k-lock" 2>/dev/null; return 0; }

# --- замок state.tsv, общий с Lua ------------------------------------------
#
# У state.tsv ДВА писателя: демон (files/lua/z2k-state-persist.lua) и вот эта
# панель. Замок был только у демона, и панель его не брала вовсе — то есть он
# охранял писателя, которого не существует (демон один и сам с собой не
# гоняется), и не охранял реального.
#
# Цена проигранной гонки — не порча файла (обе стороны пишут через атомарную
# подмену), а ПОТЕРЯ НАМЕРЕНИЯ оператора: заморозка, пин или удаление строки,
# сделанные из панели между «демон прочитал диск» и «демон переименовал свой
# временный файл», затираются его снимком из памяти. Человек видит, что кнопка
# сработала, а через секунду всё как было.
#
# Протокол ровно тот же, что в Lua, иначе взаимного исключения не выйдет:
#   • файл "<path>.lock", содержимое — unix-время захвата;
#   • пустой или нечисловой = ничей (процесс умер между созданием и записью);
#   • старше 10 секунд = протухший, забираем;
#   • метка из будущего = часы уехали, забираем.
# `set -C` даёт атомарное создание (O_EXCL) без flock, которого на Entware нет.
_state_lock() {
    local f="$1.lock" n=0 now content lt
    while :; do
        now=$(date +%s 2>/dev/null || echo 0)
        if [ -f "$f" ]; then
            content=$(cat "$f" 2>/dev/null | tr -d ' \t\r\n')
            lt=$(printf '%s' "$content" | grep -E '^[0-9]+$' || true)
            if [ -z "$lt" ]; then
                rm -f "$f" 2>/dev/null            # ничей
            elif [ "$lt" -gt "$((now + 10))" ] 2>/dev/null; then
                rm -f "$f" 2>/dev/null            # из будущего
            elif [ "$((now - lt))" -gt 10 ] 2>/dev/null; then
                rm -f "$f" 2>/dev/null            # протух
            fi
        fi
        if ( set -C; printf '%s' "$now" > "$f" ) 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        [ "$n" -gt 100 ] && return 1
        usleep 20000 2>/dev/null || sleep 1
    done
}

_state_unlock() { rm -f "$1.lock" 2>/dev/null; return 0; }

_file_replace() {
    # _file_replace <dest> <tmp> — подменить содержимое уже заполненным temp'ом.
    # Прежний `cat "$tmp" > "$dest"` СНАЧАЛА обнуляет цель: обрыв питания, ENOSPC
    # или гонка на середине оставляли пустой список (для state.tsv — стёртый
    # стейт ротатора вместе с заморозками). mv в пределах одной ФС атомарен, но
    # уносит inode ВМЕСТЕ с правами и владельцем, поэтому и то и другое снимаем
    # с цели и переносим на temp ДО подмены.
    #
    # Владелец здесь не формальность: state.tsv принадлежит nobody:nobody
    # (S99zapret2 делает chown, потому что lua внутри nfqws2 работает под
    # --user=nobody). Одна правка из панели, выполняемой от root, — и файл
    # становится root-owned, а демон теряет право записи в собственный стейт.
    local dest="$1" tmp="$2" meta mode owner
    # busybox: ни stat -c, ни chmod --reference; режим восстанавливаем из
    # символьного вида ls, владельца берём в числовом (-n) — на роутере у uid
    # 65534 имени может не быть вовсе.
    meta=$(ls -ldn "$dest" 2>/dev/null | awk '
        {
            p = substr($1, 2, 9); m = 0; c = ""
            if (substr(p, 1, 1) == "r") m += 400
            if (substr(p, 2, 1) == "w") m += 200
            c = substr(p, 3, 1)
            if (c == "x" || c == "s") m += 100
            if (c == "s" || c == "S") m += 4000
            if (substr(p, 4, 1) == "r") m += 40
            if (substr(p, 5, 1) == "w") m += 20
            c = substr(p, 6, 1)
            if (c == "x" || c == "s") m += 10
            if (c == "s" || c == "S") m += 2000
            if (substr(p, 7, 1) == "r") m += 4
            if (substr(p, 8, 1) == "w") m += 2
            c = substr(p, 9, 1)
            if (c == "x" || c == "t") m += 1
            if (c == "t" || c == "T") m += 1000
            printf "%d %s:%s\n", m, $3, $4
            exit
        }')
    if [ -n "$meta" ]; then
        mode=${meta%% *}; owner=${meta#* }
        # chown ДО chmod: смена владельца сбрасывает setuid/setgid.
        chown "$owner" "$tmp" 2>/dev/null
        chmod "$mode" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp" 2>/dev/null
    fi
    mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_list_remove_line() {
    # _list_remove_line <file> <entry> — выкинуть строку целиком.
    # grep возвращает 1, когда не осталось НИ ОДНОЙ строки — это пустой
    # результат, а не ошибка: на списке из одной записи прежний код уходил в
    # return 1, и удалить её было нельзя вообще. Настоящая ошибка чтения — это
    # код >1, её по-прежнему не глотаем.
    local file="$1" entry="$2" tmp="$1.z2k-new.$$" rc
    grep -vxF "$entry" "$file" > "$tmp"; rc=$?
    [ "$rc" -le 1 ] || { rm -f "$tmp"; return 1; }
    _file_replace "$file" "$tmp"
}

_list_end_nl() {
    # _list_end_nl <file> — дописать перевод строки, если файл им не кончается.
    # Файл могли править руками или подложить снаружи; без этого новая запись
    # приклеивается к последней (old.combar.com), и обе перестают находиться
    # и дедупом grep -qxF, и удалением.
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] && printf '\n' >> "$1"
    return 0
}

_str_len_chars() {
    # _str_len_chars <строка> — длина в СИМВОЛАХ, а не в байтах.
    # ${#var} на ash считает байты, awk на роутере тоже байто-ориентированный
    # (length("привет") == 12), поэтому считаем сами: выбрасываем продолжающие
    # байты UTF-8 (10xxxxxx) — остаётся ровно по одному байту на символ.
    # LC_ALL=C обязателен: в UTF-8-локали диапазон \200-\277 у GNU tr означает
    # символы, а не байты, и не совпадёт ни с чем.
    local s
    s=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' 2>/dev/null)
    # tr нет или он поперхнулся — считаем байты, как раньше: лучше более строгий
    # лимит, чем пропуск строки любой длины.
    [ -z "$s" ] && [ -n "$1" ] && s="$1"
    printf '%s' "${#s}"
}

is_installed() {
    [ -d "$ZAPRET2_DIR" ] && [ -x "$ZAPRET2_DIR/nfq2/nfqws2" ]
}

is_running() {
    # Матчим по отличительной части cmdline демона, как tunnel_pid: голое
    # `pgrep -f nfqws2` ловит и процесс проверки стратегии ("$engine" --dry-run),
    # который панель порождает сама в strategy_validate, — и параллельный опрос
    # /status во время проверки рапортовал running:true на остановленном роутере,
    # а restart_service_if_running в этом окне уходил в ветку рестарта.
    # --fwmark добавляет только init-скрипт (NFQWS2_OPT_BASE в S99zapret2.new),
    # в NFQWS2_OPT из конфига его нет, поэтому под dry-run он не попадает.
    pgrep -f "nfqws2 .*--fwmark=" >/dev/null 2>&1
}

service_status_string() {
    if is_running; then
        echo "active"
    elif is_installed; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

# Source BOTH utils.sh (for safe_config_read and helpers) and
# config_official.sh (for create_official_config). Without utils.sh,
# safe_config_read is undefined → every saved_* variable becomes "" →
# the heredoc emits empty-value flags → toggle never sticks. This was
# the root cause of the game-mode toggle bug (2026-04-16).
#
# Ручного спасения путей вокруг сорсинга здесь БОЛЬШЕ НЕТ. Оно было нужно, пока
# lib/utils.sh присваивал ZAPRET2_DIR/CONFIG_DIR/LISTS_DIR/INIT_SCRIPT
# безусловно: env-override, честно принятый в шапке этого файла, терялся при
# первой же перегенерации, а CONFIG_FILE/WHITELIST_FILE/STATE_FILE оставались
# от прежних значений — внутри одного запроса набор путей оказывался наполовину
# переключённым. Причина устранена в самом utils.sh (присваивание стало
# условным, ${VAR:-умолчание}), и лечить симптом здесь больше незачем.
_gen_libs_source() {
    local utils="" lib=""
    for d in "$ZAPRET2_DIR/lib" /tmp/z2k/lib; do
        [ -f "$d/utils.sh" ] && [ -z "$utils" ] && utils="$d/utils.sh"
        [ -f "$d/config_official.sh" ] && [ -z "$lib" ] && lib="$d/config_official.sh"
    done
    [ -z "$lib" ] && return 1
    # shellcheck disable=SC1090
    [ -n "$utils" ] && . "$utils"
    # shellcheck disable=SC1090
    . "$lib"
    return 0
}

regenerate_config() {
    _gen_libs_source || { echo "config_official.sh not found" >&2; return 1; }
    create_official_config "$CONFIG_FILE" >/dev/null 2>&1
    return $?
}

# ---- custom per-pool strategies -------------------------------------------
# User-owned, unlike shipped Strategy.txt (whose edits an update wipes by
# design). Read by the generator on EVERY regeneration, so they survive toggles,
# reinstalls and auto-updates.
STRATEGY_POOLS="rkn_tcp yt_tcp gv_tcp quic discord_udp"
CUSTOM_STRAT_DIR="${CUSTOM_STRAT_DIR:-$ZAPRET2_DIR/lists/custom-strategies}"

strategy_pool_ok() {
    for _p in $STRATEGY_POOLS; do [ "$1" = "$_p" ] && return 0; done
    return 1
}

# _strategy_pool_source <пул> — поставляемый файл стратегий этого пула.
# Те же пути, что читает генератор конфига (lib/config_official.sh).
_strategy_pool_source() {
    case "$1" in
        rkn_tcp) printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/RKN/Strategy.txt" ;;
        yt_tcp)  printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/YT/Strategy.txt" ;;
        gv_tcp)  printf '%s\n' "$ZAPRET2_DIR/extra_strats/TCP/YT_GV/Strategy.txt" ;;
        # Каталог файла остался ютубовским: путь виден людям в инструкциях и
        # в их собственных заметках, а переносить файлы ради имени ключа —
        # ломать то, что у человека уже работает.
        quic|yt_quic) printf '%s\n' "$ZAPRET2_DIR/extra_strats/UDP/YT/Strategy.txt" ;;
        # У голосового пула шипованного файла НЕТ: его строка живёт прямо в
        # генераторе (lib/config_official.sh, discord_udp). Дублировать её сюда
        # нельзя — две копии длинной строки разъедутся на первом же изменении,
        # и панель начнёт достраивать каркасом от прошлой версии. Поэтому
        # каркас берётся из СГЕНЕРИРОВАННОГО конфига, где лежит ровно то, что
        # сейчас работает; см. _strategy_pool_skeleton_from_config.
        discord_udp) return 1 ;;
        *) return 1 ;;
    esac
}

# _strategy_pool_skeleton_from_config <ключ> — вытащить строку профиля из
# работающего конфига по ключу ротатора.
#
# Нужно пулам без шипованного файла. Читаем то, что реально запущено, поэтому
# каркас не может отстать от генератора.
_strategy_pool_skeleton_from_config() {
    [ -s "$CONFIG_FILE" ] || return 1
    awk -v key="key=$1" '
        index($0, key) { print; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$CONFIG_FILE"
}

# strategy_complete_line <пул> — читает строку со stdin и печатает готовую.
#
# ЗАЧЕМ. Подбор по домену выдаёт ОДИН приём:
#   --lua-desync=multisplit:payload=tls_client_hello:dir=out:pos=1:seqovl=1
# а движку нужен полный набор опций профиля: фильтры портов и уровня, полезная
# нагрузка, окно и токен circular С КЛЮЧОМ ПУЛА (у РКН key=rkn_tcp, у ютуба
# yt_tcp). Человек вставлял то, что дал инструмент, и получал «не удалось
# собрать конфиг» — формат был виноват, а выглядело как поломка.
#
# Достраиваем каркасом ТОГО ПУЛА, куда вставляют: берём поставляемую строку и
# отрезаем её по первому приёму, оставляя всё до него включительно с circular.
# Ключ пула таким образом всегда правильный — он приезжает из каркаса, а не
# угадывается.
#
# Не трогаем строку, если в ней уже есть --filter-: значит человек принёс полный
# набор и знает, что делает. И не трогаем, если приёма нет вовсе — пусть
# валидатор скажет своё, молча дописывать каркас к мусору незачем.
# _strategy_tag_arms — читает строку со stdin и печатает её же, проставив
# приёмам номер strategy=1, если в строке есть ротатор circular, а номеров нет
# ни у одного приёма.
#
# Ротатор выбирает приём ПО НОМЕРУ. Приёмы без номера не принадлежат ни одному
# плечу, и ротатор не применяет НИЧЕГО: строка синтаксически верна, движок
# молчит, обхода нет. Инструмент подбора отдаёт приёмы без номеров — ему номера
# не нужны, он их применяет сам, — поэтому склейка обязана их проставить.
#
# Поле 2026-09-01, bdsmx.tube: приём, подобранный инструментом, открывал сайт
# (200, 75624 байта, 3 из 3), та же строка под ротатором без номеров давала RST
# на ClientHello (0 из 4), она же с :strategy=1 — снова 200 (4 из 4).
_strategy_tag_arms() {
    awk '{
        has_circ = 0; has_num = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^--lua-desync=circular/) { has_circ = 1; continue }
            if ($i ~ /^--lua-desync=/ && $i ~ /:strategy=/) has_num = 1
        }
        if (!has_circ || has_num) { print; next }
        out = ""
        for (i = 1; i <= NF; i++) {
            t = $i
            if (t ~ /^--lua-desync=/ && t !~ /^--lua-desync=circular/) t = t ":strategy=1"
            out = out (out == "" ? "" : " ") t
        }
        print out
    }'
}

strategy_complete_line() {
    local pool="$1" body src skel joined raw
    body=$(cat)

    case "$body" in
        *--filter-*)     printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
        *--lua-desync=*) ;;
        *)               printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
    esac

    # Каркас берём из ТЕКУЩЕЙ строки пула, если она есть, и только иначе из
    # поставляемой. Иначе своя настройка человека — другие порты, другое окно —
    # молча пропадала бы при каждой вставке нового приёма: он-то менял приём, а
    # получал сброс всего остального к заводскому.
    src="$CUSTOM_STRAT_DIR/$pool.txt"
    if [ ! -s "$src" ]; then
        if ! src=$(_strategy_pool_source "$pool"); then
            # Пул без шипованного файла: каркас берём из работающего конфига.
            raw=$(_strategy_pool_skeleton_from_config "$pool") || {
                printf '%s\n' "$body" | _strategy_tag_arms; return 0; }
            # Временный файл вместо trap RETURN: тот в POSIX sh не определён,
            # а на BusyBox ash ведёт себя непредсказуемо. Удаляем явно ниже, на
            # каждом выходе из функции.
            src="/tmp/z2k-skel.$$"
            printf '%s\n' "$raw" > "$src"
        fi
    fi
    [ -s "$src" ] || { rm -f "/tmp/z2k-skel.$$"; printf '%s\n' "$body" | _strategy_tag_arms; return 0; }

    # Каркас: всё до ПЕРВОГО приёма. circular остаётся, он часть каркаса.
    skel=$(awk '{ sub(/\r$/,""); sub(/^[[:space:]]*#.*$/,"") } NF { printf "%s ", $0 }' "$src" \
        | awk '{ out=""
                 for (i = 1; i <= NF; i++) {
                     if ($i ~ /^--lua-desync=/ && $i !~ /^--lua-desync=circular/) break
                     out = out (out == "" ? "" : " ") $i
                 }
                 print out }')
    case "$skel" in
        *--lua-desync=circular*) ;;
        *) rm -f "/tmp/z2k-skel.$$"; printf '%s\n' "$body" | _strategy_tag_arms; return 0 ;;
    esac

    # Тело человека приводим к одной строке: инструмент отдаёт одну, но из чата
    # приходит и с переносами.
    joined=$(printf '%s\n' "$body" | awk '{ sub(/\r$/,"") } NF { printf "%s ", $0 }' | sed 's/[[:space:]]*$//')
    rm -f "/tmp/z2k-skel.$$"
    printf '%s %s\n' "$skel" "$joined" | _strategy_tag_arms
}

# strategy_validate — the load-bearing part of this feature.
#
# One typo takes down nfqws2 ENTIRELY, not just the pool it was written for:
# the daemon parses all profiles as one option string and refuses to start if
# any of it is wrong. So a candidate is never applied on trust.
#
# Validation runs against the WHOLE generated option string with the candidate
# in place, not against the fragment alone — a line can be fine by itself and
# still break the result (duplicate separators, a filter that swallows the next
# profile). The engine's own --dry-run is the oracle: rc 0 = parses, rc 1 = does
# not. Verified on hardware, including that a bad --lua-desync name fails it.
#
# Живой $CUSTOM_STRAT_DIR/<pool>.txt не пишется НИ РАЗУ: генерация идёт в
# теневом дереве (_strategy_shadow_build). Класть кандидата в боевой файл «на
# время проверки» нельзя — убитый между записью и откатом CGI оставлял битую
# строку живой, параллельный toggle успевал запечь её в NFQWS2_OPT, а два
# одновременных validate одного пула снимали кандидата друг друга как «прежнее
# состояние», и откат уезжал навсегда.
#
# stdin: candidate text. $1: pool. Echoes the engine's complaint on failure.
# Символы, которые превращают строку стратегии в команду.
#
# ПРОВЕРЕНО ЭКСПЕРИМЕНТОМ 2026-08-08, это не теория. Тело пула попадает в конфиг
# как  NFQWS2_OPT="<тело>"  (config_official.sh), а конфиг сорсится root-овым
# init-скриптом. Одна кавычка внутри тела закрывает присваивание, и всё, что за
# ней, исполняется:
#
#     --dpi-desync=fake " ; touch /tmp/PWNED ; : "
#
# даёт в конфиге строку, после сорсинга которой файл /tmp/PWNED создан. Обратите
# внимание: отдельная строка из кавычки не нужна — z2k_custom_strategy склеивает
# тело в ОДНУ строку, и кавычка работает из середины.
#
# Внутри двойных кавычек шелл раскрывает ещё обратные кавычки и $(...), поэтому
# запрещены и они. Отказ, а не экранирование: у этих символов нет законного
# применения в опциях nfqws2, а экранирование пришлось бы держать в согласии с
# генератором конфига вечно.
#
# Полагаться на строгость `nfqws2 --dry-run` здесь нельзя: чужой парсер не может
# быть границей безопасности, и достаточно одной опции, принимающей произвольную
# строку, чтобы проверка перестала ловить.
_strategy_body_is_safe() {
    # LC_ALL=C — иначе классы символов зависят от локали.
    if LC_ALL=C grep -q '["`$]' "$1" 2>/dev/null; then
        return 1
    fi
    # Управляющие байты (в т.ч. \0 и перевод строки в неожиданных местах)
    if LC_ALL=C grep -q '[[:cntrl:]]' "$1" 2>/dev/null; then
        return 1
    fi
    return 0
}

strategy_validate() {
    local pool="$1"
    strategy_pool_ok "$pool" || { echo "unknown pool"; return 1; }

    local engine="${Z2K_NFQWS2:-$ZAPRET2_DIR/nfq2/nfqws2}"
    [ -x "$engine" ] || { echo "движок не найден: $engine"; return 1; }

    local shadow="/tmp/z2k-strat-shadow.$$"
    # Своя тень (PID мог быть переиспользован) — и заодно чужие, брошенные
    # убитым CGI: проверка стратегии задачу не заводит, и без этого вызова
    # осиротевшие тени не подчистил бы никто.
    rm -rf "$shadow" 2>/dev/null
    _tmp_reap_orphans
    _strategy_shadow_build "$shadow" "$pool" || {
        rm -rf "$shadow" 2>/dev/null
        echo "не удалось подготовить каталог для проверки"
        return 1
    }

    local cand="$shadow/lists/custom-strategies/$pool.txt"
    # Достраиваем ЗДЕСЬ, а не у вызывающего: проверка и сохранение обязаны
    # видеть одну и ту же строку, иначе «Проверить» скажет одно, а применится
    # другое.
    strategy_complete_line "$pool" > "$cand" || {
        rm -rf "$shadow" 2>/dev/null
        echo "не удалось записать кандидата"
        return 1
    }

    # Опасные символы отсекаем ПЕРВЫМИ — до генерации конфига и до dry-run.
    # Дальше по цепочке тело попадает в NFQWS2_OPT="…", который сорсится root'ом,
    # и там кавычка уже не текст, а конец присваивания.
    if ! _strategy_body_is_safe "$cand"; then
        rm -rf "$shadow" 2>/dev/null
        echo 'в строке стратегии недопустимы символы " ` $ и управляющие: они превращают её в команду'
        return 1
    fi

    # Строка без единой опции (пусто или одни комментарии) — не «прошедшая
    # проверку стратегия»: генератор такой файл пропускает и собирает конфиг из
    # штатной Strategy.txt, dry-run одобряет ЕЁ, а человек получает карточку
    # «своя стратегия» поверх работающей штатной с ротацией.
    if ! _strategy_body_has_options "$cand"; then
        rm -rf "$shadow" 2>/dev/null
        echo "пустая стратегия: нет ни одной строки с опциями (комментарии не в счёт)"
        return 1
    fi

    local tmpcfg="/tmp/z2k-strategy-check.$$"
    local rc=0 opt="" err=""
    if ( ZAPRET2_DIR="$shadow"; Z2K_EXTRA_STRATEGIES_RUNTIME="$shadow/lists/custom-strategies";
         export ZAPRET2_DIR Z2K_EXTRA_STRATEGIES_RUNTIME; regenerate_config_to "$tmpcfg" ); then
        opt=$(sed -n '/^NFQWS2_OPT="/,/^"$/{ /^NFQWS2_OPT="/d; /^"$/d; p; }' "$tmpcfg")
    else
        rc=1; err="не удалось собрать конфиг с этой строкой"
    fi

    if [ "$rc" = 0 ]; then
        if [ -z "$opt" ]; then
            rc=1; err="в собранном конфиге пустые опции nfqws2"
        else
            # --qnum ОБЯЗАТЕЛЕН, и его нет в NFQWS2_OPT: номер очереди
            # подставляет init при запуске, а в конфиг он не пишется. Без него
            # движок отвечает «Need queue number» на ЛЮБУЮ строку — то есть
            # проверка отвергала и заведомо исправные, включая поставляемые
            # пуловые (проверено на роутере 31.08.2026). Номер здесь любой:
            # при --dry-run движок разбирает опции и ничего не занимает.
            # shellcheck disable=SC2086
            err=$("$engine" --dry-run --qnum=200 $opt 2>&1) || rc=1
        fi
    fi

    rm -f "$tmpcfg"
    rm -rf "$shadow" 2>/dev/null

    [ "$rc" = 0 ] || { printf '%s\n' "$err" | tail -3; return 1; }
    return 0
}

# Теневая копия $ZAPRET2_DIR для проверки кандидата: верхний уровень —
# симлинки на всё, кроме lists; вместо lists настоящий каталог с симлинками на
# всё, кроме custom-strategies; вместо custom-strategies настоящий каталог с
# симлинками на чужие пулы. Проверяемый пул кладёт уже вызывающий — реальным
# файлом, поверх которого ничего не симлинчено.
#
# Подсунуть генератору пустой каталог НЕЛЬЗЯ: lib/config_official.sh берёт из
# ZAPRET2_DIR не только custom-strategies, но и config (флаги), extra_strats и
# lists — на пустом дереве проверялась бы не та строка опций, что соберётся в бою.
# Симлинк не создался — честный отказ; тихо вернуться к записи в живой файл
# значит вернуть ровно тот баг, ради которого всё это и сделано.
_strategy_shadow_build() {
    local root="$1" pool="$2" f base
    mkdir -p "$root/lists/custom-strategies" 2>/dev/null || return 1
    for f in "$ZAPRET2_DIR"/* "$ZAPRET2_DIR"/.[!.]*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        [ "$base" = "lists" ] && continue
        ln -s "$f" "$root/$base" 2>/dev/null || return 1
    done
    for f in "$ZAPRET2_DIR/lists"/* "$ZAPRET2_DIR/lists"/.[!.]*; do
        [ -e "$f" ] || continue
        base=${f##*/}
        [ "$base" = "custom-strategies" ] && continue
        ln -s "$f" "$root/lists/$base" 2>/dev/null || return 1
    done
    for f in "$CUSTOM_STRAT_DIR"/*.txt; do
        [ -f "$f" ] || continue
        base=${f##*/}
        [ "$base" = "$pool.txt" ] && continue
        ln -s "$f" "$root/lists/custom-strategies/$base" 2>/dev/null || return 1
    done
    return 0
}

# Есть ли в файле хоть одна строка с опциями. Отбрасываем ровно то же, что
# отбрасывает z2k_custom_strategy в lib/config_official.sh (комментарии и пустые
# строки), иначе «проверка прошла» и «генератор это увидит» разъедутся.
_strategy_body_has_options() {
    awk '{ sub(/\r$/, ""); sub(/^[[:space:]]*#.*$/, "") } NF { found = 1; exit } END { exit (found ? 0 : 1) }' "$1"
}

# Same as regenerate_config but writes somewhere else — used by the check above
# so a candidate is never able to overwrite the config the router is running on.
regenerate_config_to() {
    local dest="$1"
    _gen_libs_source || return 1
    create_official_config "$dest" >/dev/null 2>&1
}

strategy_pool_read() {
    strategy_pool_ok "$1" || return 1
    [ -f "$CUSTOM_STRAT_DIR/$1.txt" ] || return 2
    cat "$CUSTOM_STRAT_DIR/$1.txt"
}

# Serialize all pool mutations so a manual save/reset cannot interleave with
# the four-pool transaction while it validates or regenerates config.
strategy_config_lock_acquire() {
    local dir="${STRATEGY_CONFIG_LOCK:-/tmp/z2k-strategy-config.lock}" n=0 owner
    while ! mkdir "$dir" 2>/dev/null; do
        owner=$(cat "$dir/pid" 2>/dev/null)
        if [ -n "$(find "$dir" -maxdepth 0 -mmin +5 2>/dev/null)" ] &&
           { [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; }; then
            rm -rf "$dir" 2>/dev/null
            continue
        fi
        n=$((n + 1)); [ "$n" -le 10 ] || return 1
        usleep 20000 2>/dev/null || sleep 1
    done
    printf '%s\n' "$$" > "$dir/pid"
    STRATEGY_CONFIG_LOCK_HELD="$dir"
    return 0
}

strategy_config_lock_release() {
    local dir="${STRATEGY_CONFIG_LOCK_HELD:-${STRATEGY_CONFIG_LOCK:-/tmp/z2k-strategy-config.lock}}" owner
    owner=$(cat "$dir/pid" 2>/dev/null)
    [ "$owner" = "$$" ] && rm -rf "$dir" 2>/dev/null
    STRATEGY_CONFIG_LOCK_HELD=
}

_strategy_pool_restore_batch() {
    local live_dir="$1" txn="$2" pool tmp had rc=0
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        tmp="$live_dir/.$pool.txt.rollback.$$"
        if [ -f "$txn/backup/$pool.present" ]; then
            cp -p "$txn/backup/$pool.txt" "$tmp" && mv -f "$tmp" "$live_dir/$pool.txt" || rc=1
        else
            rm -f "$live_dir/$pool.txt" || rc=1
        fi
        rm -f "$tmp"
    done
    tmp="$CONFIG_FILE.z2k-rollback.$$"
    if [ -f "$txn/backup/config.present" ]; then
        cp -p "$txn/backup/config" "$tmp" && mv -f "$tmp" "$CONFIG_FILE" || rc=1
    else
        rm -f "$CONFIG_FILE" || rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

_strategy_pool_save_batch_locked() {
    local staged="$1" txn="$2" live_dir="$CUSTOM_STRAT_DIR" original_dir="$CUSTOM_STRAT_DIR"
    local pool f base tmp
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        [ -s "$staged/$pool.txt" ] || { echo "нет кандидатной строки для $pool" >&2; return 1; }
    done
    mkdir -p "$txn/backup" "$txn/candidate-custom" "$live_dir" || return 1

    # Validate every proposed pool against a shadow containing all four new
    # lines plus every unrelated custom pool currently on the router.
    for f in "$live_dir"/*.txt; do
        [ -f "$f" ] || continue
        base=${f##*/}; pool=${base%.txt}
        case "$pool" in yt_tcp|gv_tcp|quic|rkn_tcp) continue ;; esac
        cp -p "$f" "$txn/candidate-custom/$base" || return 1
    done
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        cp "$staged/$pool.txt" "$txn/candidate-custom/$pool.txt" || return 1
    done
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        CUSTOM_STRAT_DIR="$txn/candidate-custom"
        if ! strategy_validate "$pool" < "$txn/candidate-custom/$pool.txt"; then
            CUSTOM_STRAT_DIR="$original_dir"
            echo "общая проверка набора отклонила пул $pool" >&2
            return 1
        fi
    done
    CUSTOM_STRAT_DIR="$original_dir"

    # Snapshot every target and the generated config before the first write.
    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        if [ -f "$live_dir/$pool.txt" ]; then
            cp -p "$live_dir/$pool.txt" "$txn/backup/$pool.txt" || return 1
            : > "$txn/backup/$pool.present"
        fi
    done
    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$txn/backup/config" || return 1
        : > "$txn/backup/config.present"
    fi

    for pool in yt_tcp gv_tcp quic rkn_tcp; do
        tmp="$live_dir/.$pool.txt.unique.$$"
        cp "$staged/$pool.txt" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$live_dir/$pool.txt" || {
            rm -f "$tmp"
            if _strategy_pool_restore_batch "$live_dir" "$txn"; then
                echo "не удалось установить пул $pool; старые файлы восстановлены" >&2
            else
                echo "ОШИБКА: не удалось полностью восстановить файлы после сбоя записи $pool" >&2
            fi
            return 1
        }
    done

    if ! regenerate_config; then
        _strategy_pool_restore_batch "$live_dir" "$txn" || echo "ОШИБКА: восстановление config не удалось" >&2
        echo "не удалось регенерировать config; старые файлы восстановлены" >&2
        return 1
    fi

    if is_running; then
        ensure_init_exec
        if ! "$INIT_SCRIPT" restart 2>&1; then
            _strategy_pool_restore_batch "$live_dir" "$txn" || echo "ОШИБКА: восстановление файлов не удалось" >&2
            ensure_init_exec
            "$INIT_SCRIPT" restart 2>&1 || echo "ОШИБКА: сервис не поднялся на восстановленном config" >&2
            echo "перезапуск с новым набором не удался; выполнен откат" >&2
            return 1
        fi
        echo "Сервис перезапущен один раз с новым набором."
    else
        echo "Сервис остановлен: пулы и config сохранены, запусти сервис для применения."
    fi
    return 0
}

strategy_pool_save_batch() {
    local staged="$1" txn="$2" rc
    strategy_config_lock_acquire || { echo "не удалось захватить блокировку стратегий" >&2; return 1; }
    _strategy_pool_save_batch_locked "$staged" "$txn"
    rc=$?
    strategy_config_lock_release
    return "$rc"
}

# Save only what validates. A rejected line leaves the previous state exactly as
# it was — silently falling back to the shipped strategy would leave the user
# convinced their own is running.
_strategy_pool_save_locked() {
    local pool="$1" body
    strategy_pool_ok "$pool" || { echo "unknown pool" >&2; return 1; }
    body=$(strategy_complete_line "$pool")
    printf '%s\n' "$body" | strategy_validate "$pool" >"/tmp/z2k-strategy-err.$$" 2>&1 || {
        cat "/tmp/z2k-strategy-err.$$" >&2; rm -f "/tmp/z2k-strategy-err.$$"; return 1; }
    rm -f "/tmp/z2k-strategy-err.$$"
    mkdir -p "$CUSTOM_STRAT_DIR" 2>/dev/null || return 1
    printf '%s\n' "$body" > "$CUSTOM_STRAT_DIR/$pool.txt" || return 1
    chmod 644 "$CUSTOM_STRAT_DIR/$pool.txt" 2>/dev/null
    regenerate_config || return 1
    # nfqws2 gets NFQWS2_OPT as argv at startup and never re-reads it, so a
    # regenerated config alone changes nothing that is running. Without this the
    # panel says «применена» while the daemon keeps the previous strategy — the
    # exact «переключил, а не применилось» the toggle handlers were fixed for.
    restart_service_if_running
    return 0
}

strategy_pool_save() {
    local rc
    strategy_config_lock_acquire || { echo "не удалось захватить блокировку стратегий" >&2; return 1; }
    _strategy_pool_save_locked "$1"
    rc=$?
    strategy_config_lock_release
    return "$rc"
}

_strategy_pool_reset_locked() {
    strategy_pool_ok "$1" || { echo "unknown pool" >&2; return 1; }
    rm -f "$CUSTOM_STRAT_DIR/$1.txt" || return 1
    regenerate_config || return 1
    restart_service_if_running
    return 0
}

strategy_pool_reset() {
    local rc
    strategy_config_lock_acquire || { echo "не удалось захватить блокировку стратегий" >&2; return 1; }
    _strategy_pool_reset_locked "$1"
    rc=$?
    strategy_config_lock_release
    return "$rc"
}

_strategy_pool_restore_all() {
    local txn="$1" pool live_dir="$CUSTOM_STRAT_DIR" tmp rc=0
    mkdir -p "$live_dir" 2>/dev/null || return 1
    for pool in $STRATEGY_POOLS; do
        tmp="$live_dir/.$pool.txt.rollback.$$"
        if [ -f "$txn/backup/$pool.present" ]; then
            cp -p "$txn/backup/$pool.txt" "$tmp" && mv -f "$tmp" "$live_dir/$pool.txt" || rc=1
        else
            rm -f "$live_dir/$pool.txt" || rc=1
        fi
        rm -f "$tmp"
    done
    tmp="$CONFIG_FILE.z2k-rollback.$$"
    if [ -f "$txn/backup/config.present" ]; then
        cp -p "$txn/backup/config" "$tmp" && mv -f "$tmp" "$CONFIG_FILE" || rc=1
    else
        rm -f "$CONFIG_FILE" || rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

_strategy_pool_reset_all_locked() {
    local txn="$1" pool found=0 live_dir="$CUSTOM_STRAT_DIR"
    mkdir -p "$txn/backup" "$live_dir" || return 1
    for pool in $STRATEGY_POOLS; do
        if [ -f "$live_dir/$pool.txt" ]; then
            found=1
            cp -p "$live_dir/$pool.txt" "$txn/backup/$pool.txt" || return 1
            : > "$txn/backup/$pool.present"
        fi
    done
    [ "$found" = 1 ] || { echo "Все категории уже работают на автоматике."; return 0; }
    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$txn/backup/config" || return 1
        : > "$txn/backup/config.present"
    fi

    for pool in $STRATEGY_POOLS; do
        rm -f "$live_dir/$pool.txt" || {
            if ! _strategy_pool_restore_all "$txn"; then
                STRATEGY_RESET_RECOVERY_REQUIRED=1
                echo "ОШИБКА: восстановление пулов после сбоя удаления не удалось" >&2
            fi
            return 1
        }
    done
    if ! regenerate_config; then
        if ! _strategy_pool_restore_all "$txn"; then
            STRATEGY_RESET_RECOVERY_REQUIRED=1
            echo "ОШИБКА: восстановление пулов и конфига после ошибки генерации не удалось" >&2
        else
            echo "не удалось пересобрать конфиг; пользовательские стратегии восстановлены" >&2
        fi
        return 1
    fi

    if is_running; then
        ensure_init_exec
        if ! "$INIT_SCRIPT" restart 2>&1; then
            if ! _strategy_pool_restore_all "$txn"; then
                STRATEGY_RESET_RECOVERY_REQUIRED=1
                echo "ОШИБКА: восстановление пулов после ошибки перезапуска не удалось" >&2
            else
                echo "перезапуск на автоматике не удался; прежние стратегии восстановлены" >&2
            fi
            ensure_init_exec
            "$INIT_SCRIPT" restart 2>&1 || echo "ОШИБКА: сервис не поднялся на восстановленном конфиге" >&2
            return 1
        fi
        echo "Все категории возвращены на автоматику; сервис перезапущен один раз."
    else
        echo "Все категории возвращены на автоматику; сервис остановлен, запуск не требовался."
    fi
    return 0
}

strategy_pool_reset_all() {
    local txn rc
    strategy_config_lock_acquire || { echo "не удалось захватить блокировку стратегий" >&2; return 1; }
    STRATEGY_RESET_RECOVERY_REQUIRED=0
    txn=$(mktemp -d /tmp/z2k-strategy-reset-all.XXXXXX) || {
        strategy_config_lock_release
        echo "не удалось создать резервную копию стратегий" >&2
        return 1
    }
    _strategy_pool_reset_all_locked "$txn"
    rc=$?
    strategy_config_lock_release
    if [ "$rc" = 0 ]; then
        rm -rf "$txn"
    elif [ "$STRATEGY_RESET_RECOVERY_REQUIRED" != 1 ]; then
        rm -rf "$txn"
    fi
    return "$rc"
}

restart_service_if_running() {
    if is_running; then
        # Output goes to caller's stdout/stderr — svc_action_async
        # tees those into the job log so UI shows live progress.
        # Failure PROPAGATES (fail-closed audit): callers gate their "Готово"
        # on it. Stopped service stays rc 0 (nothing required, skip message).
        ensure_init_exec
        "$INIT_SCRIPT" restart 2>&1 || return 1
        # Health verification: restart rc 0 but no process = false success
        # (same class as the OW exit=127 lesson — job must not say success).
        is_running || { echo "restart rc 0, но сервис не жив" >&2; return 1; }
    else
        echo "Сервис не запущен — пропускаю restart"
    fi
}

# --- service control ---
# Output не silenced — caller (svc_action_async) подхватывает stdout/stderr
# и пишет в job-log для UI live-polling'а.

# Self-heal the init script's executable bit before invoking it. p-42 shipped
# S99zapret2 via the patch path, which could drop +x on some BusyBox builds
# ("/opt/etc/init.d/S99zapret2: Permission denied", rc 126) — chmod here so a
# webpanel start/stop/restart recovers even on a router not yet reinstalled.
# Эти три обёртки были мертвы, а /service/start|stop|restart в api.sh дёргал
# "$INIT_SCRIPT" напрямую — то есть ровно на том пути, ради которого писался
# self-heal, chmod не выполнялся, и обещание r-43 не работало. Эндпоинты
# переведены на обёртки; вызывать init-скрипт напрямую отсюда больше не нужно.
ensure_init_exec() { [ -f "$INIT_SCRIPT" ] && chmod +x "$INIT_SCRIPT" 2>/dev/null; return 0; }
svc_start() {
    local rc
    job_progress "Запускаю init-службу nfqws2"
    ensure_init_exec
    "$INIT_SCRIPT" start 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
        if is_running; then job_progress "Проверка: процесс nfqws2 запущен"
        else job_progress "Команда запуска завершилась успешно; процесс nfqws2 пока не подтверждён"
        fi
    else
        job_progress "Ошибка запуска nfqws2: init-служба вернула код $rc"
    fi
    return "$rc"
}
svc_stop() {
    local rc
    job_progress "Останавливаю init-службу nfqws2"
    ensure_init_exec
    "$INIT_SCRIPT" stop 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
        if is_running; then job_progress "Команда остановки завершилась; процесс nfqws2 всё ещё обнаруживается"
        else job_progress "Проверка: процесс nfqws2 остановлен"
        fi
    else
        job_progress "Ошибка остановки nfqws2: init-служба вернула код $rc"
    fi
    return "$rc"
}
svc_restart() {
    local rc
    job_progress "Перезапускаю init-службу nfqws2"
    ensure_init_exec
    "$INIT_SCRIPT" restart 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
        if is_running; then job_progress "Проверка: после перезапуска процесс nfqws2 запущен"
        else job_progress "Команда перезапуска завершилась успешно; процесс nfqws2 пока не подтверждён"
        fi
    else
        job_progress "Ошибка перезапуска nfqws2: init-служба вернула код $rc"
    fi
    return "$rc"
}

# Убрать файлы прошлых задач. Каждый запуск задачи из панели оставляет в /tmp
# три файла (.log, .pid, .exit), и до 2026-08-04 их не удалял никто: на роутере
# владельца накопилось 11 штук от четырёх запусков, два лога по 30 КБ. Само по
# себе немного, но /tmp это tmpfs, то есть ОПЕРАТИВКА, и растёт этот мусор
# только вверх до перезагрузки.
#
# Час, а не «всё кроме текущей»: панель после перезагрузки страницы теряет
# job_id и может запросить лог недавней задачи по прямой ссылке, а обновление
# идёт минуты. Час покрывает это с запасом и при этом не копит.
#
# -mmin и -delete у busybox find на роутере есть (проверено), но на всякий
# случай без -delete есть запасной путь: отсутствие find не должно ронять
# запуск задачи.
job_reap() {
    # Сносим только ЗАВЕРШЁННЫЕ задачи. Прежняя версия удаляла всё старше часа
    # без разбора, включая .pid работающей задачи: job_status тогда отвечает
    # "unknown", поллер панели крутится вечно, глобальный UI-лок не снимается, а
    # модалка «Обновление идёт» всплывает при каждой перезагрузке вкладки —
    # то есть уборка мусора ломала живое обновление. Установка на медленном
    # роутере через час не укладывается запросто.
    #
    # Признак завершения — файл .exit (его пишут оба создателя задач по выходу).
    # Если его нет, проверяем, жив ли процесс: не жив — задача умерла и её тоже
    # можно убрать.
    local f id pid
    for f in "$Z2K_JOB_DIR"/z2k-job-*.log; do
        [ -f "$f" ] || continue
        id=${f##*/}; id=${id#z2k-job-}; id=${id%.log}
        # моложе часа — не трогаем в любом случае
        find "$f" -maxdepth 0 -mmin +60 >/dev/null 2>&1 || continue
        if [ ! -f "$(_z2k_job_file "$id" exit)" ]; then
            pid=$(cat "$(_z2k_job_file "$id" pid)" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                continue    # задача ещё идёт — не трогаем
            fi
        fi
        rm -f "$(_z2k_job_file "$id" log)" "$(_z2k_job_file "$id" pid)" \
            "$(_z2k_job_file "$id" exit)" "$(_z2k_job_file "$id" cancel)" \
            "$(_z2k_job_file "$id" child)" 2>/dev/null
    done
    _tmp_reap_orphans
    return 0
}

# Осиротевший скретч в /tmp. Свой каталог/файл каждый обработчик сносит сам, но
# CGI, убитый lighttpd'ом на таймауте или ушедший вместе с перезапуском сервера,
# уносит уборку с собой, а очистка «по своему $$» в начале обработчика спасает
# только при совпадении PID. /tmp на роутере — tmpfs, то есть ОПЕРАТИВКА, и
# растёт этот мусор только вверх до перезагрузки (ради этого писался job_reap).
#
# Час — та же мера, что и для задач: заведомо дольше любой проверки стратегии и
# любой проверки обновлений, то есть живое не задеваем.
_tmp_reap_orphans() {
    local f
    for f in /tmp/z2k-strat-shadow.* /tmp/z2k-strategy-check.* /tmp/z2k-strategy-err.* \
             /tmp/z2k-strategy-pick-* \
             /tmp/z2k-warp-license.* /tmp/z2k-state-bulk.* /tmp/z2k-bulk-err.* \
             "${AU_MANIFEST_CACHE:-/tmp/z2k-au-manifest.json}".new.*; do
        [ -e "$f" ] || continue
        # Проверять надо ВЫВОД find, а не его код возврата: несовпадение по
        # -mmin это не ошибка, find печатает пустоту и выходит с нулём. На коде
        # возврата уборщик сносил свежие скретчи — в том числе файл, в который
        # соседний обработчик прямо сейчас пишет сообщение об ошибке.
        [ -n "$(find "$f" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue
        rm -rf "$f" 2>/dev/null
    done
    return 0
}

# --- async job launcher ---
#
# Запускает любую shell-команду в фоне с tee всех её stdout/stderr в
# /tmp/z2k-job-<id>.log (тот же путь который job_log endpoint раздаёт).
# Возвращает job_id. Frontend получает id, открывает openJobModal с
# live-polling /job?id=...
#
# Закрытие stdin/stdout/stderr (</dev/null >/dev/null 2>&1 на subshell)
# критично — без этого lighttpd не финализирует HTTP-ответ пока хоть
# один наследник держит fd 1/2. Внутреннее `>> log 2>&1` уже после
# наследования /dev/null заменяет fd на лог.
#
# Использование:
#   job_id=$(svc_action_async "Перезапуск се…35516 tokens truncated…2K_ROOT}/platform/openwrt/manifest.sh" || exit 1
            z2k_ow_manifest_verify_signature "$manifest" "$signature"
        else
            au_manifest_verify "$manifest" "$signature"
        fi
    )
}
# Чем тянули манифест в последний раз: mirrors | curl | пусто (не пробовали).
# Для api.sh — единственный способ показать деградацию: stderr обработчиков он
# уводит в /dev/null.
update_manifest_source() {
    [ -f "$AU_MANIFEST_SOURCE_FILE" ] || { printf ''; return 0; }
    head -1 "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null | tr -d ' \r\n'
}

# Манифест тянем той же z2k_fetch, что и весь проект (VPS-хоп -> raw -> jsdelivr
# -> gh-proxy -> ndmc-DNS), а не голым curl'ом на raw.githubusercontent: у
# ЦЕЛЕВОЙ аудитории проекта raw заблокирован, и панель показывала «обновлений
# нет» ровно там, где ночной апдейтер их прекрасно видит.
#
# utils.sh подключаем в ПОДоболочке: он безусловно переприсваивает
# ZAPRET2_DIR и соседей, а stdout здесь — тело HTTP-ответа CGI, туда не должно
# попасть ни байта постороннего.
_update_fetch_manifest() {
    local url="$1" dest="$2" utils="" d pid rc flag waited=0
    for d in "$ZAPRET2_DIR/lib" /tmp/z2k/lib; do
        [ -f "$d/utils.sh" ] && [ -z "$utils" ] && utils="$d/utils.sh"
    done
    if [ -z "$utils" ]; then
        printf 'curl\n' > "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null
        echo "lib/utils.sh не найден: проверка обновлений идёт голым curl'ом мимо зеркал — на сети, где raw.githubusercontent заблокирован, панель будет уверять, что обновлений нет" >&2
        curl -fsSL --max-time 15 "$url" -o "$dest" 2>/dev/null
        return $?
    fi
    printf 'mirrors\n' > "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null
    # Забег по зеркалам сам себя по времени не ограничивает, а мы синхронный CGI,
    # поэтому держим его на своём поводке: фоновый процесс + опрос маркера.
    # Маркер, а не `kill -0`: завершившийся, но ещё не собранный wait'ом ребёнок
    # остаётся зомби, и kill -0 по нему успешен — ждали бы полный таймаут даже
    # после мгновенной удачи. Код возврата кладём в маркер целиком собранным
    # (mv), чтобы не прочитать пустой файл на полпути.
    flag="${dest}.done.$$"
    rm -f "$flag" "$flag.part"
    # shellcheck disable=SC1090
    ( . "$utils"; z2k_fetch "$url" "$dest"; printf '%s' "$?" > "$flag.part"; mv -f "$flag.part" "$flag" ) \
        </dev/null >/dev/null 2>&1 &
    pid=$!
    while [ ! -f "$flag" ] && [ "$waited" -lt "$AU_MANIFEST_FETCH_TIMEOUT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -f "$flag" ]; then
        rc=$(cat "$flag" 2>/dev/null)
        case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    else
        _kill_tree "$pid"
        rc=1
    fi
    wait "$pid" 2>/dev/null
    rm -f "$flag" "$flag.part"
    return "$rc"
}

_kill_tree() {
    # Убить процесс вместе с прямыми потомками. Одного kill по $! мало: curl —
    # отдельный процесс, он переживает смерть подоболочки, ещё до трёх минут
    # держит соединение и в конце кладёт скачанное в наш temp, когда отказ уже
    # засчитан. PPID читаем из /proc: у busybox ps нет -o ppid, а pkill -P нет
    # вовсе. `read` — встроенная команда, обхода /proc она не удорожает.
    local pid="$1" p line rest kid
    for p in /proc/[0-9]*; do
        [ -r "$p/stat" ] || continue
        kid=${p#/proc/}
        read -r line < "$p/stat" 2>/dev/null || continue
        rest=${line#*") "}      # после имени процесса в скобках идут state ppid ...
        rest=${rest#* }
        [ "${rest%% *}" = "$pid" ] && kill -TERM "$kid" 2>/dev/null
    done
    kill -TERM "$pid" 2>/dev/null
    return 0
}

# Похоже ли скачанное на UPDATES.json. Прежняя проверка [ -s ] принимала любое
# непустое тело — HTML-заглушку провайдера, страницу ошибки зеркала — и дальше
# это кэшировалось на 5 минут и разбиралось как манифест.
_update_manifest_sane() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -c 1 "$f" 2>/dev/null | grep -q '{' || return 1
    grep -q '"current"[[:space:]]*:[[:space:]]*"' "$f" 2>/dev/null || return 1
    grep -q '"history"[[:space:]]*:' "$f" 2>/dev/null || return 1
    return 0
}

update_manifest_current() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf ''; return; }
    sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AU_MANIFEST_CACHE" | head -1
}

update_manifest_seq() {
    [ -s "$AU_MANIFEST_CACHE" ] || return 1
    awk '
        match($0, /"seq"[[:space:]]*:[[:space:]]*[0-9]+/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/.*:[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$AU_MANIFEST_CACHE" | awk '/^[1-9][0-9]*$/ { print; found=1; exit } END { if (!found) exit 1 }'
}

# Compare validated decimal release sequences without shell integer overflow.
# Prefixing with a non-digit keeps awk's comparison lexicographic; decimal
# strings are ordered by length first, then by their digits.
update_seq_compare() {
    local _installed="$1" _controlled="$2"
    case "$_installed" in ''|*[!0-9]*) return 1 ;; esac
    case "$_controlled" in ''|*[!0-9]*) return 1 ;; esac
    LC_ALL=C awk -v installed="$_installed" -v controlled="$_controlled" 'BEGIN {
        a = "x" installed
        b = "x" controlled
        if (length(installed) < length(controlled)) print -1
        else if (length(installed) > length(controlled)) print 1
        else if (a < b) print -1
        else if (a > b) print 1
        else print 0
    }'
}

# Count how many history entries appear AFTER installed_tag.
# Matches au_history_entries_after semantics in lib/auto_update.sh —
# history-order, not numeric.
update_behind_count() {
    local installed="$1"
    case "$installed" in ''|unknown)
        echo "installed release version is not registered" >&2
        return 1
        ;;
    esac
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            line = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            v = line
            if (found) { count++; next }
            if (v == inst) { found = 1 }
        }
        END {
            # A tag absent from the controlled history cannot be compared.
            # Returning zero here made valid-but-unknown state look current.
            if (!found) exit 1
            print count+0
        }
    ' "$AU_MANIFEST_CACHE"
}

update_last_check_ts() {
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '0'; return; }
    file_mtime "$AU_MANIFEST_CACHE"
}

# Провалилась ли ПОСЛЕДНЯЯ попытка сходить за манифестом.
#
# Это единственное, что отличает «вы на актуальной версии» от «канал обновлений
# мёртв, а мы показываем позавчерашний кэш». update_refresh_manifest при отказе
# сети возвращает 0 и оставляет протухший кэш (иначе панель мигала бы ошибкой
# на каждом чихе связи) — то есть по её коду возврата отличить нельзя. Зато она
# оставляет метку неудачи; до 2026-08-08 эту метку не читал никто, и наружу
# не уходило ни одного признака. Человек видел «установлена актуальная версия»
# при полностью нерабочем обновлении.
update_last_fetch_failed() {
    [ -f "$AU_MANIFEST_FAIL_STAMP" ] && printf 'true' || printf 'false'
}

# Возраст последней УДАЧНОЙ проверки в секундах; -1 если удачных не было.
update_last_check_age() {
    local ts now
    ts=$(update_last_check_ts)
    [ "${ts:-0}" -gt 0 ] 2>/dev/null || { printf '%s' "-1"; return; }
    now=$(date +%s 2>/dev/null || echo 0)
    [ "$now" -gt "$ts" ] 2>/dev/null && printf '%s' "$((now - ts))" || printf '0'
}

# Extract history entries strictly newer than installed_tag, in
# history-file order. Output is a JSON array — entries are emitted
# verbatim (each one is a single-line JSON object in UPDATES.json), no
# field re-serialization. Returns "[]" when installed is unknown or
# nothing is pending.
update_pending_entries() {
    local installed="$1"
    [ -s "$AU_MANIFEST_CACHE" ] || { printf '[]'; return; }
    if [ -z "$installed" ] || [ "$installed" = "unknown" ]; then
        printf '[]'
        return
    fi
    awk -v inst="$installed" '
        /"v"[[:space:]]*:[[:space:]]*"/ {
            v = $0
            sub(/.*"v"[[:space:]]*:[[:space:]]*"/, "", v)
            sub(/".*/, "", v)
            if (found) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                sub(/,$/, "", line)
                entries[++n] = line
                next
            }
            if (v == inst) { found = 1 }
        }
        END {
            printf "["
            for (i=1; i<=n; i++)
                printf "%s%s", (i>1?",":""), entries[i]
            printf "]"
        }
    ' "$AU_MANIFEST_CACHE"
}

# Extract history entries in reverse chronological order (newest first).
# Accepts offset and limit (defaults: 0, 20).
# Outputs JSON: {"ok":true,"total":<n>,"history":[...]}
#
# Note: Assumes one JSON entry per line in the history array, as produced by
# scripts/release.sh. Strips deliverable lists (changed_files, steps) to reduce payload.
update_history_entries() {
    local offset="${1:-0}"
    local limit="${2:-20}"
    local src=""
    # OpenWrt history is read only from the verified controlled cache. Never
    # expose payload/snapshot history when that cache is cold. Preserve the
    # legacy fallback chain byte-for-byte for Keenetic callers.
    if [ "${Z2K_PLATFORM:-keenetic}" = "openwrt" ]; then
        if [ -s "$AU_MANIFEST_CACHE" ] && [ "$(head -1 "${AU_MANIFEST_AUTHORITY_FILE:-${AU_MANIFEST_CACHE}.authority}" 2>/dev/null)" = "controlled" ]; then
            _history_candidates="$AU_MANIFEST_CACHE"
        else
            _history_candidates=""
        fi
    else
        _history_candidates="$AU_MANIFEST_CACHE
$ZAPRET2_DIR/UPDATES.json
/opt/zapret2/UPDATES.json"
    fi
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if [ -s "$cand" ]; then src="$cand"; break; fi
    done <<EOF
$_history_candidates
EOF
    [ -n "$src" ] || { printf '{"ok":true,"total":0,"history":[]}'; return; }
    awk -v off="$offset" -v lim="$limit" '
        /^[[:space:]]*\{[[:space:]]*"v"[[:space:]]*:/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            sub(/,$/, "", line)
            gsub(/"changed_files"[[:space:]]*:[[:space:]]*\[[^]]*\][[:space:]]*,?[[:space:]]*/, "", line)
            gsub(/"steps"[[:space:]]*:[[:space:]]*\[[^]]*\][[:space:]]*,?[[:space:]]*/, "", line)
            gsub(/"ref"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*/, "", line)
            gsub(/"full_install"[[:space:]]*:[[:space:]]*(true|false)[[:space:]]*,?[[:space:]]*/, "", line)
            sub(/,[[:space:]]*\}/, "}", line)
            entries[++n] = line
        }
        END {
            printf "{\"ok\":true,\"total\":%d,\"history\":[", n
            start = n - off
            end = start - lim + 1
            if (end < 1) end = 1
            count = 0
            for (i = start; i >= end; i--) {
                if (i < 1 || i > n) continue
                printf "%s%s", (count > 0 ? "," : ""), entries[i]
                count++
            }
            printf "]}"
        }
    ' "$src"
}

# Launch auto-update apply asynchronously, return job_id for /job?id=...
# polling. Output streams to /tmp/z2k-job-<id>.log so the UI can tail it via
# the existing job_log path. The real auto-update log at /opt/var/log/...
# is appended by au_log; we duplicate to the per-job temp log for the UI.
update_apply_async() {
    update_action_async apply
}

# Same single background-job mechanism for updates and user-requested reinstall.
update_reinstall_async() {
    update_action_async reinstall
}

update_action_async() {
    local action="${1:-apply}"
    local label="Обновление z2k"
    case "$action" in apply|reinstall) ;; *) return 2 ;; esac
    [ "$action" != reinstall ] || label="Переустановка z2k"
    [ -x "$AU_SCRIPT" ] || { echo "auto-update script missing: $AU_SCRIPT" >&2; return 1; }
    mkdir -p "$Z2K_JOB_DIR" || return 1
    job_reap
    local job_id
    job_id=$(date +%s)$$
    # Daemonize: close stdin and detach stdout/stderr from the CGI pipes.
    # Without `</dev/null >/dev/null 2>&1` on the subshell, the background
    # apply (and every grandchild like `curl`, `sh install`, `lighttpd`
    # restart) inherits fd 1/2 pointing at lighttpd's CGI response pipe.
    # lighttpd won't finalize the HTTP response until EVERY fd 1 holder
    # closes — which means apiPost hangs for the entire 1-2 min install,
    # the browser's confirm closes, and the modal never opens because
    # the response that carries job_id is still in flight. Innermost
    # `> log 2>&1` then overrides /dev/null with the actual job log
    # for the apply itself.
    # Z2K_AU_MANUAL=1 — a human pressed the button, so this apply runs even when
    # nightly auto-update is switched off.
    #
    # Z2K_AU_NO_JITTER=1 — the updater sleeps a deterministic 0..60min per-host
    # jitter to spread the fleet's nightly GitHub hits, and it decides "this is
    # the nightly run" from stdin not being a tty. This subshell closes stdin
    # (it has to — see the note above), so a button press was indistinguishable
    # from cron and could sit there sleeping for up to an hour and a half with an
    # empty job log. The menu path already passed this flag; the panel did not.
    # trap '' HUP — БЕЗ него обновление через панель обрывается на середине.
    #
    # busybox ash шлёт SIGHUP фоновым детям, когда обёртка завершается, а
    # CGI-обёртка обязана завершиться немедленно: она возвращает браузеру
    # job_id. Плюс сама установка перезапускает панель, под которой и живёт эта
    # задача. По умолчанию Go- и sh-процессы от HUP умирают, поэтому установка
    # падала где-то на пятом шаге из двенадцати — ровно там, где переезжает
    # дерево /opt/zapret2, — и роутер оставался с переименованным деревом и без
    # панели. Снаружи это выглядело как «панель ответила 404, чем кончилась
    # задача неизвестно»: сообщать о провале было уже некому и нечем.
    #
    # Приём тот же, что у S98tg-tunnel и S97z2k-http-tunnel (там он появился
    # из-за MIPS): ребёнок наследует игнорирование HUP. Замерено на роутере —
    # без строки задача умирает на HUP, с ней доживает до конца.
    (
        trap '' HUP
        exec >> "$(_z2k_job_file "$job_id" log)" 2>&1
        job_log_record "$label"
        printf '─────────────────────────────────────────\n'
        export Z2K_JOB_ID="$job_id"
        job_progress "Запущено: $label; читаю манифест и проверяю состав обновления"
        local started_at ended_at elapsed command_pid rc
        started_at=$(date +%s 2>/dev/null) || started_at=0
        ( env Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 sh "$AU_SCRIPT" "$action" ) &
        command_pid=$!
        job_wait_child "$command_pid" "$label"
        rc=$?
        ended_at=$(date +%s 2>/dev/null) || ended_at="$started_at"
        elapsed=$((ended_at - started_at))
        if [ "$rc" = 0 ]; then
            if [ "$action" = reinstall ]; then
                job_progress "Итог: переустановщик завершился успешно за ${elapsed} с; версия не менялась."
            else
                job_progress "Итог: updater завершил применение за ${elapsed} с; установленную сборку можно проверить в статусе."
            fi
        else
            job_progress "Итог: $label завершилось ошибкой, код $rc, время ${elapsed} с. Причина указана выше."
        fi
        printf '─────────────────────────────────────────\n'
        [ "$rc" = 0 ] && job_log_record "Готово ✓" \
            || job_log_record "Завершено с кодом $rc"
        echo "$rc" > "$(_z2k_job_file "$job_id" exit)"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$(_z2k_job_file "$job_id" pid)"
    printf '%s' "$job_id"
}

# Проверка одного домена — то же, что пункт [Y] в терминальном меню.
#
# ЧТО ЭТО. z2k-detect probe делает одну пробу домена мимо нашего обхода
# (raw-сокет с SO_MARK) и печатает, чем именно кончилась каждая стадия —
# DNS, TCP, TLS, HTTP, — плюс вердикт: блокирует ли DPI и есть ли домен в
# наших списках. Команда СТАТЕЛЕСС: не открывает состояние демона, ничего не
# пишет в списки или persistent state. Поэтому её безопасно дёргать из
# панели по кнопке.
#
# ПОЧЕМУ СИНХРОННО, БЕЗ МАШИНЕРИИ ЗАДАЧ. У пробы свой внутренний потолок в
# 1500 мс на стадию, а стадии идут параллельно — «worst-case latency from
# sum(timeouts) to max(timeouts)». Замерено на роутере: 0,18 с на
# несуществующем домене, 0,34 с на живом, 1,0 с на заблокированном, 3,2 с в
# худшем виденном случае. Заводить ради этого фоновую задачу с опросом —
# сложность без выигрыша.
#
# СТОРОЖ ВСЁ РАВНО ЕСТЬ. `timeout` на Entware отсутствует, а зависший CGI
# держит соединение и воркер lighttpd. Поэтому ждём сами и добиваем.
detect_probe_domain() {
    local domain="$1"
    local bin="${Z2K_DETECT_BIN:-/opt/sbin/z2k-detect}"

    # Проверка ТУТ, а не только на странице: панель без пароля доверяет всей
    # локальной сети, а значение уходит в командную строку. Набор символов тот
    # же, что у пункта [Y] в меню.
    case "$domain" in
        ""|*[!a-zA-Z0-9.-]*) echo "bad domain" >&2; return 2 ;;
    esac
    # 253 — потолок длины полного доменного имени.
    [ "${#domain}" -le 253 ] || { echo "domain too long" >&2; return 2; }

    [ -x "$bin" ] || { echo "z2k-detect not installed" >&2; return 3; }

    local out="/tmp/z2k-probe.$$"
    "$bin" probe "$domain" > "$out" 2>&1 &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 20 ] && { kill -9 "$pid" 2>/dev/null; rm -f "$out"; echo "probe timeout" >&2; return 4; }
        sleep 1
    done
    wait "$pid" 2>/dev/null
    cat "$out"
    rm -f "$out"
    return 0
}

STRATEGY_PICK_OUT="${STRATEGY_PICK_OUT:-/tmp/z2k-strategy-pick.json}"

# Подбор стратегии под один домен — наш аналог blockcheck.
#
# ЧТО ЭТО. Замеряем, чем именно режут домен, и выводим готовую строку
# параметров. Не перебор заранее заготовленных плеч: инструмент задаёт коробке
# несколько вопросов и собирает ответ из измеренных свойств. Обе команды
# СТАТЕЛЕСС — не пишут ни в конфиг, ни в списки, ни в состояние ротации.
# Человек сам решает, что делать со строкой.
#
# ДВА ПРОТОКОЛА, И ОБА ВСЕГДА. Человек, у которого не грузится сайт, не знает,
# каким протоколом ходит его браузер, а браузер ходит обоими: современный
# Chrome предпочитает HTTP/3 и откатывается на TCP молча и не всегда. Спрашивать
# у человека «TCP или QUIC» — перекладывать на него наш вопрос, поэтому меряем
# оба и показываем оба.
#
# ЗАМЕРЫ ИДУТ ПАРАЛЛЕЛЬНО, а не по очереди. Они независимы: разные протоколы,
# разные сокеты, разные пятёрки. Последовательный прогон удвоил бы ожидание
# ровно ни за чем.
#
# ЧАСТИЧНЫЙ УСПЕХ — ЭТО УСПЕХ. Хост может не обслуживать HTTP/3 вовсе, и тогда
# QUIC-замер честно скажет «резать нечего». Объявлять из-за этого провалившимся
# весь прогон нельзя: строка по второму протоколу человеку всё равно нужна.
#
# ПОЧЕМУ ЗАДАЧЕЙ, А НЕ СИНХРОННО, В ОТЛИЧИЕ ОТ detect_probe_domain ВЫШЕ. Та
# проба укладывается в секунды (замерено: 0,18–3,2 с), эта идёт до двух минут:
# зондов полтора десятка, и каждый повторяется трижды — вердикт выносится
# только при единогласии. Синхронный CGI на минуту занял бы воркер lighttpd.
#
# ЖУРНАЛ НЕ ДОЛЖЕН МОЛЧАТЬ. С -json на stdout уходит только итоговый JSON, а
# человек смотрит в журнал задачи, чтобы понять, что работа идёт. Поэтому
# отбиваем такт сами.
strategy_pick_run() {
    STRATEGY_PICK_FAILURE_REASON=""
    local domain="$1" mode="${2:-tcp13}" pinned_ip="${3:-}" also_test_ips="${4:-}" extra_ip target_addr
    # Прочерк — это «домена нет», его ставит вызывающий, чтобы позиция
    # аргументов не зависела от пустоты значения.
    [ "$domain" = "-" ] && domain=""
    local bin="${Z2K_DETECT_BIN:-/opt/sbin/z2k-detect}"

    # Проверка ТУТ, а не только на странице: панель без пароля доверяет всей
    # локальной сети, а значение уходит в командную строку.
    case "$mode" in
        tcp13|tcp12|mixed|quic|voice) ;;
        *) echo "неизвестный режим замера" >&2; return 2 ;;
    esac
    # Набор символов проверяем ВСЕГДА: значение уходит в командную строку, и
    # режим не должен решать, проверять его или нет. Пустой домен допустим
    # только у голоса — там его не существует.
    case "$domain" in
        *[!a-zA-Z0-9.-]*) echo "в имени домена есть недопустимые символы" >&2; return 2 ;;
    esac
    [ "${#domain}" -le 253 ] || { echo "слишком длинное имя домена" >&2; return 2; }
    if [ "$mode" != voice ] && [ -z "$domain" ]; then
        echo "не указан домен" >&2; return 2
    fi
    if [ -n "$pinned_ip" ]; then
        strategy_unique_set_ipv4_valid "$pinned_ip" || { echo "некорректный IPv4 для замера" >&2; return 2; }
        [ "$mode" = tcp13 ] || [ "$mode" = tcp12 ] || [ "$mode" = mixed ] || {
            echo "закреплённый IP поддерживается только для TCP" >&2; return 2;
        }
    fi
    for extra_ip in $also_test_ips; do
        strategy_unique_set_ipv4_valid "$extra_ip" || { echo "некорректный дополнительный IPv4 для замера" >&2; return 2; }
    done
    [ -x "$bin" ] || { echo "модуль замера не установлен" >&2; return 3; }

    rm -f "$STRATEGY_PICK_OUT"
    local tcp_out="/tmp/z2k-strategy-pick-tcp.$$"
    local quic_out="/tmp/z2k-strategy-pick-quic.$$"
    local voice_out="/tmp/z2k-strategy-pick-voice.$$"
    local tcp_err="/tmp/z2k-strategy-pick-tcp-err.$$"
    local quic_err="/tmp/z2k-strategy-pick-quic-err.$$"
    local voice_err="/tmp/z2k-strategy-pick-voice-err.$$"

    # РЕЖИМ ВЫБИРАЕТ ЧЕЛОВЕК, А НЕ МЫ ЗА НЕГО.
    #
    # Раньше замер всегда шёл по обоим протоколам, а подбор под старые
    # устройства включался по списку доменов. И то и другое — гадание: у одного
    # дома телевизор, у другого нет, одному важен браузер, другому приставка, и
    # сколько человек готов ждать, мы не знаем. Теперь он говорит сам, а мы
    # честно предупреждаем о цене.
    #
    # GODEBUG — тот же, что у службы: без него Go-бинарники падают на MIPS от
    # асинхронного вытеснения.
    local tcp_pid= quic_pid= voice_pid= limit=300
    local tcp_rc=0 quic_rc=0 voice_rc=0
    case "$mode" in
        tcp13)
            echo "Замеряю $domain по TCP для современных устройств — браузеры, телефоны."
            echo "Это занимает до двух минут."
            if [ -n "$pinned_ip" ]; then
                set -- classify -json -hello modern -sni "$domain"
                target_addr="$pinned_ip:443"
            else
                set -- classify -json -hello modern
                target_addr="${domain}:443"
            fi
            for extra_ip in $also_test_ips; do set -- "$@" -also-test-ip "$extra_ip"; done
            set -- "$@" "$target_addr"
            GODEBUG=asyncpreemptoff=1 "$bin" "$@" > "$tcp_out" 2>"$tcp_err" &
            tcp_pid=$!
            ;;
        tcp12)
            echo "Замеряю $domain по TCP для старых устройств — телевизоры, приставки."
            echo "Это занимает до двух минут."
            if [ -n "$pinned_ip" ]; then
                set -- classify -json -hello legacy -sni "$domain"
                target_addr="$pinned_ip:443"
            else
                set -- classify -json -hello legacy
                target_addr="${domain}:443"
            fi
            for extra_ip in $also_test_ips; do set -- "$@" -also-test-ip "$extra_ip"; done
            set -- "$@" "$target_addr"
            GODEBUG=asyncpreemptoff=1 "$bin" "$@" > "$tcp_out" 2>"$tcp_err" &
            tcp_pid=$!
            ;;
        mixed)
            echo "Замеряю $domain по TCP и подбираю приём, который возьмёт И современные"
            echo "устройства, И старые. Это занимает 3-5 минут: ищем кандидаты на опорном"
            echo "IP и проверяем каждый на остальных адресах и обоих приветствиях."
            limit=420
            if [ -n "$pinned_ip" ]; then
                set -- classify -json -hello both -sni "$domain"
                target_addr="$pinned_ip:443"
            else
                set -- classify -json -hello both
                target_addr="${domain}:443"
            fi
            for extra_ip in $also_test_ips; do set -- "$@" -also-test-ip "$extra_ip"; done
            set -- "$@" "$target_addr"
            GODEBUG=asyncpreemptoff=1 "$bin" "$@" > "$tcp_out" 2>"$tcp_err" &
            tcp_pid=$!
            ;;
        quic)
            echo "Замеряю $domain по QUIC — так ходят браузеры по HTTP/3."
            echo "Это занимает около минуты."
            GODEBUG=asyncpreemptoff=1 "$bin" quic -json "$domain" > "$quic_out" 2>"$quic_err" &
            quic_pid=$!
            ;;
        voice)
            echo "Замеряю голос Дискорда. Адрес беру из ИДУЩЕГО разговора: у голоса нет"
            echo "имени, которое можно вписать, сервер выдаётся на сессию."
            echo "Если разговор не начат — замер это честно скажет."
            limit=120
            GODEBUG=asyncpreemptoff=1 "$bin" voice -json > "$voice_out" 2>"$voice_err" &
            voice_pid=$!
            ;;
    esac

    local i=0
    while { [ -n "$tcp_pid" ] && kill -0 "$tcp_pid" 2>/dev/null; } ||
          { [ -n "$quic_pid" ] && kill -0 "$quic_pid" 2>/dev/null; } ||
          { [ -n "$voice_pid" ] && kill -0 "$voice_pid" 2>/dev/null; }; do
        i=$((i + 1))
        # Потолок свой на режим: смешанный честно дороже остальных, и общий
        # потолок либо резал бы его, либо был бы бессмысленно велик для прочих.
        if [ "$i" -gt "$limit" ]; then
            # СПЕРВА МЯГКО. Сырые зонды на время работы вешают правило iptables
            # и снимают его при закрытии соединения; kill -9 такой возможности
            # не даёт, и правило остаётся висеть в OUTPUT. Даём процессу
            # секунду на уборку и только потом добиваем.
            for _p in $tcp_pid $quic_pid $voice_pid; do kill "$_p" 2>/dev/null; done
            sleep 1
            [ -n "$tcp_pid" ] && kill -9 "$tcp_pid" 2>/dev/null
            [ -n "$quic_pid" ] && kill -9 "$quic_pid" 2>/dev/null
            [ -n "$voice_pid" ] && kill -9 "$voice_pid" 2>/dev/null
            rm -f "$tcp_out" "$quic_out" "$voice_out" "$tcp_err" "$quic_err" "$voice_err"
            STRATEGY_PICK_FAILURE_REASON="замер не уложился в отведённое время"
            echo "$STRATEGY_PICK_FAILURE_REASON" >&2
            return 4
        fi
        [ $((i % 15)) = 0 ] && echo "  идёт замер, ${i} с"
        sleep 1
    done
    if [ -n "$tcp_pid" ]; then
        wait "$tcp_pid" 2>/dev/null || tcp_rc=$?
    fi
    if [ -n "$quic_pid" ]; then
        wait "$quic_pid" 2>/dev/null || quic_rc=$?
    fi
    if [ -n "$voice_pid" ]; then
        wait "$voice_pid" 2>/dev/null || voice_rc=$?
    fi

    if [ ! -s "$tcp_out" ] && [ ! -s "$quic_out" ] && [ ! -s "$voice_out" ]; then
        local error_source="$tcp_err"
        [ "$mode" = quic ] && error_source="$quic_err"
        [ "$mode" = voice ] && error_source="$voice_err"
        STRATEGY_PICK_FAILURE_REASON="замер не дал результата"
        if [ -s "$error_source" ]; then
            local detail
            detail=$(awk 'NR == 1 { gsub(/[[:cntrl:]]/, " "); print substr($0, 1, 160); exit }' "$error_source")
            [ -z "$detail" ] || STRATEGY_PICK_FAILURE_REASON="$STRATEGY_PICK_FAILURE_REASON: $detail"
        fi
        rm -f "$tcp_out" "$quic_out" "$voice_out" "$tcp_err" "$quic_err" "$voice_err"
        echo "$STRATEGY_PICK_FAILURE_REASON" >&2
        return 5
    fi

    # Форма ответа одна на все режимы: половина, которую не мерили, остаётся
    # null. Так странице не нужно знать, что именно запрашивали, — она рисует
    # то, что пришло.
    #
    # Склейка литералами, а не разбором: куски — JSON, выданный нашими же
    # бинарниками, и переписывать их шеллом значило бы завести второй формат,
    # который поедет вслед за первым.
    local all="/tmp/z2k-strategy-pick-all.$$"
    local result_rc="$tcp_rc" result_source="$tcp_out" result_err="$tcp_err" typed_error
    case "$mode" in
        quic) result_rc="$quic_rc"; result_source="$quic_out"; result_err="$quic_err" ;;
        voice) result_rc="$voice_rc"; result_source="$voice_out"; result_err="$voice_err" ;;
    esac
    typed_error="$(sed -n 's/.*"error_code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$result_source" | head -n 1 | cut -c1-100)"
    # Режим кладём в ответ: страница читает ПОСЛЕДНИЙ результат и без этого не
    # знала бы, что именно мерили, — подписала бы замер под старые устройства
    # как обычный TCP.
    printf '{"mode":"%s","tcp":' "$mode" > "$all"
    if [ -s "$tcp_out" ]; then cat "$tcp_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf ',"quic":' >> "$all"
    if [ -s "$quic_out" ]; then cat "$quic_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf ',"voice":' >> "$all"
    if [ -s "$voice_out" ]; then cat "$voice_out" >> "$all"; else printf 'null' >> "$all"; fi
    printf '}\n' >> "$all"
    rm -f "$tcp_out" "$quic_out" "$voice_out"
    mv -f "$all" "$STRATEGY_PICK_OUT"
    if [ "$result_rc" -ne 0 ]; then
        local detail
        detail=$(awk 'NR == 1 { gsub(/[[:cntrl:]]/, " "); print substr($0, 1, 160); exit }' "$result_err" 2>/dev/null)
        if [ -n "$typed_error" ]; then
            STRATEGY_PICK_FAILURE_REASON="z2k-detect: $typed_error"
            echo "Итог: причина=$typed_error"
        else
            STRATEGY_PICK_FAILURE_REASON="z2k-detect завершился с кодом $result_rc"
            echo "Итог: $STRATEGY_PICK_FAILURE_REASON"
        fi
        if [ -n "$detail" ]; then
            STRATEGY_PICK_FAILURE_REASON="$STRATEGY_PICK_FAILURE_REASON; stderr: $detail"
            echo "Диагностика stderr z2k-detect: $detail"
        fi
        rm -f "$tcp_err" "$quic_err" "$voice_err"
        return "$result_rc"
    fi
    rm -f "$tcp_err" "$quic_err" "$voice_err"
    echo "Замер закончен за ${i} с."
    return 0
}

# Последний результат замера. Пусто — ни разу не запускали.
strategy_pick_last() {
    [ -s "$STRATEGY_PICK_OUT" ] && cat "$STRATEGY_PICK_OUT"
}

# Пакетный эксперимент «уникальный набор». Все параметры здесь заданы
# сервером: caller не может подставить домен, режим, имя пула или shell-команду.
strategy_unique_set_strategy() {
    # Ответ z2k-detect вкладывается в компактный JSON strategy_pick_run. Берём
    # только первое поле стратегии и отвергаем экранированные значения.
    sed -n 's/.*"strategy"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' "$1" | head -n 1
}

strategy_unique_set_normalize() {
    awk '{$1=$1; print}'
}

strategy_unique_set_ipv4_valid() {
    awk -F. 'NF != 4 { exit 1 } { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i > 255 || ($i != "0" && $i ~ /^0/)) exit 1 } END { if (NF != 4) exit 1 }' <<EOF
$1
EOF
}

strategy_unique_set_parse_ips() {
    awk -v stats="${1:-}" '
        function ipv4(ip, a, n, i) {
            n = split(ip, a, "."); if (n != 4) return 0
            for (i = 1; i <= 4; i++) {
                if (a[i] !~ /^[0-9]+$/ || a[i] + 0 > 255 || (a[i] != "0" && a[i] ~ /^0/)) return 0
            }
            return 1
        }
        {
            if ($1 == "Name:") { in_answers = 1; next }
            if (!in_answers) next
            for (i = 1; i <= NF; i++) {
                if (ipv4($i) && !raw_seen[$i]++) raw_count++
            }
            if ($1 == "Address:") {
                ip = $2
            } else if ($1 == "Address" && $2 ~ /^[0-9]+:$/) {
                ip = $3
            } else {
                next
            }
            if (ipv4(ip) && ip != "127.0.0.1" && ip != "0.0.0.0" && !seen[ip]++) {
                parsed[++parsed_count] = ip
            }
        }
        END {
            if (stats == "--stats") {
                print raw_count + 0, parsed_count + 0
            } else {
                for (i = 1; i <= parsed_count && i <= 2; i++) print parsed[i]
            }
        }
    '
}

strategy_unique_set_preflight() {
    local resolver="${Z2K_NSLOOKUP_BIN:-nslookup}" detector="${Z2K_DETECT_BIN:-/opt/sbin/z2k-detect}"
    if ! command -v "$resolver" >/dev/null 2>&1; then
        STRATEGY_UNIQUE_FAILURE_REASON="Не найден nslookup: $resolver"
        echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2
        return 1
    fi
    if [ ! -x "$detector" ]; then
        STRATEGY_UNIQUE_FAILURE_REASON="Не найден или не исполняемый z2k-detect: $detector"
        echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2
        return 1
    fi
    return 0
}

strategy_unique_set_ips() {
    local domain="$1" resolver="${Z2K_NSLOOKUP_BIN:-nslookup}" output stats raw_count parsed_count attempt=0 max_attempts=3
    STRATEGY_UNIQUE_DNS_IPS=""
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        output=$("$resolver" "$domain" 2>/dev/null) || {
            STRATEGY_UNIQUE_FAILURE_REASON="$domain: DNS-резолв завершился ошибкой"
            echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2
            return 1
        }
        STRATEGY_UNIQUE_DNS_IPS=$(printf '%s\n' "$output" | strategy_unique_set_parse_ips)
        stats=$(printf '%s\n' "$output" | strategy_unique_set_parse_ips --stats)
        raw_count=${stats%% *}
        parsed_count=${stats#* }
        if [ "$parsed_count" -ge 2 ]; then
            STRATEGY_UNIQUE_FAILURE_REASON=""
            return 0
        fi

        # Multiple raw IPv4 addresses that the parser cannot recognize indicate
        # a format regression, not a transient empty/undersized DNS answer.
        if [ "$raw_count" -ge 2 ]; then
            STRATEGY_UNIQUE_FAILURE_REASON="$domain: DNS вернул $raw_count IPv4, parser распознал $parsed_count"
            echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2
            return 1
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "$domain: DNS вернул $raw_count IPv4; повтор $((attempt + 1))/$max_attempts через 1 с, нужны два разных IPv4" >&2
            sleep 1
            continue
        fi
        if [ "$parsed_count" = 1 ]; then
            STRATEGY_UNIQUE_FAILURE_REASON="$domain: DNS вернул $raw_count IPv4; найден только один уникальный IPv4, нужны два для проверки"
        else
            STRATEGY_UNIQUE_FAILURE_REASON="$domain: DNS вернул $raw_count IPv4, parser распознал $parsed_count; нужны два разных IPv4 для проверки"
        fi
        echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2
        return 1
    done
    return 1
}

strategy_unique_set_measure() {
    local domain="$1" mode="$2" out="$3" pinned_ip="${4:-}" also_test_ips="${5:-}" previous_out="${STRATEGY_PICK_OUT:-}" rc
    STRATEGY_PICK_OUT="$out"
    strategy_pick_run "$domain" "$mode" "$pinned_ip" "$also_test_ips"
    rc=$?
    STRATEGY_PICK_OUT="$previous_out"
    if [ "$rc" != 0 ]; then
        [ -z "${STRATEGY_PICK_FAILURE_REASON:-}" ] || STRATEGY_UNIQUE_FAILURE_REASON="$STRATEGY_PICK_FAILURE_REASON"
        return "$rc"
    fi
    [ -s "$out" ] || { STRATEGY_UNIQUE_FAILURE_REASON="Замер $domain не создал результат"; echo "$STRATEGY_UNIQUE_FAILURE_REASON" >&2; return 1; }
    return 0
}

strategy_unique_set_lock_acquire() {
    local dir="${STRATEGY_UNIQUE_LOCK_DIR:-/tmp/z2k-unique-set.lock}" owner n=0
    while ! mkdir "$dir" 2>/dev/null; do
        owner=$(cat "$dir/pid" 2>/dev/null)
        if [ -n "$(find "$dir" -maxdepth 0 -mmin +120 2>/dev/null)" ] &&
           { [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; }; then
            rm -rf "$dir" 2>/dev/null
            continue
        fi
        return 1
    done
    STRATEGY_UNIQUE_LOCK_TOKEN="$(date +%s)-$$"
    printf '%s\n' "$$" > "$dir/pid"
    printf '%s\n' "$STRATEGY_UNIQUE_LOCK_TOKEN" > "$dir/token"
    return 0
}

strategy_unique_set_lock_release() {
    local dir="${STRATEGY_UNIQUE_LOCK_DIR:-/tmp/z2k-unique-set.lock}" token
    token=$(cat "$dir/token" 2>/dev/null)
    [ -n "${STRATEGY_UNIQUE_LOCK_TOKEN:-}" ] && [ "$token" = "$STRATEGY_UNIQUE_LOCK_TOKEN" ] && rm -rf "$dir"
}

strategy_unique_set_result_write() {
    local staged="$1" coverage="$2" reason="$3" elapsed="$4" restarted="$5"
    local result="${STRATEGY_UNIQUE_RESULT_FILE:-/tmp/z2k-unique-set-result.json}" tmp
    tmp="$result.$$"
    {
        printf '{"ok":true,"pools":{'
        for pool in yt_tcp gv_tcp quic rkn_tcp; do
            [ "$pool" = yt_tcp ] || printf ','
            printf '"%s":' "$pool"
            json_string "$(cat "$staged/$pool.txt")"
        done
        printf '},"rkn":{"coverage":'; json_string "$coverage"
        printf ',"strategy":'; json_string "$(cat "$staged/rkn_tcp.txt")"
        printf ',"reason":'; json_string "$reason"
        printf ',"domains":["discord.com","instagram.com","rutor.org"]}'
        printf ',"elapsed_seconds":%s,"service_restarted":%s,"needs_service_start":%s}\n' \
            "$elapsed" "$restarted" "$([ "$restarted" = true ] && echo false || echo true)"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    UNIQUE_SET_RESULT_TMP="$tmp"
    return 0
}

strategy_unique_set_result_failure_write() {
    local error="$1" elapsed="$2"
    local result="${STRATEGY_UNIQUE_RESULT_FILE:-/tmp/z2k-unique-set-result.json}" tmp
    tmp="$result.$$"
    {
        printf '{"ok":false,"error":'; json_string "$error"
        printf ',"elapsed_seconds":%s}\n' "$elapsed"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$result" || { rm -f "$tmp"; return 1; }
}

strategy_unique_set_stage() {
    local domain="$1" mode="$2" name="$3" pool="$4" json
    json="$UNIQUE_SET_DIR/$name.json"
    local found complete
    echo "Этап: $domain ($mode) → $pool"
    strategy_unique_set_measure "$domain" "$mode" "$json" || return $?
    found=$(strategy_unique_set_strategy "$json")
    [ -n "$found" ] || { echo "Для $domain стратегия не найдена" >&2; return 20; }
    case "$found" in
        *'"'*|*'\\'*) echo "В выводе для $domain небезопасная строка стратегии" >&2; return 1 ;;
    esac
    complete=$(printf '%s\n' "$found" | strategy_complete_line "$pool") || return 1
    [ -n "$complete" ] || { echo "Не удалось собрать профиль пула $pool" >&2; return 1; }
    printf '%s\n' "$complete" > "$UNIQUE_SET_DIR/$pool.txt" || return 1
    echo "Найдена стратегия: $found"
}

strategy_unique_set_stage_multi_ip() {
    local domain="$1" mode="$2" name="$3" pool="$4" ips anchor additional found complete out attempt=0
    strategy_unique_set_ips "$domain" || return 1
    ips="$STRATEGY_UNIQUE_DNS_IPS"
    [ "$(printf '%s\n' "$ips" | awk 'NF {n++} END {print n+0}')" = 2 ] || {
        echo "$domain: нужны два разных IPv4-адреса DNS для проверки, найдено меньше двух" >&2; return 1;
    }
    found=""
    while IFS= read -r anchor; do
        [ -n "$anchor" ] || continue
        attempt=$((attempt + 1))
        additional=$(printf '%s\n' "$ips" | awk -v anchor="$anchor" '$0 != anchor && NF { if (out != "") out=out " "; out=out $0 } END { print out }')
        out="$UNIQUE_SET_DIR/$name-common-$attempt.json"
        echo "Этап: $domain ($mode), ищу от $anchor и проверяю кандидаты на всех адресах"
        strategy_unique_set_measure "$domain" "$mode" "$out" "$anchor" "$additional" || {
            echo "$domain: общий замер на $anchor не завершился; пул $pool не будет применён" >&2; return 1;
        }
        found=$(strategy_unique_set_normalize < "$out" | strategy_unique_set_strategy /dev/stdin)
        [ -z "$found" ] || break
    done <<EOF
$ips
EOF
    [ -n "$found" ] || { echo "$domain: общий кандидат не найден ни с одного IP; пул $pool не будет применён" >&2; return 1; }
    case "$found" in *'"'*|*'\'*) echo "небезопасная строка стратегии для $domain" >&2; return 1 ;; esac
    complete=$(printf '%s\n' "$found" | strategy_complete_line "$pool") || return 1
    [ -n "$complete" ] || { echo "Не удалось собрать профиль пула $pool" >&2; return 1; }
    printf '%s\n' "$complete" > "$UNIQUE_SET_DIR/$pool.txt" || return 1
    echo "Общий кандидат для $domain прошёл всю проверочную матрицу: $found"
}

strategy_unique_set_run() {
    local previous_out="${STRATEGY_PICK_OUT:-}" started ended discord instagram rutor selected coverage reason rc
    local own_dir=0
    STRATEGY_UNIQUE_FAILURE_REASON=""
    strategy_unique_set_preflight || return 1
    if [ -z "${UNIQUE_SET_DIR:-}" ]; then
        UNIQUE_SET_DIR="/tmp/z2k-unique-set.$$"
        own_dir=1
    fi
    UNIQUE_SET_OWN_DIR="$own_dir"
    rm -rf "$UNIQUE_SET_DIR" 2>/dev/null
    mkdir -p "$UNIQUE_SET_DIR" || { echo "Не удалось создать рабочий каталог" >&2; return 1; }
    STRATEGY_PICK_OUT="$previous_out"
    started=$(date +%s)

    strategy_unique_set_stage_multi_ip i.ytimg.com mixed stage-youtube yt_tcp || return 1
    strategy_unique_set_stage_multi_ip googlevideo.com mixed stage-googlevideo gv_tcp || return 1
    strategy_unique_set_stage instagram.com quic stage-instagram-quic quic || return 1
    # RKN TCP is compared only on the modern TLS 1.3 hello. The legacy hello
    # can select a different strategy and is outside this experiment's target.
    strategy_unique_set_stage discord.com tcp13 stage-discord rkn_tcp || return 1
    strategy_unique_set_stage instagram.com tcp13 stage-instagram-tcp rkn_tcp || {
        rc=$?; [ "$rc" = 20 ] || return "$rc"
    }
    strategy_unique_set_stage rutor.org tcp13 stage-rutor rkn_tcp || {
        rc=$?; [ "$rc" = 20 ] || return "$rc"
    }

    discord=$(strategy_unique_set_normalize < "$UNIQUE_SET_DIR/stage-discord.json" | strategy_unique_set_strategy /dev/stdin)
    instagram=$(strategy_unique_set_strategy "$UNIQUE_SET_DIR/stage-instagram-tcp.json" 2>/dev/null | strategy_unique_set_normalize)
    rutor=$(strategy_unique_set_strategy "$UNIQUE_SET_DIR/stage-rutor.json" 2>/dev/null | strategy_unique_set_normalize)
    # Discord is mandatory; the two other RKN probes are informative and may
    # fail, in which case the measured Discord result remains the fallback.
    [ -n "$discord" ] || { echo "Discord-стратегия обязательна для RKN-пула" >&2; return 1; }
    discord=$(printf '%s' "$discord" | strategy_unique_set_normalize)
    selected="$discord"
    coverage=Discord-fallback
    reason="Discord-fallback: нет общего первого найденного приёма"
    if [ -n "$instagram" ] && [ -n "$rutor" ] && [ "$discord" = "$instagram" ] && [ "$discord" = "$rutor" ]; then
        coverage=3/3
        reason="общая строка первых найденных приёмов"
    fi
    echo "RKN: $coverage; $reason"
    printf '%s\n' "$selected" | strategy_complete_line rkn_tcp > "$UNIQUE_SET_DIR/rkn_tcp.txt" || return 1

    local service_restarted=false
    is_running && service_restarted=true
    echo "Проверяю и применяю все четыре пула одним набором…"
    strategy_pool_save_batch "$UNIQUE_SET_DIR" "$UNIQUE_SET_DIR/transaction" || { rm -f "${UNIQUE_SET_RESULT_TMP:-}"; return $?; }
    ended=$(date +%s)
    strategy_unique_set_result_write "$UNIQUE_SET_DIR" "$coverage" "$reason" "$((ended - started))" "$service_restarted" || {
        echo "Набор применён, но не удалось собрать итоговый отчёт" >&2; return 1;
    }
    mv -f "$UNIQUE_SET_RESULT_TMP" "${STRATEGY_UNIQUE_RESULT_FILE:-/tmp/z2k-unique-set-result.json}" || {
        echo "набор применён, но не удалось сохранить итоговый отчёт" >&2; return 1;
    }
    echo "Набор применён за $((ended - started)) с."
    [ "$own_dir" = 0 ] || rm -rf "$UNIQUE_SET_DIR"
    return 0
}

strategy_unique_set_worker() {
    local started ended rc error
    trap 'strategy_unique_set_worker_cleanup' 0
    started=$(date +%s)
    strategy_unique_set_run
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ended=$(date +%s)
        error="${STRATEGY_UNIQUE_FAILURE_REASON:-Набор не применён (код $rc); подробности в журнале задачи}"
        strategy_unique_set_result_failure_write "$error" "$((ended - started))" || {
            echo "Не удалось сохранить причину отказа набора" >&2
        }
    fi
    return "$rc"
}

strategy_unique_set_worker_cleanup() {
    [ "${UNIQUE_SET_OWN_DIR:-0}" = 1 ] && rm -rf "${UNIQUE_SET_DIR:-}" 2>/dev/null
    rm -f "${UNIQUE_SET_RESULT_TMP:-}" 2>/dev/null
    strategy_unique_set_lock_release
}

# Удаление z2k целиком, фоновой задачей.
#
# ОТЛИЧИЕ ОТ ВСЕХ ОСТАЛЬНЫХ ЗАДАЧ, И ОНО ГЛАВНОЕ: панель, из которой задачу
# запустили, входит в удаляемое. uninstall_zapret2 гасит S96z2k-webpanel и
# добивает lighttpd по маске — то есть сервер, отдавший этот ответ, перестанет
# существовать где-то в середине работы, и обратно не поднимется никогда.
# Поэтому:
#   * задача обязана пережить смерть своего родителя — отсюда trap '' HUP и
#     полная отвязка от CGI-конвейеров, ровно как у обновления;
#   * лог лежит в /tmp, а не в /opt/zapret2 — иначе он был бы стёрт вместе с
#     деревом ровно в тот момент, когда он единственный источник правды;
#   * фронт НЕ должен ждать возвращения панели. Для обновления ожидание
#     правильно, здесь оно означало бы «ждём вечно».
#
# Скрипт зовём по абсолютному пути из дерева, а не через /opt/bin/z2k: симлинк
# удаляется в процессе, и полагаться на него внутри собственного удаления
# нельзя.
uninstall_async() {
    local z2k_sh="${Z2K_SH:-$ZAPRET2_DIR/z2k.sh}"
    [ -x "$z2k_sh" ] || { echo "z2k script missing: $z2k_sh" >&2; return 1; }
    mkdir -p "$Z2K_JOB_DIR" || return 1
    job_reap
    local job_id
    job_id=$(date +%s)$$
    (
        trap '' HUP
        exec >> "$(_z2k_job_file "$job_id" log)" 2>&1
        job_log_record "Удаление z2k"
        printf '─────────────────────────────────────────\n'
        export Z2K_JOB_ID="$job_id"
        job_progress "Запущено: удаление z2k; сохраняю исход и приступаю к демонтажу"
        local started_at ended_at elapsed command_pid rc
        started_at=$(date +%s 2>/dev/null) || started_at=0
        ( env Z2K_UNINSTALL_CONFIRMED=1 sh "$z2k_sh" uninstall ) &
        command_pid=$!
        job_wait_child "$command_pid" "Удаление z2k"
        rc=$?
        ended_at=$(date +%s 2>/dev/null) || ended_at="$started_at"
        elapsed=$((ended_at - started_at))
        if [ "$rc" = 0 ]; then
            job_progress "Итог: сценарий удаления завершился успешно за ${elapsed} с; панель остановлена по плану."
            job_log_record "Готово ✓"
        else
            job_progress "Итог: удаление завершилось с ошибкой, код $rc, время ${elapsed} с; подробность указана выше."
            job_log_record "Завершено с кодом $rc"
        fi
        echo "$rc" > "$(_z2k_job_file "$job_id" exit)"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$(_z2k_job_file "$job_id" pid)"
    printf '%s' "$job_id"
}

# Compare-and-swap editor contract shared by whitelist and extra-domains.
# Existing add/import/delete share this lock; a stale browser cannot overwrite
# another tab's later edit. Validate the whole candidate before replacing the
# live inode so malformed input leaves the active dataplane list intact.
domain_list_revision() {
    local target="$1"
    if [ -f "$target" ]; then
        sha256sum "$target" 2>/dev/null | cut -d' ' -f1
    else
        printf '' | sha256sum | cut -d' ' -f1
    fi
}

domain_list_save() (
    local target="$1" expected="$2" check_coverage="${3:-0}" raw tmp locked=0 current
    case "$expected" in
        ''|*[!a-f0-9]*) echo "Неизвестная версия списка. Обновите список." >&2; exit 2 ;;
    esac
    [ "${#expected}" = 64 ] || { echo "Неизвестная версия списка. Обновите список." >&2; exit 2; }
    mkdir -p "$LISTS_DIR" || exit 1
    raw=$(mktemp "$target.raw.XXXXXX") || exit 1
    tmp=$(mktemp "$target.edit.XXXXXX") || { rm -f "$raw"; exit 1; }
    trap 'rm -f "$raw" "$tmp"; [ "$locked" = 0 ] || _list_unlock "$target"' EXIT
    head -c 1048577 > "$raw" || exit 1
    [ "$(wc -c < "$raw")" -le 1048576 ] || { echo "Список больше 1 МБ." >&2; exit 2; }
    # Validate the entire candidate before touching the live file. Keep comments
    # and blank lines; normalize only domain records, deduplicating case-insensitively.
    LC_ALL=C awk '
        {
            sub(/\r$/, ""); line=$0
            sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
            if ($0 == "" || substr($0, 1, 1) == "#") { print line; next }
            d=tolower($0); valid=1
            if (length(d)>253 || d !~ /^[a-z0-9.-]+$/ || d ~ /^[0-9.]+$/) valid=0
            n=split(d, labels, ".")
            for (i=1; i<=n; i++)
                if (length(labels[i])<1 || length(labels[i])>63 || labels[i] ~ /^-/ || labels[i] ~ /-$/) valid=0
            if (!valid) {
                printf "Некорректный домен в строке %d. Укажите имя сайта без адреса, протокола и пути.\n", NR > "/dev/stderr"
                bad=1; next
            }
            if (!seen[d]++) print d
        }
        END { exit bad ? 2 : 0 }
    ' "$raw" > "$tmp" || exit 2
    _list_lock "$target" || { echo "Список занят. Повторите сохранение." >&2; exit 1; }
    locked=1
    current=$(domain_list_revision "$target")
    [ "$current" = "$expected" ] || {
        echo "Список уже изменён в другой вкладке. Обновите список перед повторным сохранением." >&2
        exit 3
    }
    if [ "$check_coverage" = 1 ]; then
        _extra_domains_validate_file "$tmp" "$target" || exit 2
    fi
    chmod 644 "$tmp" && mv -f "$tmp" "$target" || {
        echo "Не удалось сохранить список." >&2
        exit 1
    }
    domain_list_revision "$target"
)

whitelist_revision() { domain_list_revision "$WHITELIST_FILE"; }
whitelist_save() { domain_list_save "$WHITELIST_FILE" "$1"; }
extra_domains_revision() { domain_list_revision "$EXTRA_DOMAINS_FILE"; }
extra_domains_save() { domain_list_save "$EXTRA_DOMAINS_FILE" "$1" 1; }

# Check only newly added records; retaining/removing an existing record remains
# possible after other lists have changed. Read each large catalogue once, not
# once per imported domain. The target list lock is already held by the caller.
_extra_domains_validate_file() {
    local candidate="$1" old="$2" label path
    [ -f "$old" ] || old=/dev/null
    while IFS='|' read -r label path; do
        [ -s "$path" ] || continue
        LC_ALL=C awk -v old="$old" -v covered="$path" -v label="$label" '
            {
                sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
                $0=tolower($0)
            }
            FILENAME == old { previous[$0]=1; next }
            FILENAME == covered { if ($0 != "" && $0 !~ /^#/) have[$0]=1; next }
            $0 == "" || $0 ~ /^#/ || previous[$0] { next }
            {
                domain=$0; suffix=domain
                while (index(suffix, ".")) {
                    if (have[suffix]) {
                        printf "Домен %s уже покрыт записью %s в списке «%s». Список не изменён.\n", domain, suffix, label > "/dev/stderr"
                        exit 2
                    }
                    sub(/^[^.]+\./, "", suffix)
                }
            }
        ' "$old" "$path" "$candidate" || return 2
    done <<CATALOG
$(_domain_lists_catalog)
CATALOG
    return 0
}
