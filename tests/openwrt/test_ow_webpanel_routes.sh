#!/bin/sh
# tests/openwrt/test_ow_webpanel_routes.sh - parity frontend calls -> api.sh cases.
#
# Ловит класс "фронт зовёт, бэкенд не знает" (живой пример: GET /toggles звал
# telemetry.js, кейса не было ни на одной платформе, фронт молча терпел 404).
# Endpoints извлекаются из CURRENT source (не руками): apiGet/apiPost/
# apiGetText/apiPostText + fetch(API + ...) + динамические /service/, /tunnel/,
# /toggle/ (значения из data-svc/TGGLE-карты/TOGGLE_API_NAME). Каждый обязан
# иметь case в webpanel/cgi/api.sh с тем же методом.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-routes"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
API="$REPO/webpanel/cgi/api.sh"
WWW="$REPO/webpanel/www"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wroutes.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

CASES="$(grep -oE '"(GET|POST) /[^"]+"' "$API")"
[ -n "$CASES" ] || { echo "FAIL[ow-webpanel-routes]: нет кейсов в api.sh" >&2; exit 1; }
has_case() { # $1 METHOD $2 PATH
    printf '%s\n' "$CASES" | grep -qF "\"$1 $2\""
}

# 1. Статические вызовы api*( "<path>[?query]" ).
grep -rhoE '(apiGet|apiPost|apiGetText|apiPostText)\("/[^"]*"' "$WWW/js" "$WWW/app.js" 2>/dev/null > "$T/eps.txt"
: > "$T/seen.txt"
while IFS= read -r _e; do
    _fn="${_e%%(*}"; _p="${_e#*(\"/}"; _p="/${_p%\"}"
    _p="${_p%%\?*}"; _p="${_p%%\&*}"
    [ -n "$_p" ] || continue
    # Динамический префикс ("/service/" + action и т.п.) — разбирается в п.3.
    case "$_p" in */) continue ;; esac
    case "$_fn" in
        apiGet|apiGetText) _m="GET" ;;
        apiPost|apiPostText) _m="POST" ;;
        *) continue ;;
    esac
    grep -qxF "$_m $_p" "$T/seen.txt" 2>/dev/null && continue
    printf '%s %s\n' "$_m" "$_p" >> "$T/seen.txt"
    if has_case "$_m" "$_p"; then _t_ok
    else _t_bad "frontend $_m $_p: нет case в api.sh"; fi
done < "$T/eps.txt"
_n="$(wc -l < "$T/seen.txt" | tr -d ' ')"
if [ "${_n:-0}" -ge 40 ]; then _t_ok
else _t_bad "извлечение вызовов сломалось: всего $_n (ждали >= 40)"; fi

# 2. fetch(API + "<path>") — метод берём любой из двух (challenge/login/import).
grep -rhoE 'fetch\(API \+ "/[^"]*"' "$WWW/js" 2>/dev/null | grep -oE '"/[^"]*"' | tr -d '"' > "$T/fetch.txt"
while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if has_case "GET" "$_p" || has_case "POST" "$_p"; then _t_ok
    else _t_bad "frontend fetch $_p: нет case в api.sh"; fi
done < "$T/fetch.txt"

# 3. Динамические маршруты: значения — из source, а не руками.
# 3a. /service/<action>: apiPost("/service/" + action), action из data-svc="".
grep -rhoE 'data-svc="[a-z]+"' "$WWW/js" 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"' | sort -u > "$T/svc.txt"
while IFS= read -r _a; do
    [ -n "$_a" ] || continue
    if has_case "POST" "/service/$_a"; then _t_ok
    else _t_bad "frontend /service/$_a (data-svc): нет case в api.sh"; fi
done < "$T/svc.txt"
# 3b. /tunnel/<action>: apiPost("/tunnel/" + action), кнопки tg-enable/tg-disable.
for _a in enable disable; do
    if grep -q "tg-$_a" "$WWW/js/pages/toggles.js" 2>/dev/null && has_case "POST" "/tunnel/$_a"; then _t_ok
    else _t_bad "frontend /tunnel/$_a: нет кнопки или case в api.sh"; fi
done
# 3c. /toggle/<name>: apiPost("/toggle/" + TOGGLE_API_NAME[key]).
sed -n '/const TOGGLE_API_NAME = {/,/};/p' "$WWW/js/pages/toggles.js" \
    | grep -oE ': "[a-z-]+"' | grep -oE '"[a-z-]+"' | tr -d '"' | sort -u > "$T/tg.txt"
while IFS= read -r _v; do
    [ -n "$_v" ] || continue
    if has_case "POST" "/toggle/$_v"; then _t_ok
    else _t_bad "frontend /toggle/$_v (TOGGLE_API_NAME): нет case в api.sh"; fi
done < "$T/tg.txt"
# game-warp тумблер идёт мимо карты, прямым вызовом (уже покрыт п.1), но
# карту без него считать битой нельзя: проверяем наличие ключа отдельно.
grep -q 'customd: "customd"' "$WWW/js/pages/toggles.js" || _t_bad "TOGGLE_API_NAME потеряла customd"
# 3d. update status/check: путь в переменной (opts.force ? ... : ...).
if has_case "GET" "/update/status"; then _t_ok
else _t_bad "frontend /update/status: нет case в api.sh"; fi
if has_case "POST" "/update/check"; then _t_ok
else _t_bad "frontend /update/check: нет case в api.sh"; fi

_t_done
