#!/bin/sh
# tests/openwrt/test_ow_webpanel_package.sh - Stage 6/7: package isolation.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-package"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpkg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
MK="$REPO/package/openwrt/Makefile"
TPL="$REPO/webpanel/lighttpd.conf"
PINIT="$REPO/package/openwrt/files/etc/init.d/z2k-webpanel"
WPADAPT="$REPO/platform/openwrt/webpanel.sh"
INSTALLER="$REPO/scripts/openwrt/install.sh"

assert_contains "webpanel postinst exists" "$MK" 'define Package/z2k-webpanel/postinst'
assert_contains "webpanel postinst enables init" "$MK" '/etc/init.d/z2k-webpanel enable'
assert_contains "webpanel postinst starts init" "$MK" '/etc/init.d/z2k-webpanel start'
assert_contains "webpanel postinst verifies running" "$MK" '/etc/init.d/z2k-webpanel running'
assert_not_contains "postinst never manages stock HTTP services" "$MK" 'wp_panel_reconcile_http_listener|/etc/init.d/(lighttpd|uhttpd)|/etc/config/uhttpd'
assert_not_contains "panel init never manages stock HTTP services" "$PINIT" 'wp_panel_reconcile_http_listener|/etc/init.d/(lighttpd|uhttpd)|/etc/config/uhttpd'
assert_not_contains "panel adapter does not load stock service lifecycle code" "$WPADAPT" 'webpanel-lifecycle\.sh'
[ ! -e "$REPO/platform/openwrt/webpanel-lifecycle.sh" ] && _t_ok || _t_bad "stock lighttpd/uhttpd lifecycle helper must not exist"

# OpenWrt APK runs a newly-installed package's /etc/init.d hooks by default.
# Lighttpd is a runtime dependency for the private :8088 instance, so its
# dependency closure is staged without scripts before the normal z2k install.
assert_contains "installer stages Lighttpd dependencies without package hooks" "$INSTALLER" 'apk --no-scripts add --virtual "$WEBPANEL_DEP_SEED"'
assert_contains "installer stages the exact Lighttpd dependency set" "$INSTALLER" 'lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias'
assert_contains "normal z2k package install still runs its hooks" "$INSTALLER" 'apk add z2k-adapter z2k-webpanel'
assert_contains "normal z2k package upgrade still runs its hooks" "$INSTALLER" 'apk add --upgrade z2k-adapter z2k-webpanel'
_seed_line=$(grep -nF 'apk --no-scripts add --virtual "$WEBPANEL_DEP_SEED"' "$INSTALLER" | head -1 | cut -d: -f1)
_fresh_line=$(grep -nF 'apk add z2k-adapter z2k-webpanel' "$INSTALLER" | head -1 | cut -d: -f1)
_upgrade_line=$(grep -nF 'apk add --upgrade z2k-adapter z2k-webpanel' "$INSTALLER" | head -1 | cut -d: -f1)
if [ -n "$_seed_line" ] && [ -n "$_fresh_line" ] && [ -n "$_upgrade_line" ] \
   && [ "$_seed_line" -lt "$_fresh_line" ] && [ "$_seed_line" -lt "$_upgrade_line" ]; then
    _t_ok
else
    _t_bad "dependency hooks are suppressed before both normal z2k transactions"
fi
assert_contains "temporary APK virtual dependency root is removed" "$INSTALLER" 'apk del "$WEBPANEL_DEP_SEED"'

# --- 1. exact webpanel dependencies and shipped lighttpd modules ---
_dep="$(sed -n '/^define Package\/z2k-webpanel$/,/^endef$/p' "$MK" 2>/dev/null | grep -E '^  DEPENDS:=')"
assert_eq "DEPENDS exact" "  DEPENDS:=z2k-adapter +lighttpd +lighttpd-mod-cgi +lighttpd-mod-setenv +lighttpd-mod-alias" "$_dep"
_mods="$(sed -n '/^server.modules = (/,/^)/p' "$TPL" 2>/dev/null | grep -oE '"mod_[a-z]+"' | tr -d '"' | sed 's/^mod_//' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "modules exact set" "alias cgi dirlisting indexfile setenv " "$_mods"
for _m in cgi setenv alias; do
    if printf '%s' "$_dep" | grep -qF "+lighttpd-mod-$_m"; then _t_ok
    else _t_bad "mod_$_m без +lighttpd-mod-$_m в DEPENDS"; fi
done

# --- 2. template has an isolated document root and panel port ---
_kk="$(grep -nE '/opt/|Entware|ndm' "$TPL" 2>/dev/null || true)"
[ -z "$_kk" ] && _t_ok || _t_bad "keenetic-пути в шаблоне: $_kk"
mkdir -p "$T/etc/z2k/webpanel" "$T/tmp/z2k/runtime" "$T/root/platform/openwrt" "$T/root/www" "$T/bin"
export PATH="$T/bin:$PATH"
cp "$WPADAPT" "$T/root/platform/openwrt/webpanel.sh"
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
_rendered="$(wp_panel_render)" || { _t_bad "render rc"; _rendered=""; }
if [ -n "$_rendered" ] && [ -f "$_rendered" ]; then
    cp "$_rendered" "$T/render.conf"
else
    : > "$T/render.conf"
    _t_bad "render: config file missing"
fi
assert_contains "render: docroot" "$T/render.conf" "$T/root/www"
assert_contains "render: dedicated port" "$T/render.conf" 'server.port                 = 8088'
assert_not_contains "render: never claims LuCI ports" "$T/render.conf" 'server.port[[:space:]]*=[[:space:]]*(80|443)([^0-9]|$)'
assert_not_contains "render: never serves stock /www" "$T/render.conf" 'server.document-root[[:space:]]*=[[:space:]]*"/www"'
assert_contains "render: bind IP" "$T/render.conf" 'server.bind                 = "192.168.7.1"'
assert_contains "render: cgi alias" "$T/render.conf" '"/cgi-bin/api" => "/usr/lib/z2k/webpanel/cgi/api.sh"'
_kko="$(grep -nE '/opt/|Entware' "$T/render.conf" 2>/dev/null || true)"
[ -z "$_kko" ] && _t_ok || _t_bad "keenetic-пути в сгенерённом конфиге: $_kko"

# --- 3. service status and shell return-code discipline ---
assert_contains "init: status override" "$PINIT" 'wp_panel_running'
# shellcheck disable=SC1090,SC1091
. "$PINIT" 2>/dev/null || { echo "FAIL[ow-webpanel-package]: init source" >&2; exit 1; }
if status >/dev/null 2>&1; then _t_bad "status: без pidfile — running"; else _t_ok; fi
printf '#!/bin/sh\nexec tail -f /dev/null "$0" "$0" >/dev/null 2>&1\n' > "$T/tmp/z2k/runtime/webpanel/lighttpd-probe"
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

_rt="$(grep -rnE '\| *tail' "$WPADAPT" "$PINIT" 2>/dev/null || true)"
[ -z "$_rt" ] && _t_ok || _t_bad "pipe-to-tail в слое: $_rt"

_t_done
