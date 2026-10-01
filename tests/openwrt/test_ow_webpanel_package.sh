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
WPLIFE="$REPO/platform/openwrt/webpanel-lifecycle.sh"

assert_contains "webpanel postinst exists" "$MK" 'define Package/z2k-webpanel/postinst'
assert_contains "webpanel postinst enables init" "$MK" '/etc/init.d/z2k-webpanel enable'
assert_contains "webpanel postinst starts init" "$MK" '/etc/init.d/z2k-webpanel start'
assert_contains "webpanel postinst verifies running" "$MK" '/etc/init.d/z2k-webpanel running'
assert_contains "webpanel postinst restores management listener" "$MK" 'wp_panel_reconcile_http_listener'
assert_contains "webpanel init restores management listener" "$PINIT" 'wp_panel_reconcile_http_listener'
_postinst="$(sed -n '/^define Package\/z2k-webpanel\/postinst$/,/^endef$/p' "$MK")"
_reconcile_at="$(printf '%s\n' "$_postinst" | grep -n 'wp_panel_reconcile_http_listener' | head -1 | cut -d: -f1)"
_enable_at="$(printf '%s\n' "$_postinst" | grep -n '/etc/init.d/z2k-webpanel enable' | head -1 | cut -d: -f1)"
_start_at="$(printf '%s\n' "$_postinst" | grep -n '/etc/init.d/z2k-webpanel start' | head -1 | cut -d: -f1)"
if [ -n "$_reconcile_at" ] && [ -n "$_enable_at" ] && [ -n "$_start_at" ] && \
    [ "$_reconcile_at" -lt "$_enable_at" ] && [ "$_enable_at" -lt "$_start_at" ]; then
    _t_ok
else
    _t_bad "postinst ordering: listener recovery must precede panel enable/start"
fi
assert_file "package-owned listener lifecycle helper" "$WPLIFE"
assert_contains "listener helper audits stock config" "$WPLIFE" 'audit --full --recursive'
assert_contains "listener helper preserves ambiguous config" "$WPLIFE" 'оставлена без изменений'
assert_not_contains "listener helper never edits LuCI or uhttpd config" "$WPLIFE" '/www|uci (set|add|delete)|/etc/config/uhttpd|chmod|chown'

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
cp "$WPADAPT" "$T/root/platform/openwrt/webpanel.sh"
cp "$WPLIFE" "$T/root/platform/openwrt/webpanel-lifecycle.sh" 2>/dev/null || :
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
assert_contains "render: dedicated port" "$_out" 'server.port                 = 8088'
printf '%s\n' "$_out" > "$T/render.conf"
assert_not_contains "render: never claims LuCI ports" "$T/render.conf" 'server.port[[:space:]]*=[[:space:]]*(80|443)([^0-9]|$)'
assert_not_contains "render: never serves stock /www" "$T/render.conf" 'server.document-root[[:space:]]*=[[:space:]]*"/www"'
assert_contains "render: bind IP" "$_out" 'server.bind                 = "192.168.7.1"'
assert_contains "render: cgi alias" "$_out" '"/cgi-bin/api" => "/usr/lib/z2k/webpanel/cgi/api.sh"'
_kko="$(grep -nE '/opt/|Entware' "$_out" 2>/dev/null || true)"
[ -z "$_kko" ] && _t_ok || _t_bad "keenetic-пути в сгенерённом конфиге: $_kko"

# --- 5. зависимость lighttpd: убрать только чистый stock-конфиг и вернуть
# uhttpd на его уже настроенный IPv4 :80; never touch /www или UCI config. ---
mkdir -p "$T/lifecycle/etc/lighttpd" "$T/lifecycle/etc/rc.d" \
    "$T/lifecycle/etc/init.d" "$T/lifecycle/etc/config" "$T/lifecycle/www/cgi-bin"
printf 'stock lighttpd config\n' > "$T/lifecycle/etc/lighttpd/lighttpd.conf"
printf 'config uhttpd main\n' > "$T/lifecycle/etc/config/uhttpd"
printf '#!/bin/sh\nexit 0\n' > "$T/lifecycle/www/cgi-bin/luci"
chmod 0755 "$T/lifecycle/www/cgi-bin/luci"
: > "$T/lifecycle/etc/rc.d/S50lighttpd"
: > "$T/lifecycle/etc/rc.d/S50uhttpd"
cat > "$T/bin/apk-mock" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "audit --full --recursive" ] || exit 98
exit "${MOCK_APK_AUDIT_RC:-0}"
EOF
cat > "$T/lifecycle/etc/init.d/lighttpd" <<'EOF'
#!/bin/sh
case "$1" in
    disable) printf 'disable\n' >> "$WP_LIFECYCLE_LOG"; rm -f "$WP_LIGHTTPD_RC" ;;
    stop) printf 'stop\n' >> "$WP_LIFECYCLE_LOG" ;;
    *) exit 97 ;;
esac
EOF
cat > "$T/lifecycle/etc/init.d/uhttpd" <<'EOF'
#!/bin/sh
[ "$1" = restart ] || exit 96
printf 'uhttpd-restart\n' >> "$WP_LIFECYCLE_LOG"
EOF
cat > "$T/bin/uci-mock" <<'EOF'
#!/bin/sh
case "$2 $3" in
    'get uhttpd.main.listen_http') printf '%s\n' "${MOCK_UHTTPD_HTTP:-0.0.0.0:80 [::]:80}" ;;
    'get network.lan.ipaddr') printf '192.168.7.1' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/apk-mock" "$T/bin/uci-mock" \
    "$T/lifecycle/etc/init.d/lighttpd" "$T/lifecycle/etc/init.d/uhttpd"
export WP_APK_BIN="$T/bin/apk-mock" WP_UCI_BIN="$T/bin/uci-mock"
export WP_LIGHTTPD_INIT="$T/lifecycle/etc/init.d/lighttpd"
export WP_LIGHTTPD_RC="$T/lifecycle/etc/rc.d/S50lighttpd"
export WP_LIGHTTPD_CONF_DIR="$T/lifecycle/etc/lighttpd"
export WP_UHTTPD_INIT="$T/lifecycle/etc/init.d/uhttpd"
export WP_UHTTPD_RC="$T/lifecycle/etc/rc.d/S50uhttpd"
export WP_LIFECYCLE_LOG="$T/lifecycle/actions.log"
_luci_hash_before="$(sha256sum "$T/lifecycle/www/cgi-bin/luci" | cut -d' ' -f1)"
_luci_meta_before="$(ls -ldn "$T/lifecycle/www/cgi-bin/luci" | awk '{print $1, $3, $4}')"
_uhttpd_hash_before="$(sha256sum "$T/lifecycle/etc/config/uhttpd" | cut -d' ' -f1)"
_stock_hash_before="$(sha256sum "$T/lifecycle/etc/lighttpd/lighttpd.conf" | cut -d' ' -f1)"
wp_panel_reconcile_http_listener >/dev/null 2>&1 || _t_bad "stock lighttpd recovery failed"
assert_eq "stock service disabled, stopped, then uhttpd restarted" \
    "disable stop uhttpd-restart " "$(tr '\n' ' ' < "$WP_LIFECYCLE_LOG")"
[ ! -e "$WP_LIGHTTPD_RC" ] && _t_ok || _t_bad "stock lighttpd remains enabled"
wp_panel_reconcile_http_listener >/dev/null 2>&1 || _t_bad "recovery is not idempotent"
assert_eq "repeated lifecycle call has no extra effects" \
    "disable stop uhttpd-restart " "$(tr '\n' ' ' < "$WP_LIFECYCLE_LOG")"
assert_eq "LuCI bytes preserved" "$_luci_hash_before" "$(sha256sum "$T/lifecycle/www/cgi-bin/luci" | cut -d' ' -f1)"
assert_eq "LuCI mode and owner preserved" "$_luci_meta_before" "$(ls -ldn "$T/lifecycle/www/cgi-bin/luci" | awk '{print $1, $3, $4}')"
assert_eq "uhttpd config preserved" "$_uhttpd_hash_before" "$(sha256sum "$T/lifecycle/etc/config/uhttpd" | cut -d' ' -f1)"
assert_eq "stock config preserved" "$_stock_hash_before" "$(sha256sum "$T/lifecycle/etc/lighttpd/lighttpd.conf" | cut -d' ' -f1)"

# APK may start/re-enable its lighttpd dependency during later package
# transactions. Model update-like deployment, reinstall, and legacy migration
# as a fresh dependency enable followed by the same package reconciliation.
for _phase in update-like reinstall legacy-migration; do
    : > "$WP_LIGHTTPD_RC"
    : > "$WP_LIFECYCLE_LOG"
    wp_panel_reconcile_http_listener >/dev/null 2>&1 || _t_bad "$_phase listener recovery failed"
    assert_eq "$_phase disables, stops, and restores uhttpd" \
        "disable stop uhttpd-restart " "$(tr '\n' ' ' < "$WP_LIFECYCLE_LOG")"
    [ ! -e "$WP_LIGHTTPD_RC" ] && _t_ok || _t_bad "$_phase left stock lighttpd enabled"
    assert_eq "$_phase preserves LuCI bytes" "$_luci_hash_before" "$(sha256sum "$T/lifecycle/www/cgi-bin/luci" | cut -d' ' -f1)"
    assert_eq "$_phase preserves LuCI mode and owner" "$_luci_meta_before" "$(ls -ldn "$T/lifecycle/www/cgi-bin/luci" | awk '{print $1, $3, $4}')"
    assert_eq "$_phase preserves uhttpd config" "$_uhttpd_hash_before" "$(sha256sum "$T/lifecycle/etc/config/uhttpd" | cut -d' ' -f1)"
    assert_eq "$_phase preserves stock lighttpd config" "$_stock_hash_before" "$(sha256sum "$T/lifecycle/etc/lighttpd/lighttpd.conf" | cut -d' ' -f1)"
done

# There is intentionally no package removal hook, so uninstall without purge
# leaves the shared LuCI/uhttpd fixture outside this package's lifecycle. The
# stock :80 lighttpd also stays disabled, since restoring its default config
# would reintroduce the exact LuCI 403 this package fixes.
: > "$WP_LIFECYCLE_LOG"
assert_not_contains "uninstall has no destructive lifecycle hook" "$MK" '^define Package/z2k-webpanel/(postrm|prerm)$'
[ ! -e "$WP_LIGHTTPD_RC" ] && _t_ok || _t_bad "uninstall re-enabled stock lighttpd on LuCI port"
[ ! -s "$WP_LIFECYCLE_LOG" ] && _t_ok || _t_bad "uninstall changed service state"
assert_eq "uninstall leaves LuCI bytes" "$_luci_hash_before" "$(sha256sum "$T/lifecycle/www/cgi-bin/luci" | cut -d' ' -f1)"
assert_eq "uninstall leaves LuCI mode and owner" "$_luci_meta_before" "$(ls -ldn "$T/lifecycle/www/cgi-bin/luci" | awk '{print $1, $3, $4}')"
assert_eq "uninstall leaves uhttpd config" "$_uhttpd_hash_before" "$(sha256sum "$T/lifecycle/etc/config/uhttpd" | cut -d' ' -f1)"

# An APK audit failure means a local modification or unknown config file:
# preserve the service and report ambiguity without restarting uhttpd.
: > "$WP_LIGHTTPD_RC"
: > "$WP_LIFECYCLE_LOG"
export MOCK_APK_AUDIT_RC=99
if wp_panel_reconcile_http_listener >/dev/null 2>"$T/lifecycle/ambiguous.log"; then
    _t_bad "custom lighttpd config was treated as stock"
else
    _wp_lifecycle_rc=$?
    assert_eq "custom lighttpd config returns ambiguous" "2" "$_wp_lifecycle_rc"
fi
assert_contains "ambiguous config is reported" "$T/lifecycle/ambiguous.log" 'оставлена без изменений'
[ -e "$WP_LIGHTTPD_RC" ] && _t_ok || _t_bad "ambiguous stock service was disabled"
[ ! -s "$WP_LIFECYCLE_LOG" ] && _t_ok || _t_bad "ambiguous config caused service changes"
unset MOCK_APK_AUDIT_RC
unset WP_APK_BIN WP_UCI_BIN WP_LIGHTTPD_INIT WP_LIGHTTPD_RC WP_LIGHTTPD_CONF_DIR
unset WP_UHTTPD_INIT WP_UHTTPD_RC WP_LIFECYCLE_LOG

# --- 6. init: правдивый status() (ноль инстансов — не running) ---
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

# --- 7. rc-дисциплина слоя: никакого `| tail` перед проверкой rc ---
# (конструкция `cmd | tail; echo $?` возвращает rc tail, не cmd).
_rt="$(grep -rnE '\| *tail' "$WPADAPT" "$PINIT" 2>/dev/null || true)"
[ -z "$_rt" ] && _t_ok || _t_bad "pipe-to-tail в слое: $_rt"

_t_done
