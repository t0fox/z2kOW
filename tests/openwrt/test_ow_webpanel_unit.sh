#!/bin/sh
# tests/openwrt/test_ow_webpanel_unit.sh - Stage 6 Layer B: platform adapter unit.
# Функции platform/openwrt/webpanel.sh на фикстурах, без CGI и lighttpd.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-unit"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpu.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/platform/openwrt" "$T/etc/z2k/webpanel" "$T/tmp/z2k/runtime" "$T/bin"
export PATH="$T/bin:$PATH"
ln -s "$REPO/platform/openwrt/webpanel.sh" "$T/root/platform/openwrt/webpanel.sh" 2>/dev/null
# uci-stub: только network.lan.ipaddr (остальное — пусто/rc!=0), как настоящий.
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
# stub: только network.lan.ipaddr (MOCK_LAN_ABSENT=1 — ключа нет).
if [ "$1 $2 $3" = "-q get network.lan.ipaddr" ]; then
    [ -n "${MOCK_LAN_ABSENT:-}" ] && exit 1
    printf '%s' "${MOCK_LAN_IP:-192.168.7.1}"
else
    exit 1
fi
EOF
chmod +x "$T/bin/uci"
export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export WP_SETTINGS_DIR="$T/etc/z2k/webpanel" WP_RUN_DIR="$T/tmp/z2k/runtime/webpanel"
export WP_TEMPLATE="$T/tpl.conf" WP_PORT_DEFAULT=8088
# shellcheck disable=SC1090,SC1091
. "$T/root/platform/openwrt/webpanel.sh" || { echo "FAIL[ow-webpanel-unit]: source" >&2; exit 1; }
cp "$REPO/webpanel/lighttpd.conf" "$T/tpl.conf"

# --- lan: IPv4 из uci, имя сети — отказ (lighttpd bind="lan" не стартует) ---
# NOTE: MOCK_* обязаны быть export'ed: uci-stub — внешний процесс, через
# subshell $(...) до него доходят только экспортированные переменные
# (shell-функции видят и неэкспортные — в этом разница с прямым вызовом).
assert_eq "lan из uci" "192.168.7.1" "$(wp_lan_ip)"
# CIDR-суффикс uci с живого роутера (Stage 8 live-дефект) — снимается.
# IP специально НЕ дефолтный: иначе тест зелёный и без strip (вакцина).
export MOCK_LAN_IP="10.20.30.40/24"
assert_eq "lan CIDR strip" "10.20.30.40" "$(wp_lan_ip)"
export MOCK_LAN_IP="lan"
wp_lan_ip >/dev/null 2>&1 && _t_bad "lan: имя принято" || _t_ok
export MOCK_LAN_IP="192.168.7.999/24"
wp_lan_ip >/dev/null 2>&1 && _t_bad "lan: октет 999 принят" || _t_ok
unset MOCK_LAN_IP
export MOCK_LAN_ABSENT=1
wp_lan_ip >/dev/null 2>&1 && _t_bad "lan: без uci принят" || _t_ok
unset MOCK_LAN_ABSENT
# fallback-seam: uci нет в PATH, явный путь через WP_UCI_BIN (как /sbin/uci
# в урезанном postinst-PATH; фикстура вместо настоящего /sbin, host PATH
# не задействован).
mkdir -p "$T/fake-sbin"
cat > "$T/fake-sbin/uci" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "-q get network.lan.ipaddr" ] && printf '10.11.12.13/24'
EOF
chmod +x "$T/fake-sbin/uci"
assert_eq "lan fallback-seam" "10.11.12.13" "$(PATH="/usr/bin:/bin" WP_UCI_BIN="$T/fake-sbin/uci" wp_lan_ip)"

# --- render: настройки только если отсутствуют (WP2/WP3) ---
_out="$(wp_panel_render)" || _t_bad "render rc"
assert_eq "render печатает путь" "$T/tmp/z2k/runtime/webpanel/lighttpd.conf" "$_out"
assert_eq "port default записан" "8088" "$(cat "$T/etc/z2k/webpanel/port")"
assert_eq "bind из LAN" "192.168.7.1" "$(cat "$T/etc/z2k/webpanel/bind")"
assert_contains "render: bind подставлен" "$_out" 'server.bind'
if grep -q '@[A-Z_]*@' "$_out"; then _t_bad "render: остался плейсхолдер"; else _t_ok; fi
assert_contains "render: PLATFORM_ENV" "$_out" 'Z2K_PLATFORM'
assert_contains "render: docroot" "$_out" "$T/root/www"
# повторный render не сбрасывает ручные настройки:
printf '9090\n' > "$T/etc/z2k/webpanel/port"
printf '10.9.9.9\n' > "$T/etc/z2k/webpanel/bind"
_out2="$(wp_panel_render)" || _t_bad "render2 rc"
assert_contains "render2: порт сохранён" "$_out2" '9090'
assert_contains "render2: bind сохранён" "$_out2" '10.9.9.9'
# template update (WP4): новый шаблон -> новый конфиг тем же render:
printf '# v2\n' >> "$T/tpl.conf"
_out3="$(wp_panel_render)" || _t_bad "render3 rc"
assert_contains "render3: шаблон обновлён" "$_out3" '# v2'
# битый шаблон (нет файла) -> отказ, старый конфиг цел:
WP_TEMPLATE="$T/tpl-no-such-file.conf"
if wp_panel_render >/dev/null 2>&1; then _t_bad "render: битый принят"; else _t_ok; fi
WP_TEMPLATE="$T/tpl.conf"
# render создаёт каталог errorlog (lighttpd без него не открывает лог):
_out4="$(WP_LOG_DIR="$T/tmp/z2k-log" wp_panel_render)" || _t_bad "render4 rc"
[ -d "$T/tmp/z2k-log" ] && _t_ok || _t_bad "render: лог-каталог не создан"
# render маппит CGI декларативно (alias, без симлинков в document-root):
assert_contains "render: cgi alias" "$_out4" '"/cgi-bin/" => "/usr/lib/z2k/webpanel/cgi/"'
# мусор в bind (имя сети вместо IP — артефакт старого wp_lan_ip) -> громкий
# отказ, а не конфиг с bind="lan", умирающий глубоко в lighttpd:
printf 'lan\n' > "$T/etc/z2k/webpanel/bind"
if WP_LOG_DIR="$T/tmp/z2k-log" wp_panel_render >/dev/null 2>&1; then _t_bad "render: мусорный bind принят"; else _t_ok; fi
printf '10.9.9.9\n' > "$T/etc/z2k/webpanel/bind"

# --- validate: mock lighttpd (коды как настоящий -tt) ---
cat > "$T/bin/lighttpd" <<EOF
#!/bin/sh
echo "mock-lighttpd:\$*" >> "$T/lighttpd.log"
[ "\${MOCK_TT_RC:-0}" = "0" ]
EOF
chmod +x "$T/bin/lighttpd"
wp_panel_validate "$_out3" >/dev/null 2>&1 && _t_ok || _t_bad "validate rc 0"
export MOCK_TT_RC=1
wp_panel_validate "$_out3" >/dev/null 2>&1 && _t_bad "validate принял битый" || _t_ok
unset MOCK_TT_RC

# --- running: pidfile + cmdline-match (WP22-наблюдаемость без procd) ---
# Портативно: sh-скрипт с lighttpd в пути внутри run dir (без exec -a; без
# копирования multicall-бинарей — uutils по argv[0] не заведётся).
export WP_PIDFILE="$T/run.pid"
printf '#!/bin/sh\nsleep 30\n' > "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
chmod +x "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
# argv[0]=/bin/sh, argv[1]=путь (содержит lighttpd), argv[2]=run dir:
# порядок совпадает с продом (lighttpd ... -f <run dir>/...).
"$T/tmp/z2k/runtime/webpanel/lighttpd-probe" "$T/tmp/z2k/runtime/webpanel/x" &
_wp_pid=$!
echo "$_wp_pid" > "$T/run.pid"
sleep 1
if kill -0 "$_wp_pid" 2>/dev/null; then
    wp_panel_running && _t_ok || _t_bad "running: живой процесс не опознан"
else
    _t_ok
fi
kill -9 "$_wp_pid" 2>/dev/null
printf '999999\n' > "$T/run.pid"
wp_panel_running && _t_bad "running: мёртвый pid опознан" || _t_ok
rm -f "$T/run.pid"
wp_panel_running && _t_bad "running: без pidfile опознан" || _t_ok
unset WP_PIDFILE

# --- port: free / ours / foreign (WP21) ---
export WP_PIDFILE="$T/run.pid"
assert_eq "port: свободен" "0" "$(wp_port_free_or_ours 18099; echo $?)"
printf '#!/bin/sh\nsleep 30\n' > "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
chmod +x "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
"$T/tmp/z2k/runtime/webpanel/lighttpd-probe" "$T/tmp/z2k/runtime/webpanel/x" &
_wp_pid=$!
echo "$_wp_pid" > "$T/run.pid"
sleep 1
if kill -0 "$_wp_pid" 2>/dev/null; then
    assert_eq "port: свой процесс" "0" "$(wp_port_free_or_ours 18099; echo $?)"
fi
kill -9 "$_wp_pid" 2>/dev/null
rm -f "$T/run.pid"
cat > "$T/bin/ss" <<'EOF'
#!/bin/sh
printf 'LISTEN 0 128 *:18099 *:* users:(("foreign",pid=1,fd=3))\n'
EOF
chmod +x "$T/bin/ss"
wp_port_free_or_ours 18099 >/dev/null 2>&1 && _t_bad "port: чужой пропущен" || _t_ok
rm -f "$T/bin/ss"
unset WP_PIDFILE

# --- neighbors: TSV-формат, fallback'и, on-флаг ---
# ARP фиксируем пустым файлом (хостовый /proc/net/arp иначе шумит).
mkdir -p "$T/warp"
printf 'aa:bb:cc:dd:ee:ff\n' > "$T/warp/devices.txt"
export WARP_LISTS_DIR="$T/warp" WP_DHCP_LEASES="$T/leases" WP_ARP_PATH="$T/arp-empty"
: > "$T/arp-empty"
printf '1721000000 aa:bb:cc:dd:ee:ff 192.168.7.50 myphone 01:aa:bb:cc:dd:ee:ff\n' > "$T/leases"
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "-4" ]; then
    printf '192.168.7.50 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n'
    printf '192.168.7.60 dev br-lan lladdr 11:22:33:44:55:66 STALE\n'
fi
exit 0
EOF
chmod +x "$T/bin/ip"
_SEP="$(printf '\037')"
_out="$(wp_neighbors)"
printf '%s' "$_out" > "$T/nb.log"
assert_eq "neighbors: две строки" "2" "$(grep -c . "$T/nb.log" || true)"
assert_contains "neighbors: label из leases" "$T/nb.log" "myphone"
assert_eq "neighbors: on-флаг" "1" "$(awk -F"$_SEP" '$1=="aa:bb:cc:dd:ee:ff"{print $6}' "$T/nb.log")"
assert_eq "neighbors: stale не active" "0" "$(awk -F"$_SEP" '$1=="11:22:33:44:55:66"{print $5}' "$T/nb.log")"
_ln1="$(printf '%s' "$_out" | head -1)"
_nf="$(printf '%s' "$_ln1" | tr -dc '\037' | wc -c | tr -d ' ')"
assert_eq "neighbors: 6 полей" "5" "$_nf"
# без ip: только arp-источники; label никогда не пуст (mac fallback, не выдумка):
rm -f "$T/bin/ip"
_out2="$(wp_neighbors)"
if printf '%s' "$_out2" | awk -F"$_SEP" 'NF && NF!=6{bad=1} $3==""{bad=1} END{exit bad?1:0}'; then
    _t_ok
else
    _t_bad "neighbors: битая форма без ip"
fi

_t_done
