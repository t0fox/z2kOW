#!/bin/sh
# tests/openwrt/test_ow_webpanel_package.sh - Stage 6/7: packaging webpanel.
# Статика пакета (без lighttpd на хосте): точные DEPENDS, модули конфига
# против зависимостей, отсутствие Keenetic-путей, init-status, rc-дисциплина.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-package"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpkg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
MK="$REPO/package/openwrt/Makefile"
TPL="$REPO/webpanel/lighttpd.conf"
PINIT="$REPO/package/openwrt/files/etc/init.d/z2k-webpanel"
WPADAPT="$REPO/platform/openwrt/webpanel.sh"

# --- 1. точные DEPENDS z2k-webpanel (mod_cgi/mod_setenv — live-доказанные,
# Stage 8: без них postinst/старт валятся; угадывать имена запрещено) ---
_dep="$(sed -n '/^define Package\/z2k-webpanel$/,/^endef$/p' "$MK" 2>/dev/null | grep -E '^  DEPENDS:=')"
assert_eq "DEPENDS exact" "  DEPENDS:=z2k-adapter +lighttpd +lighttpd-mod-cgi +lighttpd-mod-setenv +lighttpd-mod-alias" "$_dep"

# --- 2. модули конфига: ровно известные; каждый не-базовый покрыт DEPENDS ---
# base-builtin (ядро пакета lighttpd, отдельных -mod пакетов в фиде нет):
# indexfile, dirlisting. Остальные обязаны иметь +lighttpd-mod-X в DEPENDS.
_mods="$(sed -n '/^server.modules = (/,/^)/p' "$TPL" 2>/dev/null | grep -oE '"mod_[a-z]+"' | tr -d '"' | sed 's/^mod_//' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "modules exact set" "alias cgi dirlisting indexfile setenv " "$_mods"
for _m in cgi setenv alias; do
    if printf '%s' "$_dep" | grep -qF "+lighttpd-mod-$_m"; then _t_ok
    else _t_bad "mod_$_m без +lighttpd-mod-$_m в DEPENDS"; fi
done

# --- 3. в шаблоне нет Keenetic runtime-путей (генерированный конфиг едет
# на OpenWrt как есть, вместе с комментариями) ---
_kk="$(grep -nE '/opt/|Entware|ndm' "$TPL" 2>/dev/null || true)"
[ -z "$_kk" ] && _t_ok || _t_bad "keenetic-пути в шаблоне: $_kk"

# --- 4. render-фикстура: подстановки + отсутствие keenetic-путей в выхлопе ---
mkdir -p "$T/etc/z2k/webpanel" "$T/tmp/z2k/runtime" "$T/root/platform/openwrt" "$T/root/www" "$T/bin"
export PATH="$T/bin:$PATH"
ln -s "$WPADAPT" "$T/root/platform/openwrt/webpanel.sh" 2>/dev/null
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "-q get network.lan.ipaddr" ] && printf '192.168.7.1'
EOF
chmod +x "$T/bin/uci"
export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export WP_SETTINGS_DIR="$T/etc/z2k/webpanel" WP_RUN_DIR="$T/tmp/z2k/runtime/webpanel"
export WP_TEMPLATE="$T/tpl.conf" WP_LOG_DIR="$T/tmp/z2k-log" WP_PORT_DEFAULT=8088
cp "$TPL" "$T/tpl.conf"
# shellcheck disable=SC1090,SC1091
. "$T/root/platform/openwrt/webpanel.sh" || { echo "FAIL[ow-webpanel-package]: source" >&2; exit 1; }
_out="$(wp_panel_render)" || _t_bad "render rc"
assert_contains "render: docroot" "$_out" "$T/root/www"
assert_contains "render: bind IP" "$_out" 'server.bind                 = "192.168.7.1"'
assert_contains "render: cgi alias" "$_out" '"/cgi-bin/" => "/usr/lib/z2k/webpanel/cgi/"'
_kko="$(grep -nE '/opt/|Entware' "$_out" 2>/dev/null || true)"
[ -z "$_kko" ] && _t_ok || _t_bad "keenetic-пути в сгенерённом конфиге: $_kko"

# --- 5. init: правдивый status() (ноль инстансов — не running) ---
assert_contains "init: status override" "$PINIT" 'wp_panel_running'
# shellcheck disable=SC1090,SC1091
. "$PINIT" 2>/dev/null || { echo "FAIL[ow-webpanel-package]: init source" >&2; exit 1; }
if status >/dev/null 2>&1; then _t_bad "status: без pidfile — running"; else _t_ok; fi
printf '#!/bin/sh\nsleep 30\n' > "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
chmod +x "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
"$T/tmp/z2k/runtime/webpanel/lighttpd-probe" "$T/tmp/z2k/runtime/webpanel/x" &
_wp_pid=$!
export WP_PIDFILE="$T/run.pid"
printf '%s\n' "$_wp_pid" > "$T/run.pid"
sleep 1
if kill -0 "$_wp_pid" 2>/dev/null; then
    if status 2>/dev/null | grep -q running; then _t_ok; else _t_bad "status: живой процесс — не running"; fi
else
    _t_ok
fi
kill -9 "$_wp_pid" 2>/dev/null
unset WP_PIDFILE

# --- 6. rc-дисциплина слоя: никакого `| tail` перед проверкой rc ---
# (конструкция `cmd | tail; echo $?` возвращает rc tail, не cmd).
_rt="$(grep -rnE '\| *tail' "$WPADAPT" "$PINIT" 2>/dev/null || true)"
[ -z "$_rt" ] && _t_ok || _t_bad "pipe-to-tail в слое: $_rt"

_t_done
