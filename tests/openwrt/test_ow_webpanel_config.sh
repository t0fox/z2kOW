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
trap 'rm -rf "$T"' EXIT INT TERM

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

if ! command -v lighttpd >/dev/null 2>&1; then
    echo "SKIP[ow-webpanel-config]: нет lighttpd на хосте (в CI ставится из apt)"
    echo "SUITE[ow-webpanel-config]: pass=0 fail=0"
    exit 0
fi
note() { printf 'lighttpd %s\n' "$*"; }
note "$("lighttpd" -v 2>&1 | head -1)"

# Позитив: сгенерённый конфиг валиден.
_tout="$(lighttpd -t -f "$_out" 2>&1)"; _trc=$?
if [ "$_trc" = "0" ]; then _t_ok
else _t_bad "lighttpd -t отверг конфиг: $_tout"; fi

# Негативный контроль: несуществующий модуль обязан ронять -t
# (иначе позитив выше — пустышка, проверяющая ничего).
cp "$_out" "$T/bad.conf"
printf '\nserver.modules += ( "mod_no_such_xyz" )\n' >> "$T/bad.conf"
_bout="$(lighttpd -t -f "$T/bad.conf" 2>&1)"; _brc=$?
if [ "$_brc" != "0" ]; then _t_ok
else _t_bad "lighttpd -t принял несуществующий модуль"; fi

_t_done
