#!/bin/sh
# tests/openwrt/test_ow_webpanel_config.sh - Stage 6/7: сгенерённый конфиг
# проходит НАСТОЯЩИЙ `lighttpd -t` (не мок).
#
# Именно здесь ловится класс "конфиг не валиден" с живого роутера: неизвестные
# модули, битые директивы, несуществующие пути. Версионный скос приемлем:
# CI ставит lighttpd из apt (1.4.x), прод — 1.4.85; все используемые директивы
# стабильны годами. Без lighttpd на хосте — громкий SKIP (как lua-less).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-config"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wcfg.XXXXXX")" || exit 1
trap 'kill ${_srvpid:-} 2>/dev/null; rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/etc/z2k/webpanel" "$T/tmp/z2k/runtime" "$T/root/platform/openwrt" "$T/root/www" "$T/bin"
export PATH="$T/bin:$PATH"
ln -s "$REPO/platform/openwrt/webpanel.sh" "$T/root/platform/openwrt/webpanel.sh" 2>/dev/null
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "-q get network.lan.ipaddr" ] && printf '192.168.7.1'
EOF
chmod +x "$T/bin/uci"
export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export WP_SETTINGS_DIR="$T/etc/z2k/webpanel" WP_RUN_DIR="$T/tmp/z2k/runtime/webpanel"
export WP_TEMPLATE="$T/tpl.conf" WP_PORT_DEFAULT=8088
unset WP_LOG_DIR
cp "$REPO/webpanel/lighttpd.conf" "$T/tpl.conf"
# shellcheck disable=SC1090,SC1091
. "$T/root/platform/openwrt/webpanel.sh" || { echo "FAIL[ow-webpanel-config]: source" >&2; exit 1; }
_out="$(wp_panel_render)" || { echo "FAIL[ow-webpanel-config]: render" >&2; exit 1; }
mkdir -p "$T/root/www"

if ! command -v lighttpd >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "SKIP[ow-webpanel-config]: нет lighttpd/curl на хосте (в CI ставятся из apt)"
    echo "SUITE[ow-webpanel-config]: pass=0 fail=0"
    exit 0
fi
note() { printf 'lighttpd %s\n' "$*"; }
note "$("lighttpd" -v 2>&1 | head -1)"

# Позитив: сгенерённый конфиг валиден.
_tout="$(lighttpd -t -f "$_out" 2>&1)"; _trc=$?
if [ "$_trc" = "0" ]; then _t_ok
else _t_bad "lighttpd -t отверг конфиг: $_tout"; fi

# Негативный контроль: битый синтаксис обязан ронять -t (иначе позитив
# выше — пустышка). NOTE: несуществующий модуль через server.modules +=
# этот -t НЕ ловит (модули он не грузит — проверено CI-раном); имена модулей
# держит static-assert в test_ow_webpanel_package.sh (точный сет + DEPENDS).
cp "$_out" "$T/bad.conf"
printf '\nthis is not valid lighttpd {{{ \n' >> "$T/bad.conf"
_bout="$(lighttpd -t -f "$T/bad.conf" 2>&1)"; _brc=$?
if [ "$_brc" != "0" ]; then _t_ok
else _t_bad "lighttpd -t принял битый синтаксис"; fi

# --- REAL HTTP integration: настоящий lighttpd на 127.0.0.1, mock api.sh ---
# Доказывает end-to-end routing (чего -t не видит): /cgi-bin/api исполняется,
# PATH_INFO доезжает, исходники не светятся. Mock СПЕЦИАЛЬНО mode 0644:
# interpreter-handler (/bin/sh) +x не требует (доказано live-разбором).
mkdir -p "$T/srv/www" "$T/srv/cgi" "$T/httplog"
printf '<html><head><title>Z2K-WEBPANEL-FIXTURE</title></head><body>hi</body></html>\n' > "$T/srv/www/index.html"
cat > "$T/srv/cgi/api.sh" <<'EOF'
#!/bin/sh
printf 'Content-Type: application/json\r\n\r\n'
printf '{"executed":true,"script_name":"%s","path_info":"%s"}\n' "$SCRIPT_NAME" "$PATH_INFO"
EOF
chmod 644 "$T/srv/cgi/api.sh"
for _d in auth actions platform; do
    printf '#!/bin/sh\n# SECRET-SOURCE-MARKER-%s\n' "$_d" > "$T/srv/cgi/$_d.sh"
    chmod 644 "$T/srv/cgi/$_d.sh"
done
# live-конфиг из шаблона под фикстуру: свой docroot уже есть ($T/root/www
# с index? нет — кладём маркер и туда), bind/порт/логи/pid — локальные,
# alias-цель — фикстурный cgi-каталог.
printf '<html><head><title>Z2K-WEBPANEL-FIXTURE</title></head><body>hi</body></html>\n' > "$T/root/www/index.html"
sed -e 's|^server.bind .*|server.bind = "127.0.0.1"|' \
    -e "s|^server.port .*|server.port = 18080|" \
    -e "s|/tmp/z2k/logs/z2k-webpanel-error.log|$T/httplog/error.log|" \
    -e "s|/var/run/z2k-webpanel.pid|$T/httplog/pid|" \
    -e "s|/usr/lib/z2k/webpanel/cgi/|$T/srv/cgi/|" \
    "$_out" > "$T/live.conf"
_http_get() {
    # $1 port $2 path -> тело в http-body.txt; rc=0 только при HTTP 200
    _code="$(curl -s -o "$T/http-body.txt" -w '%{http_code}' --max-time 10 "http://127.0.0.1:$1$2" 2>/dev/null)" || return 1
    [ "$_code" = "200" ]
}
_srv_start() {
    # $1 conf $2 port; rc=0 если static-маркер отвечает (до 3 попыток —
    # медленные раннеры стартуют lighttpd дольше секунды).
    lighttpd -D -f "$1" >/dev/null 2>&1 &
    _srvpid=$!
    _try=0
    while [ "$_try" -lt 3 ]; do
        sleep 1
        if _http_get "$2" "/" && grep -q "Z2K-WEBPANEL-FIXTURE" "$T/http-body.txt" 2>/dev/null; then
            return 0
        fi
        _try=$((_try + 1))
    done
    kill "$_srvpid" 2>/dev/null
    return 1
}
_srv_stop() {
    kill "$_srvpid" 2>/dev/null
    sleep 1
    kill -9 "$_srvpid" 2>/dev/null
    if kill -0 "$_srvpid" 2>/dev/null; then
        _t_bad "lighttpd не остановился"
    else
        _t_ok
    fi
}
trap 'kill ${_srvpid:-} 2>/dev/null; rm -rf "$T"' EXIT INT TERM
if ! _srv_start "$T/live.conf" 18080; then
    _t_bad "live lighttpd не встал (лог: $(tail -5 "$T/httplog/error.log" 2>/dev/null | tr '\n' '|'))"
else
    # 1-2. endpoint'ы исполняют mock (0644!): JSON бывает только из выполнения
    # (файла /cgi-bin/api на диске нет — статике отдать нечего).
    if _http_get 18080 "/cgi-bin/api" && grep -q '"executed":true' "$T/http-body.txt" \
        && grep -q 'cgi-bin/api' "$T/http-body.txt"; then _t_ok
    else _t_bad "GET /cgi-bin/api не исполнил mock"; fi
    if _http_get 18080 "/cgi-bin/api/status" && grep -q '"path_info":"/status"' "$T/http-body.txt"; then _t_ok
    else _t_bad "GET /cgi-bin/api/status без PATH_INFO=/status"; fi
    # 3. исходники НЕ светятся: прямые .sh — 404 без маркеров.
    for _d in api auth actions platform; do
        if curl -s -o "$T/http-body.txt" -w '%{http_code}' --max-time 10 \
                "http://127.0.0.1:18080/cgi-bin/$_d.sh" 2>/dev/null | grep -q '^404$' \
            && ! grep -q "SECRET-SOURCE-MARKER" "$T/http-body.txt" 2>/dev/null; then _t_ok
        else _t_bad "source disclosure: /cgi-bin/$_d.sh"; fi
    done
    _srv_stop
fi
# 4. Негативный контроль: СТАРЫЙ глобальный directory-alias в той же
# фикстуре обязан ПРОВАЛИТЬ routing-тест (иначе тест не отличит фикс от
# бага: на живом роутере глобальный alias давал 404 на endpoint'ах + 200
# с исходниками). NB: alias обязан быть ГЛОБАЛЬНЫМ, как в живом баге —
# внутри conditional он безвреден (conditional его и ограничивает).
sed -e '/^    alias\.url = ($/,+2d' "$T/live.conf" > "$T/live-bad.conf"
printf '\nalias.url += (\n    "/cgi-bin/" => "%s/srv/cgi/"\n)\n' "$T" >> "$T/live-bad.conf"
sed -i 's|^server.port .*|server.port = 18081|' "$T/live-bad.conf"
if ! _srv_start "$T/live-bad.conf" 18081; then
    _t_bad "negative-конфиг не встал (ожидался живой сервер с битым роутингом)"
else
    if _http_get 18081 "/cgi-bin/api/status" && grep -q '"path_info":"/status"' "$T/http-body.txt" 2>/dev/null; then
        _t_bad "старый directory-alias тоже роутит API (тест не отличает фикс)"
    else
        _t_ok
    fi
    if curl -s --max-time 10 "http://127.0.0.1:18081/cgi-bin/api.sh" 2>/dev/null | grep -q "SECRET-SOURCE-MARKER"; then
        _t_ok
    else
        _t_bad "negative-фикстура не воспроизводит source disclosure"
    fi
    _srv_stop
fi
_srvpid=""
_t_done
