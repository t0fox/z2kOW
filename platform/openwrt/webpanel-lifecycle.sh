#!/bin/sh
# Package-owned recovery for the default lighttpd dependency taking LuCI's
# IPv4 port 80. Customized or unverifiable service configuration is preserved.

wp_panel_reconcile_http_listener() {
    local _init="${WP_LIGHTTPD_INIT:-/etc/init.d/lighttpd}"
    local _rc="${WP_LIGHTTPD_RC:-/etc/rc.d/S50lighttpd}"
    local _conf="${WP_LIGHTTPD_CONF_DIR:-/etc/lighttpd}"
    local _apk="${WP_APK_BIN:-apk}" _audit_rc _listeners _uci _lan _addr

    # A disabled service is an explicit operator choice; leave it untouched.
    [ -L "$_rc" ] || [ -e "$_rc" ] || return 0
    [ -x "$_init" ] || {
        echo "z2k-webpanel: найден S50lighttpd без штатного init-скрипта; состояние сохранено" >&2
        return 1
    }
    if [ "$_apk" = apk ]; then
        command -v apk >/dev/null 2>&1 || {
            echo "z2k-webpanel: apk audit недоступен; lighttpd оставлен без изменений" >&2
            return 2
        }
    elif [ ! -x "$_apk" ]; then
        echo "z2k-webpanel: apk audit недоступен; lighttpd оставлен без изменений" >&2
        return 2
    fi

    "$_apk" audit --full --recursive "$_conf" >/dev/null 2>&1
    _audit_rc=$?
    if [ "$_audit_rc" != 0 ]; then
        echo "z2k-webpanel: конфигурация lighttpd изменена или не проверена; служба оставлена без изменений, LuCI может быть недоступен на IPv4:80" >&2
        return 2
    fi

    "$_init" disable || {
        echo "z2k-webpanel: не удалось отключить штатный lighttpd" >&2
        return 1
    }
    "$_init" stop || {
        echo "z2k-webpanel: не удалось остановить штатный lighttpd" >&2
        return 1
    }

    # Release port 80, then let the already enabled uhttpd bind its configured
    # IPv4 listener again. Keep this stock service disabled while the package is
    # installed; restarting its default :80 config can reproduce the LuCI 403.
    # Read UCI only; never rewrite its config or init unit.
    _init="${WP_UHTTPD_INIT:-/etc/init.d/uhttpd}"
    _rc="${WP_UHTTPD_RC:-/etc/rc.d/S50uhttpd}"
    [ -x "$_init" ] && { [ -L "$_rc" ] || [ -e "$_rc" ]; } || return 0
    _uci="${WP_UCI_BIN:-}"
    if [ -z "$_uci" ]; then
        if command -v uci >/dev/null 2>&1; then _uci=uci
        elif [ -x /sbin/uci ]; then _uci=/sbin/uci
        else return 0
        fi
    fi
    _listeners=$("$_uci" -q get uhttpd.main.listen_http 2>/dev/null) || return 0
    _lan=$(wp_lan_ip 2>/dev/null || true)
    for _addr in $_listeners; do
        _addr=$(printf '%s' "$_addr" | tr -d "\"'")
        case "$_addr" in
            0.0.0.0:80|"$_lan:80")
                "$_init" restart || {
                    echo "z2k-webpanel: штатный lighttpd отключён, но uhttpd не восстановил свой IPv4 HTTP listener" >&2
                    return 1
                }
                return 0
                ;;
        esac
    done
    return 0
}
