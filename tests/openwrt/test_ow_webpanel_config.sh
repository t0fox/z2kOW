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
PINIT="$REPO/package/openwrt/files/etc/init.d/z2k-webpanel"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wcfg.XXXXXX")" || exit 1
trap 'for _p in ${_srvpid:-} ${_panel_pid:-} ${_foreign_pid:-}; do [ -n "$_p" ] && kill "$_p" 2>/dev/null; done; rm -rf "$T"' EXIT INT TERM

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
trap 'for _p in ${_srvpid:-} ${_panel_pid:-} ${_foreign_pid:-}; do [ -n "$_p" ] && kill "$_p" 2>/dev/null; done; rm -rf "$T"' EXIT INT TERM
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
    # Disclosure доказываем через auth.sh: у api.sh в фикстуре JSON-mock
    # (маркера в нём нет by design — его-то endpoint и проверяем выше).
    if curl -s --max-time 10 "http://127.0.0.1:18081/cgi-bin/auth.sh" 2>/dev/null | grep -q "SECRET-SOURCE-MARKER"; then
        _t_ok
    else
        _t_bad "negative-фикстура не воспроизводит source disclosure"
    fi
    _srv_stop
fi
_srvpid=""

# --- LuCI ownership + address-aware port ownership (real kernel sockets) ---
# Start actual lighttpd listeners on high test ports. A foreign listener on a
# different specific IPv4 may coexist with the panel; same-address and
# wildcard listeners must make the production start_service fail before procd.
mkdir -p "$T/srv/www" "$T/httplog"
printf 'Z2K-PANEL-LISTENER\n' > "$T/root/www/index.html"
printf 'FOREIGN-LISTENER\n' > "$T/srv/www/index.html"
sed -i "s|/tmp/z2k/logs/z2k-webpanel-error.log|$T/httplog/panel-error.log|" "$T/tpl.conf"
sed -i "s|/var/run/z2k-webpanel.pid|$T/httplog/panel.pid|" "$T/tpl.conf"
WP_LOG_DIR="$T/httplog"
WP_PIDFILE="$T/httplog/panel.pid"
_make_listener_conf() {
    _bind="$1" _port="$2" _name="$3"
    sed -e "s|^server.bind .*|server.bind = \"$_bind\"|" \
        -e "s|^server.port .*|server.port = $_port|" \
        -e "s|^server.errorlog .*|server.errorlog = \"$T/httplog/$_name-error.log\"|" \
        -e "s|^server.pid-file .*|server.pid-file = \"$T/httplog/$_name.pid\"|" \
        -e "s|^server.document-root .*|server.document-root = \"$T/srv/www\"|" \
        "$_out" > "$T/$_name.conf"
}
_wait_marker() {
    _addr="$1" _port="$2" _marker="$3" _try=0
    while [ "$_try" -lt 5 ]; do
        _code="$(curl -sS --noproxy '*' -o "$T/probe.body" -w '%{http_code}' \
            --max-time 3 "http://$_addr:$_port/" 2>/dev/null)" || _code=""
        if [ "$_code" = "200" ] && grep -qF "$_marker" "$T/probe.body"; then return 0; fi
        sleep 1
        _try=$((_try + 1))
    done
    return 1
}
_make_listener_conf 127.0.0.2 18082 foreign-split
lighttpd -D -f "$T/foreign-split.conf" > "$T/httplog/foreign-split.out" 2>&1 &
_foreign_pid=$!
if _wait_marker 127.0.0.2 18082 FOREIGN-LISTENER; then
    _foreign_sum="$(cksum "$T/foreign-split.conf" | awk '{print $1 ":" $2}')"
    printf '127.0.0.1\n' > "$WP_SETTINGS_DIR/bind"
    printf '18082\n' > "$WP_SETTINGS_DIR/port"
    . "$PINIT" 2>/dev/null || _t_bad "init source for port lifecycle"
    procd_open_instance() { _procd_open=$((_procd_open + 1)); }
    procd_set_param() {
        if [ "$1" = command ]; then _panel_cfg="$5"; fi
        return 0
    }
    procd_close_instance() { return 0; }
    _procd_open=0 _panel_cfg=""
    start_service > "$T/split-start.out" 2>&1
    _start_rc=$?
    if [ "$_start_rc" = 0 ] && [ "$_procd_open" = 1 ] && [ -n "$_panel_cfg" ]; then _t_ok
    else _t_bad "different-IPv4 listener rejected by production start_service: $(cat "$T/split-start.out")"; fi
    if [ "$_start_rc" = 0 ] && [ -n "$_panel_cfg" ]; then
        lighttpd -D -f "$_panel_cfg" > "$T/httplog/panel-split.out" 2>&1 &
        _panel_pid=$!
        _srvpid=$_panel_pid
        if _wait_marker 127.0.0.1 18082 Z2K-PANEL-LISTENER; then _t_ok
        else _t_bad "panel failed to bind same port on a distinct IPv4: $(cat "$T/httplog/panel-split.out")"; fi
        if _wait_marker 127.0.0.2 18082 FOREIGN-LISTENER && kill -0 "$_foreign_pid" 2>/dev/null; then _t_ok
        else _t_bad "foreign listener changed when panel used same numeric port"; fi
        kill "$_panel_pid" 2>/dev/null
        wait "$_panel_pid" 2>/dev/null
        _panel_pid="" _srvpid=""
        if _wait_marker 127.0.0.2 18082 FOREIGN-LISTENER \
            && [ "$_foreign_sum" = "$(cksum "$T/foreign-split.conf" | awk '{print $1 ":" $2}')" ]; then _t_ok
        else _t_bad "panel stop changed foreign listener or config"; fi
    fi
    kill "$_foreign_pid" 2>/dev/null
    wait "$_foreign_pid" 2>/dev/null
    _foreign_pid=""
else
    _t_bad "could not start foreign listener on 127.0.0.2:18082"
    kill "$_foreign_pid" 2>/dev/null
    wait "$_foreign_pid" 2>/dev/null
    _foreign_pid=""
fi

# Same-address and IPv4 wildcard conflicts fail before procd without touching
# the real foreign process or its configuration.
_assert_foreign_conflict() {
    _foreign_bind="$1" _panel_bind="$2" _port="$3" _name="$4" _probe="$5"
    _make_listener_conf "$_foreign_bind" "$_port" "$_name"
    lighttpd -D -f "$T/$_name.conf" > "$T/httplog/$_name.out" 2>&1 &
    _foreign_pid=$!
    if ! _wait_marker "$_probe" "$_port" FOREIGN-LISTENER; then
        _t_bad "$_name foreign listener did not start"
        kill "$_foreign_pid" 2>/dev/null
        wait "$_foreign_pid" 2>/dev/null
        _foreign_pid=""
        return
    fi
    _foreign_sum="$(cksum "$T/$_name.conf" | awk '{print $1 ":" $2}')"
    printf '%s\n' "$_panel_bind" > "$WP_SETTINGS_DIR/bind"
    printf '%s\n' "$_port" > "$WP_SETTINGS_DIR/port"
    : > "$T/procd.log"
    _procd_open=0 _panel_cfg=""
    start_service > "$T/$_name-start.out" 2>&1
    _start_rc=$?
    if [ "$_start_rc" != 0 ] && grep -q "порт $_port занят чужим процессом" "$T/$_name-start.out"; then _t_ok
    else _t_bad "$_name conflict did not fail loudly: $(cat "$T/$_name-start.out")"; fi
    if [ "$_procd_open" = 0 ] && [ -z "$_panel_cfg" ]; then _t_ok
    else _t_bad "$_name conflict reached procd"; fi
    if kill -0 "$_foreign_pid" 2>/dev/null \
        && _wait_marker "$_probe" "$_port" FOREIGN-LISTENER \
        && [ "$_foreign_sum" = "$(cksum "$T/$_name.conf" | awk '{print $1 ":" $2}')" ]; then _t_ok
    else _t_bad "$_name conflict changed foreign listener or config"; fi
    kill "$_foreign_pid" 2>/dev/null
    wait "$_foreign_pid" 2>/dev/null
    _foreign_pid=""
}
_assert_foreign_conflict 127.0.0.1 127.0.0.1 18083 foreign-exact 127.0.0.1
_assert_foreign_conflict 0.0.0.0 127.0.0.1 18084 foreign-wildcard 127.0.0.1

_t_done
