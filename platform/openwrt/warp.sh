#!/bin/sh
# platform/openwrt/warp.sh - Game WARP glue (Stage 5).
#
# Upstream contract: docs/openwrt-warp-contract.md (+mark allocation).
# Optional feature: бинаря нет = фичи нет. procd instance "z2k-warp",
# nft sets/chains в runtime-таблице, PBR (mark + table 989) ТОЛЬКО при
# доказанной ready. Fail open всегда: нет ready = нет маршрута.
#
# CLI самостоятельно загружает paths/env перед общим updater-кодом.
# Lifecycle-вызовы из адаптера уже приходят с выставленными paths/env.
# Использование:
#   CLI (будущая панель просто вызывает):
#     install reload-lists status selfheal migrate
#     enable disable remove
#   lifecycle (init/hotplug/cron/updater):
#     1 (boot converge: sets + instance, PBR только если proven ready)
#     0 (full stop), rules (hotplug), proc-bounce, cleanup, check
#
# Разделение stop_proxy/stop (upstream S96): proc-bounce (только процесс)
# vs 0 (полный teardown). Рестарт демона НИКОГДА не снимает PBR-желание,
# а снятие PBR идёт ПЕРВЫМ при любом переходе в не-ready.
# Mutation log (§31 RT-стиль): DNS нет; NFT_CREATED:/NFT_REMOVED:/
# PROCESS_ACTION:/PBR_UP:/PBR_DOWN: на stdout (тихо при Z2K_WARP_QUIET=1).

CONFIG_FILE="${CONFIG_FILE:-${Z2K_ETC:-/etc/z2k}/config}"
WARP_BIN="${WARP_BIN:-${Z2K_BIN:-/usr/lib/z2k/bin}/z2k-warpd}"
WARP_DEVICE="${WARP_DEVICE:-${Z2K_STATE:-/etc/z2k/state}/warp/device.json}"
WARP_STATUS="${WARP_STATUS:-${Z2K_TMP:-/tmp/z2k}/warp/status.json}"
WARP_LOG="${WARP_LOG:-${Z2K_TMP:-/tmp/z2k}/warp/warpd.log}"
WARP_REG_RETRY="${WARP_REG_RETRY:-600}"
WARP_REG_STAMP="${WARP_REG_STAMP:-${Z2K_TMP:-/tmp/z2k}/warp/register.stamp}"
# Runtime ownership record PBR (defect 5): пишется успешным pbr_up, читается
# pbr_down для proof route-ownership; убирается после teardown. Tmpfs —
# после reboot записи нет, и это корректно (PBR тоже нет).
WARP_PBR_OWNER="${WARP_PBR_OWNER:-${Z2K_TMP:-/tmp/z2k}/warp/pbr.owner}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-${Z2K_ETC:-/etc/z2k}/user-lists/warp}"
# The updater owns the per-game tree under the shipped WARP namespace.  Keep
# the runtime default aligned with z2k-update-lists.sh and the package layout;
# tests may still override WARP_GAMES_DIR for isolated fixtures.
WARP_GAMES_DIR="${WARP_GAMES_DIR:-${Z2K_LISTS_DIR}/warp/games}"
WARP_ENABLED_FILE="${WARP_ENABLED_FILE:-$WARP_LISTS_DIR/.enabled}"
WARP_DEVICES_FILE="${WARP_DEVICES_FILE:-$WARP_LISTS_DIR/devices.txt}"
WARP_ENDPOINTS="${WARP_ENDPOINTS:-${Z2K_LISTS_DIR:-/usr/lib/z2k/lists}/warp-endpoints.txt}"
WARP_SET="${WARP_SET:-z2k_warp_dst4}"
WARP_SET_SRC="${WARP_SET_SRC:-z2k_warp_src4}"
WARP_TABLE="${WARP_TABLE:-989}"
WARP_MARK="${WARP_MARK:-0x80000000}"
WARP_MASK="${WARP_MASK:-0x80000000}"
WARP_RULE_PREF="${WARP_RULE_PREF:-500}"
WARP_READY_WAIT="${WARP_READY_WAIT:-120}"
WARP_CHAIN_MARK="${WARP_CHAIN_MARK:-z2k_warp_mark}"
WARP_CHAIN_MSS="${WARP_CHAIN_MSS:-z2k_warp_mss}"
WARP_CHAIN_FWD="${WARP_CHAIN_FWD:-z2k_warp_fwd}"
WARP_CHAIN_NAT="${WARP_CHAIN_NAT:-z2k_warp_nat}"
Z2K_WARP_NFT_FAMILY="${Z2K_WARP_NFT_FAMILY:-inet}"
# Дефолт таблицы — как у TG (см. tg.sh): дефолт pinned runtime.
Z2K_WARP_NFT_TABLE="${Z2K_WARP_NFT_TABLE:-zapret2}"
# Релей для API/регистрации, если напрямую заблокирован (как S51/z2k-warp.sh;
# дефолт продублирован — равенство трёх копий сторожит parity-тест).
# Секрет релей НЕ логируем никогда (см. warp_register).
WARP_VPS_PROXY_DEFAULT="http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119"

_wlog() { echo "[z2k-warp] $*" >&2; }
_z2k_ow_warp_mut() { [ -n "$Z2K_WARP_QUIET" ] || printf '%s\n' "$1"; }
warp_flag() { grep -m1 '^GAME_WARP_ENABLED=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '" '; }
warp_set_flag() {
    [ -f "$CONFIG_FILE" ] || return 0
    local _tmp="$CONFIG_FILE.warp.$$"
    if grep -q '^GAME_WARP_ENABLED=' "$CONFIG_FILE"; then
        sed "s/^GAME_WARP_ENABLED=.*/GAME_WARP_ENABLED=$1/" "$CONFIG_FILE" > "$_tmp" && mv -f "$_tmp" "$CONFIG_FILE"
    else
        printf 'GAME_WARP_ENABLED=%s\n' "$1" >> "$CONFIG_FILE"
    fi
    rm -f "$_tmp" 2>/dev/null
}
warp_cfg() { # $1 key, $2 default: чтение конфига без сорсинга
    local _v=""
    [ -f "$CONFIG_FILE" ] && \
        _v=$(awk -F= -v k="$1" '$1==k {v=$2; gsub(/[" ]/,"",v)} END {print v}' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}
# Транспорт движка (p-84.18 parity: auto|wg|h2). Источник — конфиг
# (Z2K_WARP_TRANSPORT пишет панель; генератор его сохраняет при regen).
# Движок читает ту же переменную из env (см. merged main.go: default =
# os.Getenv) — procd instance экспортирует её ниже. Мусор = auto (та же
# нормализация, что у статус-эндпоинта панели в /warp/status).
warp_transport() {
    local _m=""
    _m="$(warp_cfg Z2K_WARP_TRANSPORT auto)"
    case "$_m" in wg|h2) printf '%s' "$_m" ;; *) printf 'auto' ;; esac
}
# Поля status.json/device.json — без jq (как upstream).
_json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1; }
_json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([a-z0-9.-]*\).*/\1/p" "$1" 2>/dev/null | head -1; }

# A fatal start removes status.json in z2k-warpd's defer, so a failed OpenWrt
# instance otherwise looks exactly like a still-starting one. Keep the daemon
# writer contract untouched and recover only the current failure code from the
# latest daemon attempt in the OpenWrt log. Resetting the accumulator on each
# `starting` line prevents an old crash from poisoning a later attempt.
_warp_log_error() {
    [ -s "$WARP_LOG" ] || return 1
    awk '
        /z2k-warpd .* starting/ { err="" }
        /fatal:.*\/dev\/net\/tun does not exist/ { err="tun_failed" }
        /fatal:.*device\.json:/ { err="register_blocked" }
        END { if (err != "") print err; else exit 1 }
    ' "$WARP_LOG" 2>/dev/null
}

warp_last_error() {
    local _error=""
    [ "$(warp_flag)" = "1" ] || return 0
    _error=$(_json_str "$WARP_STATUS" last_error)
    [ -n "$_error" ] && { printf '%s' "$_error"; return 0; }
    _warp_log_error 2>/dev/null || true
}

# wanted: global ENABLED=1 + флаг=1 + бинарь +x + ключ -s.
# (Единая точка для всех путей: init смотрит ENABLED раньше сам,
# но cron/hotplug идут мимо него.)
warp_wanted_boot() {
    [ "$(warp_cfg ENABLED 1)" = "1" ] || return 1
    [ "$(warp_flag)" = "1" ] || return 1
    [ -x "$WARP_BIN" ] || return 1
    [ -s "$WARP_DEVICE" ] || return 1
    return 0
}

# Убийство — через helper (тестам — переопределить; procd поднимает сам).
_z2k_ow_warp_kill() { kill "$@" 2>/dev/null || true; }

# PIDs нашего процесса (матч по `run` в cmdline).
warp_pids() {
    local _p _cl
    for _p in $(pidof z2k-warpd 2>/dev/null); do
        [ -r "${Z2K_PROC_ROOT:-/proc}/$_p/cmdline" ] || continue
        _cl=$(tr '\0' ' ' < "${Z2K_PROC_ROOT:-/proc}/$_p/cmdline" 2>/dev/null)
        case "$_cl" in
            *" run"*) printf '%s\n' "$_p" ;;
        esac
    done
    return 0
}
warp_running() { [ -n "$(warp_pids)" ]; }

# Собрать argv и выполнить $1 как команду (ровно одно слово-колбэк).
warp_with_argv() {
    local _cb="$1"
    shift
    set -- "$WARP_BIN" run \
        --device "$WARP_DEVICE" \
        --status "$WARP_STATUS" \
        --log "$WARP_LOG" \
        --endpoints "$WARP_ENDPOINTS" \
        --net-backend=external
    "$_cb" "$@"
}
_z2k_ow_warp_procd_command() { procd_set_param command "$@"; }

# --- списки: active + валидация (канонические awk-блоки upstream) ---

warp_lists_migrate() {
    [ -d "$WARP_LISTS_DIR" ] || mkdir -p "$WARP_LISTS_DIR" || {
        _wlog "cannot create $WARP_LISTS_DIR"; return 1; }
    mkdir -p "$WARP_GAMES_DIR" 2>/dev/null
    # One-shot purge legacy aggregate (адаптировано: только user-пути;
    # shipped-агрегата в репо нет, usque-наследия на OpenWrt не бывает).
    if [ ! -f "$WARP_LISTS_DIR/.legacy-aggregate-purged" ]; then
        rm -f "$WARP_LISTS_DIR/game-warp-ips.txt" \
              "$WARP_LISTS_DIR/.game-warp-ips.base" \
              "$WARP_LISTS_DIR/.game-warp-ips.upstream" \
              "$WARP_LISTS_DIR/.game-warp-ips.removed" \
              "$WARP_LISTS_DIR/.game-warp-ips.san" 2>/dev/null
        touch "$WARP_LISTS_DIR/.legacy-aggregate-purged" 2>/dev/null || true
        _wlog "legacy aggregate list removed"
    fi
    chmod 644 "$WARP_LISTS_DIR"/*.txt 2>/dev/null
    return 0
}

# Файлы назначений: user-списки + включённые game-списки (devices.txt —
# источники, сюда нельзя). Имя в .enabled без файла — скип.
# p-84.18 parity: user-список, выключенный тумблером панели (имя лежит в
# $WARP_LISTS_DIR/.disabled — ведёт common warp_list_toggle), в наборы НЕ
# входит. Game-списки — opt-in через .enabled (там же, общий формат).
warp_active_lists() {
    local _f _n _off="$WARP_LISTS_DIR/.disabled"
    for _f in "$WARP_LISTS_DIR"/*.txt; do
        [ "$_f" = "$WARP_DEVICES_FILE" ] && continue
        [ -f "$_f" ] || continue
        if [ -f "$_off" ]; then
            _n=$(basename "$_f" .txt)
            grep -qxF "$_n" "$_off" 2>/dev/null && continue
        fi
        printf '%s\n' "$_f"
    done
    [ -f "$WARP_ENABLED_FILE" ] || return 0
    while IFS= read -r _n; do
        _n=$(printf '%s' "$_n" | tr -d ' \t\r')
        [ -n "$_n" ] || continue
        case "$_n" in
            '#'*|.*|-*) continue ;;
            *[!A-Za-z0-9._-]*) continue ;;
        esac
        [ -f "$WARP_GAMES_DIR/$_n.txt" ] && printf '%s\n' "$WARP_GAMES_DIR/$_n.txt"
    done < "$WARP_ENABLED_FILE"
    return 0
}

# Устройства-источники: IPv4 из LAN/private/CGNAT или MAC через neigh.
# MAC офлайн — скип сейчас (подхват позже). Публичный IP — reject.
warp_devices_ips() {
    [ -s "$WARP_DEVICES_FILE" ] || return 0
    local _neigh
    _neigh=$(ip -4 neigh show 2>/dev/null | awk '$0 ~ /lladdr/ {for (i=1;i<=NF;i++) if ($i=="lladdr") printf "%s %s;", tolower($(i+1)), $1}')
    awk -v neigh="$_neigh" '
    BEGIN { n = split(neigh, lines, ";"); for (i = 1; i <= n; i++) { split(lines[i], f, " "); if (f[1] != "") mac[f[1]] = f[2] } }
    # --- z2k warp SOURCE filter (canonical; keep byte-identical in all 3 copies) ---
    function ip_ok(s,  o) {
        if (s !~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) return 0
        split(s, o, ".")
        if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
        if (o[1] == 10) return 1
        if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 1
        if (o[1] == 192 && o[2] == 168) return 1
        if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 1
        return 0
    }
    # --- end z2k warp SOURCE filter ---
    {
        sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 == "" || $0 ~ /^#/) next
        s = tolower($0); gsub(/-/, ":", s)
        if (s ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) { if ((s in mac) && ip_ok(mac[s])) print mac[s]; next }
        if (ip_ok($0)) print $0
    }' "$WARP_DEVICES_FILE"
}

# Валидированные элементы dst: по строке (пустые/комменты/CRLF/пробелы — мимо).
warp_validated_dst() {
    warp_active_lists | while IFS= read -r _wl; do cat "$_wl" 2>/dev/null; done | awk '
# --- z2k warp address filter (canonical; keep byte-identical in all 4 copies) ---
function z2k_warp_addr_ok(s,   ip, h, o) {
    if (s !~ /^[1-9][0-9]{0,2}(\.(0|[1-9][0-9]{0,2})){3}(\/([1-9]|[12][0-9]|3[0-2]))?$/) return 0
    ip = s
    if (split(s, h, "/") == 2) ip = h[1]
    # No width cap. There was one at /10, on the reasoning that no game lives on
    # a /8 — but the blocks it cut are 3.0.0.0/8 and 15.0.0.0/8, i.e. Amazon,
    # which is exactly what people switch WARP on for. /0 is still impossible:
    # the grammar above only accepts prefixes 1-32.
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return 0
    if (o[1] == 10 || o[1] == 127 || o[1] >= 224) return 0
    if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) return 0
    if (o[1] == 169 && o[2] == 254) return 0
    if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) return 0
    if (o[1] == 192 && o[2] == 168) return 0
    if (o[1] == 192 && o[2] == 0 && (o[3] == 0 || o[3] == 2)) return 0
    if (o[1] == 198 && (o[2] == 18 || o[2] == 19)) return 0
    if (o[1] == 198 && o[2] == 51 && o[3] == 100) return 0
    if (o[1] == 203 && o[2] == 0 && o[3] == 113) return 0
    return 1
}
# --- end z2k warp address filter ---
    {
        sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
        if (!z2k_warp_addr_ok($0)) next
        split($0, p, "/")
        split(p[1], o, ".")
        ip = (((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4])
        plen = (p[2] != "" ? p[2] + 0 : 32)
        block = 2 ^ (32 - plen)
        start = int(ip / block) * block
        print start, start + block - 1
    }' | sort -n -k1,1 -k2,2r | awk '
# nft interval sets reject overlapping CIDRs even when every individual line
# is valid.  Gaming feeds occasionally contain a broad network together with
# one of its narrower children; merge the numeric intervals first, then emit
# the smallest aligned CIDR cover.  This keeps the live set atomic and avoids
# hiding a failed `nft -f` behind a successful API response.
function ip4(n, a) {
    a[1] = int(n / 16777216); n -= a[1] * 16777216
    a[2] = int(n / 65536);    n -= a[2] * 65536
    a[3] = int(n / 256);      a[4] = n - a[3] * 256
    return a[1] "." a[2] "." a[3] "." a[4]
}
function emit_range(lo, hi, size, plen) {
    while (lo <= hi) {
        for (plen = 0; plen <= 32; plen++) {
            size = 2 ^ (32 - plen)
            if ((lo % size) == 0 && lo + size - 1 <= hi) break
        }
        printf "%s/%d\n", ip4(lo), plen
        lo += size
    }
}
{
    lo = $1 + 0; hi = $2 + 0
    if (!have) { cur_lo = lo; cur_hi = hi; have = 1; next }
    if (lo <= cur_hi + 1) {
        if (hi > cur_hi) cur_hi = hi
        next
    }
    emit_range(cur_lo, cur_hi)
    cur_lo = lo; cur_hi = hi
}
END { if (have) emit_range(cur_lo, cur_hi) }'
}

# CSV для `add element { ... }` (пусто = валидно пусто, вызывающий решает).
_warp_csv() { tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g'; }

_z2k_ow_warp_table_ok() {
    nft list table "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" >/dev/null 2>&1
}

# W19 helper: есть ли вообще входной материал (файлы с содержимым)?
_warp_lists_have_content() {
    local _wl
    [ -s "$WARP_DEVICES_FILE" ] && return 0
    for _wl in $(warp_active_lists 2>/dev/null); do
        [ -s "$_wl" ] && return 0
    done
    return 1
}

# Атомарный коммит ОБОИХ live sets ОДНОЙ nft-транзакцией (defect 2/W19b).
# $1 — валидированный dst-список (newline), $2 — валидированный src-список.
# Валидация — ДО вызова; здесь только переход OLD -> NEW целиком или никак:
# `nft -f -` применяет весь batch атомарно, частичного flush НЕТ.
# Пустые входы валидны (W18): оба сета атомарно пустеют.
_warp_nft_sets_commit() {
    local _dst="$1" _src="$2"
    {
        printf 'flush set %s %s %s\n' "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET"
        printf 'flush set %s %s %s\n' "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET_SRC"
        if [ -n "$_dst" ]; then
            printf 'add element %s %s %s { %s }\n' \
                "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET" \
                "$(printf '%s' "$_dst" | _warp_csv)"
        fi
        if [ -n "$_src" ]; then
            printf 'add element %s %s %s { %s }\n' \
                "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET_SRC" \
                "$(printf '%s' "$_src" | _warp_csv)"
        fi
    } | nft -f - || return 1
    return 0
}

# Загрузить ОБА сета (validate-first: битая строка не доходит до nft).
# W19: источник НЕпуст, а валидных ноль = corrupt -> отказ, live set цел.
# Источники пусты (W18, пользователь всё удалил) = валидно пусто -> заливаем
# пустоту. Возврат 0 = live-состояние корректно.
warp_nft_sets_load() {
    local _dst _src
    _dst="$(warp_validated_dst)"
    _src="$(warp_devices_ips)"
    if [ -z "$_dst" ] && [ -z "$_src" ] && _warp_lists_have_content; then
        _wlog "источники непусты, а валидных ноль — corrupt? live set цел"
        return 1
    fi
    _z2k_ow_warp_table_ok || {
        echo "z2k-openwrt: warp: нет таблицы ${Z2K_WARP_NFT_FAMILY} ${Z2K_WARP_NFT_TABLE} (сначала fw_apply)" >&2
        return 1
    }
    # Idempotent ensure создания (контент не трогаем — только add set):
    for _s in "$WARP_SET" "$WARP_SET_SRC"; do
        nft add set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_s" \
            '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    done
    # ОДНА транзакция на оба сета (flush+add обоих): всё или ничего.
    _warp_nft_sets_commit "$_dst" "$_src" || return 1
    _z2k_ow_warp_mut "NFT_CREATED: sets $WARP_SET/$WARP_SET_SRC"
    return 0
}

# Sets живы? (таблицу снесли вместе с сетами — MARK-правилам будущих
# converge не на что ссылаться; rules-путь тогда перезаливает, defect 6).
_warp_sets_ensure_live() {
    nft list set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_SET" >/dev/null 2>&1 || return 1
    nft list set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_SET_SRC" >/dev/null 2>&1 || return 1
    return 0
}

# --- nft chains/rules (свои chains в ЧУЖОЙ runtime-таблице) ---

warp_nft_rules_apply() {
    _z2k_ow_warp_table_ok || {
        echo "z2k-openwrt: warp: нет таблицы ${Z2K_WARP_NFT_FAMILY} ${Z2K_WARP_NFT_TABLE}" >&2
        return 1
    }
    nft add chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_MARK" \
        '{ type filter hook prerouting priority -150; }' 2>/dev/null || true
    nft add chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_MSS" \
        '{ type filter hook forward priority -150; }' 2>/dev/null || true
    nft add chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_FWD" \
        '{ type filter hook forward priority -1; }' 2>/dev/null || true
    nft add chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_NAT" \
        '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
    for _c in "$WARP_CHAIN_MARK" "$WARP_CHAIN_MSS" "$WARP_CHAIN_FWD" "$WARP_CHAIN_NAT"; do
        nft flush chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_c" 2>/dev/null || true
    done
    # Mark ТОЛЬКО PREROUTING, ТОЛЬКО битами маски (чужие биты живут).
    # masked-mark идиома (доказана реальными правилами): (m & ~MASK) | MARK.
    nft add rule "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_MARK" \
        ip daddr "@$WARP_SET" meta mark set mark '&' 0x7fffffff '^' 0x80000000 || return 1
    nft add rule "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_MARK" \
        ip saddr "@$WARP_SET_SRC" meta mark set mark '&' 0x7fffffff '^' 0x80000000 || return 1
    return 0
}

warp_nft_rules_verify() {
    local _c _out
    _z2k_ow_warp_table_ok || return 1
    for _c in "$WARP_CHAIN_MARK" "$WARP_CHAIN_MSS" "$WARP_CHAIN_FWD" "$WARP_CHAIN_NAT"; do
        _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$_c" 2>/dev/null) || return 1
        [ -n "$_out" ] || return 1
    done
    _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_MARK" 2>/dev/null)
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "ip daddr @$WARP_SET meta mark set" || return 1
    printf '%s\n' "$_out" | tr -s ' ' | grep -qF "ip saddr @$WARP_SET_SRC meta mark set" || return 1
    return 0
}

warp_nft_tun_verify() {
    local _iface="$1" _out
    [ -n "$_iface" ] || return 1
    for _c in "$WARP_CHAIN_MSS" "$WARP_CHAIN_FWD" "$WARP_CHAIN_NAT"; do
        _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$_c" 2>/dev/null) || return 1
        [ -n "$_out" ] || return 1
    done
    _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_MSS" 2>/dev/null)
    printf '%s\n' "$_out" | grep -q "oifname .*$_iface.*maxseg size set rt mtu" || return 1
    printf '%s\n' "$_out" | grep -q "iifname .*$_iface.*maxseg size set 1240" || return 1
    _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_FWD" 2>/dev/null)
    printf '%s\n' "$_out" | grep -q "oifname .*$_iface.* accept" || return 1
    _out=$(nft list chain "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_NAT" 2>/dev/null)
    printf '%s\n' "$_out" | grep -q "oifname .*$_iface.* masquerade" || return 1
    return 0
}

warp_nft_sets_verify() {
    local _want _got _list
    _z2k_ow_warp_table_ok || return 1
    _want="$(warp_validated_dst | sed 's#/32$##' | sort -u)"
    _list="$(nft list set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET" 2>/dev/null)" || return 1
    _got="$(printf '%s\n' "$_list" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' | sort -u)"
    [ "$_want" = "$_got" ] || return 1
    _want="$(warp_devices_ips | sort -u)"
    _list="$(nft list set "$Z2K_WARP_NFT_FAMILY" "$Z2K_WARP_NFT_TABLE" "$WARP_SET_SRC" 2>/dev/null)" || return 1
    _got="$(printf '%s\n' "$_list" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' | sort -u)"
    [ "$_want" = "$_got" ]
}

# NAT/FORWARD/MSS для валидированного iface (вызывать ПОСЛЕ проверки имени).
# Convergence ОДНОЙ транзакцией (defect 5): ensure chains + flush dynamic +
# add ровно текущих правил. Повторный tick НЕ копит дубликаты (W40):
# состояние после N применений идентично состоянию после одного.
# Base MARK rules — отдельный слой (warp_nft_rules_apply), здесь не трогаем.
warp_nft_tun_apply() {
    local _iface="$1" _fam="${Z2K_WARP_NFT_FAMILY}" _tab="${Z2K_WARP_NFT_TABLE}"
    [ -n "$_iface" ] || return 1
    # MSS 1240 = engine.MTU(1280)-40 (coupling держит тест с Go-константой):
    # outbound — clamp-to-PMTU, inbound — explicit (НЕ зеркальный PMTU-clamp:
    # дал бы 1460 с LAN-моста; полевое измерение upstream).
    {
        printf 'add chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_MSS"
        printf 'add chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_FWD"
        printf 'add chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_NAT"
        printf 'flush chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_MSS"
        printf 'flush chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_FWD"
        printf 'flush chain %s %s %s\n' "$_fam" "$_tab" "$WARP_CHAIN_NAT"
        printf 'add rule %s %s %s oifname %s tcp flags syn tcp option maxseg size set rt mtu\n' \
            "$_fam" "$_tab" "$WARP_CHAIN_MSS" "$_iface"
        printf 'add rule %s %s %s iifname %s tcp flags syn tcp option maxseg size set 1240\n' \
            "$_fam" "$_tab" "$WARP_CHAIN_MSS" "$_iface"
        printf 'add rule %s %s %s oifname %s accept\n' \
            "$_fam" "$_tab" "$WARP_CHAIN_FWD" "$_iface"
        printf 'add rule %s %s %s oifname %s masquerade\n' \
            "$_fam" "$_tab" "$WARP_CHAIN_NAT" "$_iface"
    } | nft -f - || return 1
    _z2k_ow_warp_mut "NFT_CREATED: tun $WARP_CHAIN_MSS/$WARP_CHAIN_FWD/$WARP_CHAIN_NAT $_iface"
    return 0
}

# Dynamic TUN plumbing в off (no-ready/disable): chains пустые, правил нет.
_warp_tun_clear() {
    local _c
    _z2k_ow_warp_table_ok || return 0
    for _c in "$WARP_CHAIN_MSS" "$WARP_CHAIN_FWD" "$WARP_CHAIN_NAT"; do
        nft flush chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_c" 2>/dev/null || true
    done
    return 0
}

# Marking side effect в off (disable, defect 7/W42): MARK chain пуст —
# пакетная маркировка остановлена. Sets сохраняем как cache, chains —
# для быстрого re-enable (удаляет их только полный stop/remove).
_warp_mark_clear() {
    _z2k_ow_warp_table_ok || return 0
    nft flush chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_CHAIN_MARK" 2>/dev/null || true
    return 0
}

warp_nft_remove() {
    # $1: "full" — снести и sets (remove/uninstall); иначе только chains.
    local _full="${1:-}" _c _s
    _z2k_ow_warp_table_ok || return 0
    for _c in "$WARP_CHAIN_MARK" "$WARP_CHAIN_MSS" "$WARP_CHAIN_FWD" "$WARP_CHAIN_NAT"; do
        nft flush chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_c" 2>/dev/null || true
        nft delete chain "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_c" 2>/dev/null || true
        _z2k_ow_warp_mut "NFT_REMOVED: $_c"
    done
    if [ "$_full" = "full" ]; then
        for _s in "$WARP_SET" "$WARP_SET_SRC"; do
            nft delete set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$_s" 2>/dev/null || true
        done
    fi
    return 0
}

# --- PBR: route+rule только при доказанной ready ---

# iface из ЖИВОГО status (не device.json — там прошлый запуск).
_warp_live_iface() { _json_str "$WARP_STATUS" iface; }
_warp_iface_valid() {
    case "$1" in
        z2ktun[0-9]|z2ktun[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    ip link show dev "$1" >/dev/null 2>&1 || return 1
    return 0
}

# proven ready: status ready=true + ЖИВОЙ matching-процесс + валидный iface.
# (Файл alone врёт после kill -9: defer Remove не выполняется.)
_warp_proven_ready() {
    [ "$(_json_raw "$WARP_STATUS" ready)" = "true" ] || return 1
    warp_running || return 1
    _warp_iface_valid "$(_warp_live_iface)" || return 1
    return 0
}

# Conflict detection ПЕРЕД установкой PBR. Возврат:
#   0 — ставить можно (пусто или ровно наше — идемпотентность);
#   1 — чужой конфликт (FAIL LOUDLY, caller снимает PBR).
# Чужие rules/routes НЕ трогаем никогда. При конфликте взводим
# _WARP_CONFLICT=1, чтобы enable вернул 1 (hard fail), а не 2.
_warp_pbr_check() {
    local _iface="$1" _line _mv _mm _mt _ov _pline
    _WARP_CONFLICT=0
    # Точное наше правило не освобождает от скана: чужой конфликт рядом
    # с нашим = тоже отказ (трафик уже уводят). Нашу exact-строку пропускаем.
    while IFS= read -r _line; do
        case "$_line" in *fwmark*) ;; *) continue ;; esac
        case "$_line" in
            *"fwmark $WARP_MARK/$WARP_MASK lookup $WARP_TABLE"*) continue ;;
        esac
            _mv=$(printf '%s' "$_line" | sed -n 's/.*fwmark \([^ ]*\).*/\1/p' | head -1)
            _mm="${_mv##*/}"; _mv="${_mv%%/*}"
            [ -n "$_mm" ] || _mm="0xffffffff"
            # Числа обязаны парситься (0x понимает и shell); мусор = конфликт
            # (неизвестное не трогаем, но и рядом не встаём).
            case "$_mv$_mm" in *[!0-9a-fA-FxX]*)
                echo "z2k-openwrt: warp: непарсируемый fwmark: $_line" >&2
                _WARP_CONFLICT=1; return 1 ;; esac
            # Overlap: чужое НЕ исключает bit31 положительно
            # (маска покрывает, а значение — нет) => пересечение.
            _ov=0
            if [ "$(( _mm & 0x80000000 ))" != "0" ] && [ "$(( _mv & 0x80000000 ))" = "0" ]; then
                _ov=0
            else
                _ov=1
            fi
            if [ "$_ov" = "1" ]; then
                echo "z2k-openwrt: warp: mark-конфликт: $_line (наш $WARP_MARK/$WARP_MASK)" >&2
                _WARP_CONFLICT=1; return 1
            fi
        done <<EOF_RULES
$(ip rule show 2>/dev/null)
EOF_RULES
    # Pref cardinality (defect 4/W39): 0 (ставить можно) или ровно 1 exact
    # ours. >1 (даже exact-дубликаты — invalid state) или 1 чужой =
    # conflict/corruption: FAIL LOUDLY, чужое не трогаем.
    _pline="$(ip rule show 2>/dev/null | grep -E "^$WARP_RULE_PREF:" || true)"
    if [ -n "$_pline" ]; then
        if [ "$(printf '%s\n' "$_pline" | grep -c .)" -gt 1 ]; then
            echo "z2k-openwrt: warp: pref $WARP_RULE_PREF дублирован — не трогаю" >&2
            _WARP_CONFLICT=1; return 1
        fi
        if printf '%s\n' "$_pline" | grep -qvF "fwmark $WARP_MARK/$WARP_MASK lookup $WARP_TABLE"; then
            echo "z2k-openwrt: warp: pref $WARP_RULE_PREF занят чужим правилом — не трогаю" >&2
            _WARP_CONFLICT=1; return 1
        fi
    fi
    # Таблица: пусто (норма) или ровно наш default на живой iface (adopt).
    # BusyBox ip may leave padding before the newline (the live router emits
    # `default dev z2ktun0 scope link `).  Route ownership is textual, so
    # normalize that harmless presentation detail before the exact check;
    # otherwise a route we just installed is misclassified as foreign.
    _mt="$(ip route show table "$WARP_TABLE" 2>/dev/null | sed 's/[[:space:]]*$//')"
    if [ -n "$_mt" ]; then
        case "$_mt" in
            "default dev $_iface"|"default dev $_iface scope link") ;;
            *)
                echo "z2k-openwrt: warp: table $WARP_TABLE содержит чужое — не трогаю" >&2
                _WARP_CONFLICT=1; return 1 ;;
        esac
    fi
    return 0
}

warp_pbr_down() {
    # Route+rule ПЕРВЫМИ (мгновенный fail-open), затем тишина.
    # Rule: ТОЛЬКО exact owned delete (pref+mark/mask+table, bounded от
    # дубликатов) — чужое не трогаем (defect 4). Legacy unmasked-формы нет:
    # на OpenWrt наше правило всегда ставилось с pref+masked mark.
    _warp_rule_delete_exact || true
    _warp_route_release_owned || true
    rm -f "$WARP_PBR_OWNER" "$WARP_PBR_OWNER".new.* 2>/dev/null
    _z2k_ow_warp_mut "PBR_DOWN"
    return 0
}

# Route delete ТОЛЬКО при доказанном ownership (defect 5, подход A):
# owner-record (mark/mask/pref/table/iface успешного pbr_up) + текущий
# default таблицы в точности наш ("default dev IFACE" [scope link]).
# Mismatch/drift/нет записи/таблица пуста: foreign НЕ трогаем, route НЕ
# удаляем. Критический принцип: сомневаемся -> exact rule уже снят выше
# (traffic fail-open), а без нашего rule чужой default mark-трафик не
# маршрутизирует — он безопаснее удалённого чужого default.
_warp_route_release_owned() {
    local _oiface=""
    [ -f "$WARP_PBR_OWNER" ] || return 0
    _oiface="$(sed -n 's/^iface=//p' "$WARP_PBR_OWNER" 2>/dev/null | head -1)"
    case "$_oiface" in
        z2ktun[0-9]|z2ktun[0-9][0-9]) ;;
        *) return 0 ;;
    esac
    _warp_route_release_iface "$_oiface"
    return 0
}

# Доказательство "текущий default таблицы — ровно наш $1": все строки —
# наш default (иначе drift/чужое: стоим). Пустая таблица: удалять нечего.
_warp_route_release_iface() {
    local _iface="$1" _cur=""
    case "$_iface" in
        z2ktun[0-9]|z2ktun[0-9][0-9]) ;;
        *) return 0 ;;
    esac
    _cur="$(ip route show table "$WARP_TABLE" 2>/dev/null | sed 's/[[:space:]]*$//')"
    [ -n "$_cur" ] || return 0
    if printf '%s\n' "$_cur" | grep -qvE "^default dev $_iface( scope link)?\$"; then
        return 0
    fi
    ip route del default table "$WARP_TABLE" 2>/dev/null || true
    return 0
}

# --- procd ---

warp_start_instance() {
    command -v procd_open_instance >/dev/null 2>&1 || {
        echo "z2k-openwrt: warp: нет procd-контекста (только из start_service)" >&2
        return 1
    }
    local _proxy
    _proxy="$(warp_cfg Z2K_WARP_VPS_PROXY "")"
    [ -n "$_proxy" ] || _proxy="$WARP_VPS_PROXY_DEFAULT"
    procd_open_instance "z2k-warp"
    warp_with_argv _z2k_ow_warp_procd_command
    # procd_set_param env публикует весь параметр одним блоком: повторный
    # вызов заменяет предыдущий набор на BusyBox/OpenWrt, поэтому GODEBUG,
    # выбранный транспорт и релей должны попасть в одну запись. Транспорт
    # остаётся env-параметром: старое бинарное не знает --transport и упадёт
    # на разборе такого флага.
    if [ -n "$_proxy" ]; then
        procd_set_param env \
            GODEBUG=asyncpreemptoff=1 \
            "Z2K_WARP_TRANSPORT=$(warp_transport)" \
            "Z2K_WARP_VPS_PROXY=$_proxy"
    else
        procd_set_param env \
            GODEBUG=asyncpreemptoff=1 \
            "Z2K_WARP_TRANSPORT=$(warp_transport)"
    fi
    procd_set_param pidfile "${Z2K_RUN:-/tmp/z2k/runtime}/warpd.pid"
    # Bounded respawn как TG/RT (доказательство: procd/service/instance.c):
    # threshold 3600 / timeout 5 / retry 5; crash-loop halt'ится, не штормит.
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    _z2k_ow_warp_mut "PROCESS_ACTION: instance z2k-warp opened"
    return 0
}

# --- install/register (CLI) ---

# Дефолт VPS-релея (как S51/z2k-warp.sh; равенство трёх копий — parity-тест).
# В логах URL НЕ появляется никогда (см. warp_register).
WARP_VPS_PROXY_DEFAULT="http://z2kwarp:z2kW4rpR3g2026@213.176.74.63:8119"

# sha256 ожидаемого артефакта из ПРОВЕРЕННОГО манифеста ($1 файл, $2 arch).
_warp_manifest_path() {
    printf 'z2k-warpd/builds/z2k-warpd-linux-%s' "$1"
}

_warp_manifest_sha() {
    if command -v z2k_ow_manifest_file_sha >/dev/null 2>&1; then
        z2k_ow_manifest_file_sha "$1" "$(_warp_manifest_path "$2")" | tr 'A-F' 'a-f'
    else
        return 1
    fi
}

_z2k_ow_manifest_helper_load() {
    command -v z2k_ow_manifest_prepare >/dev/null 2>&1 && return 0
    local _d="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_d/manifest.sh" ] || return 1
    # shellcheck disable=SC1090,SC1091
    . "$_d/manifest.sh"
}

warp_fetch_engine() {
    # WARP_FETCH_STUB — тесты: вместо сети копируется готовый файл.
    local _arch="$1" _tmp="$WARP_BIN.new.$$" _want="" _have=""
    rm -f "$_tmp"
    if [ -n "$WARP_FETCH_STUB" ]; then
        cp "$WARP_FETCH_STUB" "$_tmp"
    else
        # Standalone `warp.sh install` does not pass through update.sh or
        # webpanel's platform bootstrap. Map the package-owned paths before
        # auto_update.sh captures defaults such as Z2K_AU_PUBKEY.
        local _adapter_dir="${Z2K_ADAPTER_DIR:-}"
        if [ -z "$_adapter_dir" ] || [ ! -r "$_adapter_dir/paths.sh" ] || \
           [ ! -r "$_adapter_dir/env.sh" ]; then
            _adapter_dir="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)" || {
                _wlog "cannot locate OpenWrt path environment — refusing"
                rm -f "$_tmp"
                return 1
            }
        fi
        . "$_adapter_dir/paths.sh" >/dev/null 2>&1 || {
            _wlog "cannot load OpenWrt paths — refusing"
            rm -f "$_tmp"
            return 1
        }
        . "$_adapter_dir/env.sh" >/dev/null 2>&1 || {
            _wlog "cannot load OpenWrt environment — refusing"
            rm -f "$_tmp"
            return 1
        }
        # Resolve the one OpenWrt manifest authority. A CI snapshot uses the
        # package-embedded manifest and immutable commit; production uses the
        # signed channel. The helper keeps common hash/download primitives.
        # shellcheck disable=SC1090,SC1091
        . "${Z2K_LIB:-/usr/lib/z2k/lib}/utils.sh" >/dev/null 2>&1 || return 1
        # shellcheck disable=SC1090,SC1091
        . "${Z2K_LIB:-/usr/lib/z2k/lib}/auto_update.sh" >/dev/null 2>&1 || return 1
        _z2k_ow_manifest_helper_load || {
            _wlog "cannot load OpenWrt manifest helper"
            rm -f "$_tmp"
            return 1
        }
        local _md="$_tmp.manifest" _sg="$_tmp.manifest.sig"
        z2k_ow_manifest_prepare "$_md" "$_arch" || {
            _wlog "manifest authority unavailable — refusing"
            rm -f "$_md" "$_sg" "$_tmp"
            return 1
        }
        _want="$(_warp_manifest_sha "$_md" "$_arch")"
        [ -n "$_want" ] || { _wlog "no manifest hash for arch $_arch — refusing"; rm -f "$_md" "$_sg" "$_tmp"; return 1; }
        local _url
        _url=$(z2k_ow_manifest_file_url "$(_warp_manifest_path "$_arch")") || {
            _wlog "manifest source URL unavailable — refusing"
            rm -f "$_md" "$_sg" "$_tmp"
            return 1
        }
        _wlog "скачиваю движок ($_arch, ~7 МБ)..."
        z2k_fetch "$_url" "$_tmp" 2>/dev/null || {
            _wlog "engine download failed"; rm -f "$_md" "$_sg" "$_tmp"; return 1; }
        _have=$(z2k_sha256_file "$_tmp" 2>/dev/null)
        rm -f "$_md" "$_sg"
        [ "$_have" = "$_want" ] || { _wlog "sha256 mismatch for engine ($_arch)"; rm -f "$_tmp"; return 1; }
    fi
    [ -s "$_tmp" ] || { _wlog "engine download failed"; rm -f "$_tmp"; return 1; }
    if [ -z "$WARP_FETCH_STUB" ]; then
        head -c 4 "$_tmp" 2>/dev/null | grep -q ELF || { _wlog "engine is not an ELF"; rm -f "$_tmp"; return 1; }
    fi
    chmod 755 "$_tmp"
    "$_tmp" version >/dev/null 2>&1 || { _wlog "engine does not run on this architecture"; rm -f "$_tmp"; return 1; }
    mkdir -p "$(dirname "$WARP_BIN")" 2>/dev/null
    mv -f "$_tmp" "$WARP_BIN" || { rm -f "$_tmp"; return 1; }
    _wlog "движок установлен: $WARP_BIN"
    return 0
}

warp_arch() {
    # Та же карта, что установщик/апдейтер (map_arch_to_bin_arch -> linux-*),
    # минус префикс: артефакты лежат как z2k-warpd-linux-<arch>.
    # Карту НЕ дублируем: при standalone-запуске (sh warp.sh install из
    # панели, где common utils не подсорсен) подтягиваем её оттуда
    # best-effort. Нет карты вовсе — честный отказ с причиной, а не голое
    # "unsupported architecture" на поддерживаемой арке (live-урок: функция
    # отсутствовала — aarch64 выглядел неподдерживаемым).
    local _hw _ba _ul
    _hw=$(uname -m 2>/dev/null)
    if ! command -v map_arch_to_bin_arch >/dev/null 2>&1; then
        _ul="${Z2K_LIB:-${Z2K_ROOT:-/usr/lib/z2k}/lib}/utils.sh"
        # shellcheck disable=SC1090,SC1091
        [ -f "$_ul" ] && . "$_ul" 2>/dev/null
    fi
    if command -v map_arch_to_bin_arch >/dev/null 2>&1; then
        _ba=$(map_arch_to_bin_arch "$_hw" 2>/dev/null || true)
    else
        echo "z2k-openwrt: warp: нет карты арок (utils.sh недоступен)" >&2
        return 1
    fi
    [ -n "$_ba" ] || { echo "z2k-openwrt: warp: арка $_hw не маппится" >&2; return 1; }
    printf '%s' "${_ba#linux-}"
    return 0
}

warp_register() {
    local _out _proxy
    _proxy="$(warp_cfg Z2K_WARP_VPS_PROXY "")"
    [ -n "$_proxy" ] || _proxy="$WARP_VPS_PROXY_DEFAULT"
    mkdir -p "$(dirname "$WARP_DEVICE")" 2>/dev/null
    if [ -s "$WARP_DEVICE" ]; then
        _wlog "ключ устройства уже есть — проверяю (новое устройство не создаётся)..."
    else
        _wlog "регистрирую устройство (до минуты)..."
    fi
    if _out=$("$WARP_BIN" register --device "$WARP_DEVICE" 2>&1); then
        _wlog "$_out"
    else
        # Причина — код, НЕ proxy-URL (секрет релея в логи не пишем).
        _wlog "напрямую не вышло — пробую через релей..."
        if _out=$("$WARP_BIN" register --device "$WARP_DEVICE" --proxy "$_proxy" 2>&1); then
            _wlog "через релей: зарегистрированы"
        else
            _wlog "register_blocked"
            return 1
        fi
    fi
    chmod 600 "$WARP_DEVICE" 2>/dev/null
    return 0
}

# Пора ли пробовать регистрацию снова (метка ДО попытки).
warp_register_due() {
    local _now _last
    _now=$(date +%s 2>/dev/null) || return 1
    _last=$(cat "$WARP_REG_STAMP" 2>/dev/null)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    [ "$((_now - _last))" -ge "$WARP_REG_RETRY" ]
}

warp_install() {
    warp_op_current || { warp_op_superseded; return 3; }
    warp_lists_migrate || return 1
    local _arch
    _arch=$(warp_arch) || { _wlog "unsupported architecture"; return 1; }
    warp_fetch_engine "$_arch" || return 1
    # Ничего не запускается: только движок на диск и ключ устройства.
    warp_register || return 1
    return 0
}

# Одноразовая уборка manual-пинов удалённого подборщика плеча (портировано
# с OpenWrt-путями; чужие закрепления не трогаем).
warp_unpin_legacy() {
    local _f
    for _f in "${Z2K_STATE:-/etc/z2k/state}/state.tsv" /tmp/z2k-autocircular-state.tsv; do
        [ -n "$_f" ] && [ -f "$_f" ] || continue
        awk -F'\t' -v k="rkn_tcp" -v h="cloudflareclient.com|4" \
            '($1 == k && $2 == h && $5 == "manual") { next } { print }' \
            "$_f" > "$_f.z2k-unpin.$$" 2>/dev/null || { rm -f "$_f.z2k-unpin.$$"; continue; }
        if cmp -s "$_f" "$_f.z2k-unpin.$$"; then
            rm -f "$_f.z2k-unpin.$$"
        else
            chmod 644 "$_f.z2k-unpin.$$" 2>/dev/null
            mv -f "$_f.z2k-unpin.$$" "$_f" 2>/dev/null || rm -f "$_f.z2k-unpin.$$"
            _wlog "снято закрепление плеча, оставленное удалённым подборщиком"
        fi
    done
    return 0
}

# Wait for proven ready (NOT stale: status must be newer than wait start,
# else kill -9 left a ready file of a corpse; defer Remove never runs on SIGKILL).
# A steady-healthy daemon writes on every transition, so fresh ready = live ready.
# Supersession ($2 != "internal"): чужое user-действие в середине ожидания =
# выход 3. Внутренние продолжения (proc-bounce рефреша: $2 = "internal") —
# не новое намерение пользователя, а хвост текущего flow (иначе stale op-file
# убивал бы refresh, W44).
_warp_wait_ready() {
    local _waited=0 _t0 _mt
    _t0=$(date +%s 2>/dev/null || echo 0)
    while [ "$_waited" -lt "${1:-$WARP_READY_WAIT}" ]; do
        if [ "${2:-}" != "internal" ]; then
            warp_op_current || { warp_op_superseded; return 3; }
        fi
        if [ "$(_json_raw "$WARP_STATUS" ready)" = "true" ] && warp_running; then
            if command -v stat >/dev/null 2>&1; then
                _mt=$(stat -c %Y "$WARP_STATUS" 2>/dev/null || echo 0)
                case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
                [ "$_mt" -ge "$_t0" ] || { sleep 2; _waited=$((_waited + 2)); continue; }
            fi
            _warp_iface_valid "$(_warp_live_iface)" && return 0
        fi
        sleep 2; _waited=$((_waited + 2))
    done
    return 1
}

# PBR install: conflict-check + tun-правила + route + rule.
# Требует proven ready у вызывающего ИЛИ проверяет сам (дёшево).
warp_pbr_up() {
    local _mode="${1:-full}" _iface _route_ok=0 _rule_ok=0
    _warp_proven_ready || return 1
    _iface="$(_warp_live_iface)"
    _warp_pbr_check "$_iface" || return 1
    if [ "$_mode" = "repair" ]; then
        warp_nft_tun_verify "$_iface" >/dev/null 2>&1 || warp_nft_tun_apply "$_iface" || return 1
    else
        warp_nft_tun_apply "$_iface" || return 1
    fi
    # Дальше — PBR-мутации: ЛЮБОЙ провал после первой откатываем целиком
    # (defect 3: failed enable обязан fail open, без полу-PBR).
    if ip route show table "$WARP_TABLE" 2>/dev/null | grep -qE "^default dev $_iface( scope link)?$"; then
        _route_ok=1
    fi
    if ip rule show 2>/dev/null | grep -qF "fwmark $WARP_MARK/$WARP_MASK lookup $WARP_TABLE"; then
        _rule_ok=1
    fi
    if [ "$_route_ok" = "0" ]; then
        ip route replace default dev "$_iface" table "$WARP_TABLE" 2>/dev/null || {
            _warp_pbr_rollback "$_iface"; return 1; }
    fi
    if [ "$_rule_ok" = "0" ]; then
        ip rule add pref "$WARP_RULE_PREF" fwmark "$WARP_MARK/$WARP_MASK" table "$WARP_TABLE" 2>/dev/null || {
            _warp_pbr_rollback "$_iface"; return 1; }
    fi
    warp_pbr_owner_verify "$_iface" >/dev/null 2>&1 || \
        _warp_owner_write "$_iface" || { _warp_pbr_rollback "$_iface"; return 1; }
    _z2k_ow_warp_mut "PBR_UP: table $WARP_TABLE pref $WARP_RULE_PREF mark $WARP_MARK/$_iface"
    return 0
}

# Откат незавершённого up (defect 3): снять exact rule (bounded: все
# exact-дубликаты tuple), route — только если текущий default в точности
# только что ставленный наш (под локом конкурентных мутаторов нет; чужой
# drift не трогаем), owner-огрызок удалить. Fail open.
_warp_pbr_rollback() {
    local _iface="$1" _cur=""
    [ -n "$_iface" ] || return 0
    _warp_rule_delete_exact || true
    _cur="$(ip route show table "$WARP_TABLE" 2>/dev/null)"
    if [ -n "$_cur" ] && ! printf '%s\n' "$_cur" | grep -qvE "^default dev $_iface( scope link)?\$"; then
        ip route del default table "$WARP_TABLE" 2>/dev/null || true
    fi
    rm -f "$WARP_PBR_OWNER" "$WARP_PBR_OWNER".new.* 2>/dev/null
    return 0
}

# Bounded-delete всех exact-duplicates нашего tuple (defect 4): ip rule del
# снимает по одному совпадению; >8 — уже не дубликаты, а патология стоим.
_warp_rule_delete_exact() {
    local _n=0
    while [ "$_n" -lt 8 ]; do
        ip rule show 2>/dev/null | grep -qE "^$WARP_RULE_PREF:.*fwmark $WARP_MARK/$WARP_MASK lookup $WARP_TABLE" || return 0
        ip rule del pref "$WARP_RULE_PREF" fwmark "$WARP_MARK/$WARP_MASK" table "$WARP_TABLE" 2>/dev/null || return 0
        _n=$((_n + 1))
    done
    return 0
}

# Owner atomic-write (defect 3): temp -> chmod 600 -> mv. Никаких
# полу-записей: читатель видит либо целый предыдущий, либо целый новый.
_warp_owner_write() {
    local _iface="$1" _tmp="$WARP_PBR_OWNER.new.$$"
    [ -n "$_iface" ] || return 1
    mkdir -p "$(dirname "$WARP_PBR_OWNER")" 2>/dev/null || true
    {
        printf 'mark=%s\nmask=%s\npref=%s\ntable=%s\niface=%s\n' \
            "$WARP_MARK" "$WARP_MASK" "$WARP_RULE_PREF" "$WARP_TABLE" "$_iface"
    } > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    # chmod failure = rollback (defect 2): полу-защищённый owner публиковать
    # нельзя — temp удалить, публикацию не делать, up откатить у вызывающего.
    chmod 600 "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    mv -f "$_tmp" "$WARP_PBR_OWNER" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
    return 0
}

# --- enable/disable/remove ---

# Per-feature mutation lock (defect 8): mkdir-атомарный лок в /tmp (flock
# на target не гарантирован). Сериализует CLI / cron / hotplug / init /
# updater. Берут лок ТОЛЬКО verb entry-points (dispatch + warp-proc.sh);
# внутренние функции — никогда (вложенности нет, дедлока с собой нет).
# `status` read-only — без лока. Fail-safe: bounded wait, stale recovery,
# crash holder'а никого не вешает навсегда.
WARP_LOCK_DIR="${WARP_LOCK_DIR:-${Z2K_TMP:-/tmp/z2k}/warp/mutate.lock}"
WARP_LOCK_STALE_SECS="${WARP_LOCK_STALE_SECS:-300}"
_z2k_ow_warp_lock() {
    local _t="${1:-30}" _waited=0 _owner=""
    case "$_t" in ''|*[!0-9]*) _t=30 ;; esac
    mkdir -p "$(dirname "$WARP_LOCK_DIR")" 2>/dev/null || true
    while ! mkdir "$WARP_LOCK_DIR" 2>/dev/null; do
        # Протухший лок снимаем, но НЕ перепрыгиваем через sleep/timeout
        # (continue мимо них давал вечный спин, если mkdir падает всегда —
        # например, нет parent dir: S9-cleanup поймал это в lc_ops).
        if _warp_lock_stale; then
            rm -rf "$WARP_LOCK_DIR" 2>/dev/null
        fi
        if [ "$_waited" -ge "$_t" ]; then
            # Preemption (supersession): снять чужой STUCK-lock вправе только
            # последнее user-действие; перебитое уступает само через
            # current-checks и никого не убивает.
            if warp_op_current 2>/dev/null && _warp_lock_stale; then
                _owner="$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)"
                if [ -n "$_owner" ] && [ "$_owner" != "$$" ]; then
                    _wlog "предыдущее действие с WARP не отвечает (pid $_owner) — прерываю"
                    kill "$_owner" 2>/dev/null
                fi
                rm -rf "$WARP_LOCK_DIR" 2>/dev/null
                continue
            fi
            return 1
        fi
        sleep 1; _waited=$((_waited + 1))
    done
    printf '%s' "$$" > "$WARP_LOCK_DIR/pid" 2>/dev/null || {
        rm -rf "$WARP_LOCK_DIR" 2>/dev/null; return 1; }
    return 0
}
_z2k_ow_warp_unlock() {
    # Снимает только свой лок (чужой не трогаем никогда).
    local _owner=""
    _owner=$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)
    [ "$_owner" = "$$" ] || return 0
    rm -rf "$WARP_LOCK_DIR" 2>/dev/null
    return 0
}
_warp_lock_stale() {
    # rc 0 = лок протух (можно снять); rc 1 = живой (ждать).
    local _owner="" _mt=0 _now=0
    _owner=$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$_owner" ]; then
        kill -0 "$_owner" 2>/dev/null && return 1
        return 0
    fi
    # PID-записи нет (упал между mkdir и записью): решает возраст; без
    # date/stat чинить нечего гадать — снимаем (иначе вечный дедлок).
    _now=$(date +%s 2>/dev/null || echo 0)
    _mt=$(stat -c %Y "$WARP_LOCK_DIR" 2>/dev/null || echo 0)
    case "$_mt$_now" in *[!0-9]*) return 0 ;; esac
    [ "$((_now - _mt))" -gt "$WARP_LOCK_STALE_SECS" ] && return 0
    return 1
}
_warp_locked() {
    # Выполнить verb "$@" под mutation lock; rc пробрасывается как есть.
    local _rc
    _z2k_ow_warp_lock "${WARP_LOCK_WAIT:-30}" || {
        _wlog "mutation lock busy ($*)"; return 1; }
    "$@"
    _rc=$?
    _z2k_ow_warp_unlock
    return $_rc
}

# User entry-points publish intent before waiting for the feature lock. This
# lets a newer panel action supersede a long restart/enable while the older
# action is still waiting, instead of timing out behind its lock.
_warp_user_locked() {
    local _rc _owner
    warp_op_begin
    _warp_locked "$@"
    _rc=$?
    _owner=$(cat "$WARP_OP_FILE" 2>/dev/null)
    [ "$_owner" = "$$" ] && rm -f "$WARP_OP_FILE" 2>/dev/null
    return $_rc
}

# --- supersession (p-84.18 parity): последнее user-действие побеждает ---
#
# Модель — та же, что upstream (op-file + current-checks), поверх нашего
# mkdir-lock (не копируем их lock целиком): каждое user-действие пишет свой
# pid в op-file; долгие ожидания сверяют его на каждом круге и, увидев чужой,
# выходят с кодом 3 ничего больше не трогая. Короткие участки под замком;
# держатель, застрявший ПОСЛЕ того, как его перебили, снимается новым
# действием (только им — перебитое уступает само).
# User-глаголы (begin): install/enable/disable/remove/restart/license.
# Lifecycle (1/0/rules/check/...) op-file НЕ трогают: иначе cron-тик крал бы
# "текущесть" у долгого пользовательского enable.
WARP_OP_FILE="${WARP_OP_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/op}"
warp_op_begin() {
    mkdir -p "$(dirname "$WARP_OP_FILE")" 2>/dev/null
    printf '%s\n' "$$" > "$WARP_OP_FILE" 2>/dev/null
    return 0
}
# Всё ещё ли это действие последнее (нет op-file = не user-контекст = да).
warp_op_current() {
    [ -f "$WARP_OP_FILE" ] || return 0
    [ "$(cat "$WARP_OP_FILE" 2>/dev/null)" = "$$" ]
}
warp_op_superseded() {
    _wlog "прервано: запущено другое действие с WARP"
    return 3
}

# Реальное procd service state (defect 2): НЕ pidof nfqws2 (мёртвый nfqws2
# при живом сервисе врал бы "остановлен" — enable не reconciles instance,
# disable течёт instance). Прямой ubus-запрос first, init running — fallback.
# Z2K_INIT переопределимо тестам (mock-init).
_z2k_ow_service_running() {
    local _init="${Z2K_INIT:-/etc/init.d/z2k}" _ubus=""
    for _ubus in ubus /sbin/ubus /usr/sbin/ubus; do
        if command -v "$_ubus" >/dev/null 2>&1; then
            "$_ubus" -S call service list 2>/dev/null | grep -q '"z2k":{' && return 0
            return 1
        fi
    done
    [ -x "$_init" ] || return 1
    "$_init" running >/dev/null 2>&1
}

warp_enable() {
    local _was_enabled _need_rebuild
    warp_op_current || { warp_op_superseded; return 3; }
    _was_enabled="$(warp_flag)"
    warp_set_flag 1
    warp_unpin_legacy
    [ -x "$WARP_BIN" ] || { _wlog "движок не установлен"; warp_set_flag 0; return 1; }
    warp_nft_sets_load || { _wlog "списки не загрузились"; warp_set_flag 0; return 1; }
    warp_nft_rules_apply || { _wlog "nft chains не встали"; warp_set_flag 0; return 1; }
    _need_rebuild=0
    if _z2k_ow_service_running && { [ "$_was_enabled" != "1" ] || ! warp_running; }; then
        _need_rebuild=1
    fi
    if [ "$_need_rebuild" = "1" ]; then
        _z2k_ow_warp_service_rebuild || return $?
    else
        _z2k_ow_warp_service_reload
    fi
    _warp_wait_and_pbr
}

# Общий хвост enable/restart: ожидание proven ready (+supersede-checks
# внутри) и PBR. Коды как upstream warp_enable: 0 ready; 2 включено, туннель
# поднимается (флаг остаётся, причина — в статусе); 1 — конфликт foreign
# state (desired-флаг цел); 3 — перебито новым действием.
_warp_wait_and_pbr() {
    local _wrc=0
    _warp_wait_ready "$WARP_READY_WAIT"; _wrc=$?
    # Supersede (3) пробрасываем как есть — это не "не ready", а "нас перебили".
    [ "$_wrc" = "3" ] && return 3
    if [ "$_wrc" = "0" ]; then
        _WARP_CONFLICT=0
        if warp_pbr_up; then
            _wlog "WARP ready: $(_json_str "$WARP_STATUS" transport) $(_json_str "$WARP_STATUS" endpoint)"
            return 0
        fi
        # Конфликт foreign state = hard fail (rc 1, флаг остаётся как desired);
        # иначе — просто не сошлось (rc 2, tick/selfheal доведут).
        [ "$_WARP_CONFLICT" = "1" ] && return 1
        return 2
    fi
    _wlog "не ready за $WARP_READY_WAIT c: $(_json_str "$WARP_STATUS" last_error) (флаг остаётся, selfheal доведёт)"
    return 2
}

# service reload (не restart): procd пересоздаёт instance без bounce чужих.
# ТОЛЬКО если сервис активен (defect 2): на остановленном сервисе intent
# записан, конвергенция — на старте; весь z2k сам НЕ стартуем (W46).
_z2k_ow_warp_service_reload() {
    _z2k_ow_service_running || return 0
    "${Z2K_INIT:-/etc/init.d/z2k}" reload >/dev/null 2>&1 || true
    return 0
}

# Rebuild the owning procd service when the WARP instance must be created or
# removed. The feature lock is released while rc.common runs so its own
# z2k_ow_warp lifecycle calls can acquire it; the caller regains ownership
# before it proceeds to readiness/PBR checks.
_z2k_ow_warp_service_rebuild() {
    local _held=0 _owner=""
    _z2k_ow_service_running || return 0
    _owner=$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)
    [ "$_owner" = "$$" ] && _held=1
    [ "$_held" = "1" ] && _z2k_ow_warp_unlock
    _z2k_ow_warp_service_restart
    if [ "$_held" = "1" ]; then
        _z2k_ow_warp_lock "${WARP_LOCK_WAIT:-30}" || return 1
        warp_op_current || { warp_op_superseded; return 3; }
    fi
    return 0
}

warp_disable() {
    local _was_running
    # Порядок (defect 1): PBR down ПЕРВЫМ -> clears -> flag 0 -> reconcile.
    # Reload при flag=1 пересоздал бы instance (окно "выключен, но работает").
    warp_op_current || { warp_op_superseded; return 3; }
    warp_unpin_legacy
    _was_running=0
    warp_running && _was_running=1
    warp_pbr_down
    _warp_tun_clear
    _warp_mark_clear
    warp_set_flag 0
    if [ "$_was_running" = "1" ] && _z2k_ow_service_running; then
        _z2k_ow_warp_service_rebuild || return $?
    else
        _z2k_ow_warp_service_reload
    fi
    # Invariant: успех disable => процесса нет (а не только flag=0).
    if warp_running; then
        _wlog "disable: процесс всё ещё жив после reconcile"
        return 1
    fi
    return 0
}

# Перезапуск движка со сменой транспорта (панель; контракт как upstream
# warp_restart): PBR down ПЕРВЫМ (трафик напрямую, пока движок встаёт).
# На активном procd-сервисе одного kill недостаточно: instance хранит env,
# поэтому делаем полный service restart, который заново объявляет instance с
# новым Z2K_WARP_TRANSPORT. Лок временно отпускаем, иначе start_service не
# сможет открыть тот же WARP-lock. После restart снова захватываем его и
# сверяем supersession перед PBR. Выключенному нечего перезапускать: выбор
# применится при включении.
warp_restart() {
    warp_op_current || { warp_op_superseded; return 3; }
    if [ "$(warp_flag)" != "1" ]; then
        return 0
    fi
    warp_pbr_down >/dev/null 2>&1 || true
    if warp_running; then
        for _p in $(warp_pids); do _z2k_ow_warp_kill "$_p"; done
    fi
    # procd respawn uses the already-committed instance definition, including
    # its old env. Rebuild that definition through the owning service.
    _z2k_ow_warp_service_rebuild || return $?
    _warp_wait_and_pbr
}

# Ключ WARP+ со stdin — в движок через stdin (не в argv/логи, §9).
# rc-контракт как upstream warp_license: 0 применён, 2 не похож на ключ,
# 3 reject Cloudflare, 4 нет движка. Сеть: напрямую, затем релей.
warp_license() {
    local _key _out _rc _proxy
    [ -x "$WARP_BIN" ] || { _wlog "движок не установлен — нажмите «Установить»"; return 4; }
    _key=$(cat)
    _proxy="$(warp_cfg Z2K_WARP_VPS_PROXY "")"
    [ -n "$_proxy" ] || _proxy="$WARP_VPS_PROXY_DEFAULT"
    _out=$(printf '%s' "$_key" | "$WARP_BIN" license --device "$WARP_DEVICE" 2>&1); _rc=$?
    if [ "$_rc" = "1" ] && [ -n "$_proxy" ]; then
        _wlog "напрямую Cloudflare не ответил — пробую через релей..."
        _out=$(printf '%s' "$_key" | "$WARP_BIN" license --device "$WARP_DEVICE" --proxy "$_proxy" 2>&1); _rc=$?
    fi
    [ -n "$_out" ] && printf '%s\n' "$_out"
    return "$_rc"
}

warp_remove() {
    # Invariant: успех remove ⇒ успех disable (процесса нет, PBR нет) —
    # бинарь удаляем ТОЛЬКО после доказанного off. Провал disable = провал
    # remove, бинарь цел (W51).
    warp_op_current || { warp_op_superseded; return 3; }
    warp_disable || return 1
    rm -f "$WARP_BIN" "$WARP_BIN".new.* 2>/dev/null
    warp_nft_remove full
    _wlog "движок удалён; ключ устройства и списки сохранены"
    return 0
}

# --- selfheal tick (cron) ---

# Death-note: движок исчез без stopped/fatal в логе (SIGKILL/OOM) — след.
warp_note_death() {
    [ -s "$WARP_LOG" ] || return 0
    case "$(tail -n1 "$WARP_LOG" 2>/dev/null)" in
        *" stopped"|*" fatal: "*|*"движок уже запущен"*|*"исчез без остановки"*) return 0 ;;
    esac
    local _pid _why
    _pid=$(_json_raw "$WARP_STATUS" pid)
    _why="причина в логах не записана"
    if [ -n "$_pid" ]; then
        _why=$(dmesg 2>/dev/null | grep "Killed process $_pid " | tail -n1 | sed 's/^\[[^]]*\] *//')
        [ -n "$_why" ] && _why="OOM-killer: $_why" || _why="причина в логах не записана"
    fi
    printf '%s движок исчез без остановки (pid %s): %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${_pid:-?}" "$_why" >> "$WARP_LOG" 2>/dev/null
    return 0
}

# (tick живёт один раз — z2k_ow_warp_check ниже; warp_selfheal-обёртка
# для CLI-диспатча определена рядом с ним.)

# Sets reload только при изменении входов (хеш), без рестарта движка.
warp_nft_sets_reload_if_changed() {
    local _hfile="${Z2K_TMP:-/tmp/z2k}/warp/sets.hash" _h="" _old=""
    mkdir -p "$(dirname "$_hfile")" 2>/dev/null || return 0
    _h="$( { warp_active_lists | while IFS= read -r _wl; do cat "$_wl" 2>/dev/null; done
             [ -s "$WARP_DEVICES_FILE" ] && cat "$WARP_DEVICES_FILE"; } | cksum 2>/dev/null | awk '{print $1}')"
    [ -f "$_hfile" ] && _old=$(cat "$_hfile" 2>/dev/null)
    if [ "$_h" = "$_old" ] && warp_nft_sets_verify >/dev/null 2>&1; then
        return 0
    fi
    # A missing hash marker is not a reason to rewrite healthy kernel state;
    # adopt the live sets after the read-only verifier succeeds.
    if warp_nft_sets_verify >/dev/null 2>&1; then
        printf '%s' "$_h" > "$_hfile" 2>/dev/null || true
        return 0
    fi
    warp_nft_sets_load >/dev/null 2>&1 || return 1
    warp_nft_sets_verify >/dev/null 2>&1 || return 1
    printf '%s' "$_h" > "$_hfile" 2>/dev/null
    return 0
}

# Явный reload списков (CLI): всегда перезаливаем, без хеш-гейта.
warp_reload_lists() {
    warp_lists_migrate || return 1
    warp_nft_sets_load || return 1
    return 0
}

# Live-apply списков, пока фича включена (панель после правок; Stage 6):
# тот же atomic sets_load, никакой второй ipset-реализации. Выключено —
# noop (enable зальёт полностью сам).
# Совпадает с keenetic-вербом `ipset` files/z2k-warp.sh по контракту вызова.
warp_ipset() {
    [ "$(warp_flag)" = "1" ] || return 0
    warp_nft_sets_load || return 1
    return 0
}

# One-shot migrate (CLI): только списки (usque-наследия на OpenWrt нет).
warp_migrate() {
    warp_lists_migrate
}

# CLI-обёртка selfheal (диспатч ниже зовёт warp_selfheal).
warp_selfheal() {
    z2k_ow_warp_check
}

# --- status (key=value для будущей панели/CLI) ---

warp_status() {
    local _installed=0 _running=0 _ready=0 _route_ready=0
    local _entries=0 _devices=0 _error="" _state="off"
    [ -x "$WARP_BIN" ] && _installed=1
    warp_running && _running=1
    _warp_proven_ready >/dev/null 2>&1 && _ready=1
    warp_status_routing_ready >/dev/null 2>&1 && _route_ready=1
    _error="$(warp_last_error)"
    if [ "$(warp_flag)" = "1" ]; then
        if [ -n "$_error" ]; then
            _state=error
        elif [ "$_ready" = "1" ] && [ "$_route_ready" = "1" ]; then
            _state=ready
        elif [ "$_ready" = "1" ]; then
            _state=tunnel
        elif [ "$_running" = "1" ]; then
            _state=connecting
        else
            _state=recovering
        fi
    fi
    _entries=$(nft list set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_SET" 2>/dev/null | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    _devices=$(nft list set "${Z2K_WARP_NFT_FAMILY}" "${Z2K_WARP_NFT_TABLE}" "$WARP_SET_SRC" 2>/dev/null | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    # plan/license — из daemon-sidecars (пишет z2k-warpd license, читаем
    # только факты наличия/типа; сам ключ сюда не попадает никогда, §9):
    # plan — account_type, plan_err — ключ не привязался, license — ключ есть.
    local _acct _plan _plan_err=0 _lic=0
    _acct="$(dirname "$WARP_DEVICE")/account.json"
    _plan=$(_json_str "$_acct" account_type)
    case "$_plan" in *[!a-z_]*) _plan="" ;; esac
    [ -n "$(_json_str "$_acct" error)" ] && _plan_err=1
    [ -s "$(dirname "$WARP_DEVICE")/license" ] && _lic=1
    printf 'installed=%s enabled=%s running=%s ready=%s route_ready=%s state=%s transport=%s endpoint=%s iface=%s addr=%s entries=%s devices=%s error=%s mem=%s plan=%s plan_err=%s license=%s\n' \
        "$_installed" "$(warp_flag)" "$_running" "$_ready" "$_route_ready" "$_state" \
        "$(_json_str "$WARP_STATUS" transport)" "$(_json_str "$WARP_STATUS" endpoint)" \
        "$(_json_str "$WARP_STATUS" iface)" "$(_json_str "$WARP_STATUS" addr)" \
        "$_entries" "$_devices" "$_error" \
        "$(_json_raw "$WARP_STATUS" mem_kb)" "$_plan" "$_plan_err" "$_lic"
}

# --- топология lifecycle ---

# Verb entry-point: мутирующие глаголы идут под per-feature lock (defect 8),
# `status` read-only — мимо лока. Прямые вызовы внутренних warp_* функций
# лока не берут (однопоточные сценарии; кросс-процессные гонки закрыты здесь).
z2k_ow_warp() {
    case "${1:-}" in
        status) warp_status; return $? ;;
        *) _warp_locked _z2k_ow_warp_dispatch "$@" ;;
    esac
}

_z2k_ow_warp_dispatch() {
    case "${1:-}" in
        1)
            # Boot converge: sets + instance; PBR — только если proven ready
            # (на старте почти surely нет; tick доведёт). Boot никогда не
            # валит сервис: sets-load провален -> тихо, tick повторит.
            warp_wanted_boot || return 0
            warp_nft_sets_load >/dev/null 2>&1 || return 0
            warp_nft_rules_apply >/dev/null 2>&1 || return 0
            warp_start_instance >/dev/null 2>&1 || return 0
            if _warp_proven_ready; then
                warp_pbr_up >/dev/null 2>&1 || true
            fi
            ;;
        0)
            # Full stop: PBR down ПЕРВЫМ, затем chains; процесс — через procd.
            warp_pbr_down >/dev/null 2>&1 || true
            warp_nft_remove >/dev/null 2>&1 || true
            ;;
        rules)
            # hotplug/firewall-reload: sets (если изменились; плюс ensure при
            # сносе таблицы — MARK-правилам не на что ссылаться) + base chains;
            # затем dynamic TUN по proven-ready (defect 6: одного route/rule
            # мало — MSS/FWD/NAT тоже восстанавливаем) либо чистое off.
            # Демон не трогаем.
            # Ready-gate (no resurrection; предикат из env.sh).
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            if warp_wanted_boot; then
                warp_nft_sets_reload_if_changed >/dev/null 2>&1 || true
                _warp_sets_ensure_live || { warp_nft_sets_load >/dev/null 2>&1 || return 1; }
                warp_nft_rules_apply >/dev/null 2>&1 || return 1
                if _warp_proven_ready; then
                    warp_nft_tun_apply "$(_warp_live_iface)" >/dev/null 2>&1 || true
                    warp_pbr_verify >/dev/null 2>&1 || {
                        warp_pbr_up >/dev/null 2>&1 || true
                    }
                else
                    _warp_tun_clear >/dev/null 2>&1 || true
                    warp_pbr_down >/dev/null 2>&1 || true
                fi
            else
                warp_pbr_down >/dev/null 2>&1 || true
                warp_nft_remove >/dev/null 2>&1 || true
            fi
            ;;
        proc-bounce)
            # Daemon-only restart: ТОЛЬКО kill (procd поднимает); PBR/rules целы.
            if warp_running; then
                for _p in $(warp_pids); do _z2k_ow_warp_kill "$_p"; done
                _z2k_ow_warp_mut "PROCESS_ACTION: bounced (PBR kept)"
            fi
            ;;
        cleanup)
            # uninstall: всё снять (chains+sets+PBR),filеs — пакет/пользователь.
            warp_pbr_down >/dev/null 2>&1 || true
            warp_nft_remove full >/dev/null 2>&1 || true
            return 0
            ;;
        check)
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            z2k_ow_warp_check
            ;;
        # CLI-глаголы — явный мэппинг + propagation rc (дефисный reload-lists
        # через "warp_$1" не вызовется; хвостовой return 0 глотал бы rc).
        # Лок НЕ здесь (его уже держит z2k_ow_warp-обёртка) — только прямые
        # вызовы; вложенного лока нет.
        install)      warp_install; return $? ;;
        enable)       warp_enable; return $? ;;
        disable)      warp_disable; return $? ;;
        remove)       warp_remove; return $? ;;
        restart)      warp_restart; return $? ;;
        license)      warp_license; return $? ;;
        status)       warp_status; return $? ;;
        selfheal)     warp_selfheal; return $? ;;
        reload-lists) warp_reload_lists; return $? ;;
        ipset)        warp_ipset; return $? ;;
        migrate)      warp_migrate; return $? ;;
        *)
            echo "usage: z2k_ow_warp {1|0|rules|proc-bounce|cleanup|check|install|enable|disable|remove|restart|license|status|selfheal|reload-lists|ipset|migrate}" >&2
            return 1
            ;;
    esac
    return 0
}

# Boot-wanted определён один раз — выше (wanted с ENABLED).

# PBR present-and-valid? Ровно одна exact rule (defect 4: дубликат exact —
# тоже invalid, verify=false), плюс route на живой iface.
warp_pbr_verify() {
    local _iface _n
    _iface="$(_warp_live_iface)"
    [ -n "$_iface" ] || return 1
    _n="$(ip rule show 2>/dev/null | grep -E "^$WARP_RULE_PREF:.*fwmark $WARP_MARK/$WARP_MASK lookup $WARP_TABLE" | grep -c . || true)"
    [ "$_n" = "1" ] || return 1
    ip route show table "$WARP_TABLE" 2>/dev/null | grep -qF "default dev $_iface" || return 1
    return 0
}

# Read-only proof used by the status projection. `ready=true` is the daemon's
# transport proof; this second predicate proves the platform-owned nft/TUN/PBR
# plumbing plus the exact route and owner record are present together.
warp_status_routing_ready() {
    local _iface
    _warp_proven_ready || return 1
    _iface="$(_warp_live_iface)"
    warp_nft_tun_verify "$_iface" >/dev/null 2>&1 || return 1
    warp_pbr_verify >/dev/null 2>&1 || return 1
    warp_pbr_owner_verify "$_iface" >/dev/null 2>&1 || return 1
    return 0
}

warp_pbr_owner_verify() {
    local _iface="$1" _o
    [ -n "$_iface" ] && [ -s "$WARP_PBR_OWNER" ] || return 1
    _o=$(cat "$WARP_PBR_OWNER" 2>/dev/null) || return 1
    printf '%s\n' "$_o" | grep -qxF "mark=$WARP_MARK" || return 1
    printf '%s\n' "$_o" | grep -qxF "mask=$WARP_MASK" || return 1
    printf '%s\n' "$_o" | grep -qxF "pref=$WARP_RULE_PREF" || return 1
    printf '%s\n' "$_o" | grep -qxF "table=$WARP_TABLE" || return 1
    printf '%s\n' "$_o" | grep -qxF "iface=$_iface" || return 1
    return 0
}

# --- health check (cron) ---

# Converge-to-off lite (defect 4): PBR down + dynamic пуст. MARK — параметром:
# "full" (disabled: маркировки нет вовсе) или "keep" (not-ready: desired-слой
# инертен — bit31 без WARP ip-rule route не меняет, см. контракт §8).
_warp_converge_off() {
    warp_pbr_down >/dev/null 2>&1 || true
    _warp_tun_clear >/dev/null 2>&1 || true
    [ "${1:-keep}" = "full" ] && _warp_mark_clear >/dev/null 2>&1
    return 0
}

z2k_ow_warp_check() {
    mkdir -p "${Z2K_TMP:-/tmp/z2k}/warp" 2>/dev/null || return 0
    # Graduated gates (НЕ один wanted: устройству без ключа нужен
    # register-recovery, а не молчаливый converge-to-off).
    [ "$(warp_cfg ENABLED 1)" = "1" ] || { _warp_converge_off full; return 0; }
    [ "$(warp_flag)" = "1" ] || { _warp_converge_off full; return 0; }
    [ -x "$WARP_BIN" ] || { _warp_converge_off keep; return 0; }
    if [ ! -s "$WARP_DEVICE" ]; then
        _warp_converge_off keep
        if warp_register_due; then
            mkdir -p "$(dirname "$WARP_REG_STAMP")" 2>/dev/null
            date +%s > "$WARP_REG_STAMP" 2>/dev/null
            { _wlog "нет ключа — регистрирую"; warp_register; } >>"$WARP_LOG" 2>&1 \
                && _z2k_ow_warp_service_restart
        fi
        return 0
    fi
    if ! warp_running; then
        warp_note_death
        _warp_converge_off keep
        return 0
    fi
    if _warp_proven_ready; then
        local _iface
        _iface="$(_warp_live_iface)"
        # Read-only probes first.  Every repair is tied to the failed layer;
        # healthy MARK/TUN/PBR/owner state performs zero nft/ip/filesystem
        # mutations, even when the tick runs every minute.
        warp_nft_sets_reload_if_changed >/dev/null 2>&1 || true
        if ! warp_nft_rules_verify >/dev/null 2>&1; then
            warp_nft_rules_apply >/dev/null 2>&1 || { _warp_converge_off keep; return 0; }
        fi
        if ! warp_nft_tun_verify "$_iface" >/dev/null 2>&1; then
            warp_nft_tun_apply "$_iface" >/dev/null 2>&1 || { _warp_converge_off keep; return 0; }
        fi
        if ! warp_pbr_verify >/dev/null 2>&1; then
            warp_pbr_up repair >/dev/null 2>&1 || _warp_converge_off keep
        elif ! warp_pbr_owner_verify "$_iface" >/dev/null 2>&1; then
            _warp_owner_write "$_iface" >/dev/null 2>&1 || _warp_converge_off keep
        fi
        warp_nft_sets_verify >/dev/null 2>&1 && \
            warp_nft_rules_verify >/dev/null 2>&1 && \
            warp_nft_tun_verify "$_iface" >/dev/null 2>&1 && \
            warp_pbr_verify >/dev/null 2>&1 && \
            warp_pbr_owner_verify "$_iface" >/dev/null 2>&1 || _warp_converge_off keep
    else
        _warp_converge_off keep
    fi
    return 0
}

_z2k_ow_warp_service_restart() {
    # Как reload: только при активном сервисе (defect 2 — не pidof nfqws2).
    _z2k_ow_service_running || return 0
    "${Z2K_INIT:-/etc/init.d/z2k}" restart >/dev/null 2>&1 || true
    return 0
}

# Sourced by tests to exercise the functions with stubs — skip the dispatch.
[ -n "$Z2K_WARP_SOURCE_ONLY" ] && return 0 2>/dev/null || true

case "${1:-}" in
    install)   _warp_user_locked warp_install ;;
    enable)    _warp_user_locked warp_enable ;;
    disable)   _warp_user_locked warp_disable ;;
    remove)    _warp_user_locked warp_remove ;;
    restart)   _warp_user_locked warp_restart ;;
    license)   _warp_user_locked warp_license ;;
    status)    warp_status ;;
    selfheal)  _warp_user_locked warp_selfheal ;;
    reload-lists) _warp_user_locked warp_reload_lists ;;
    ipset) _warp_user_locked warp_ipset ;;
    migrate)   warp_migrate ;;
    *)
        echo "usage: $0 {install|enable|disable|remove|restart|license|status|selfheal|reload-lists|ipset|migrate}" >&2
        exit 1 ;;
esac
