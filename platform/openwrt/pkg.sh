#!/bin/sh
# platform/openwrt/pkg.sh - минимальный установщик пакетов (§11).
# Один рецепт, без package-manager abstraction project: apk если есть,
# иначе opkg. Используется будущими runtime install-хелперами.

# z2k_ow_pkg_manager — печатает "apk" или "opkg", иначе провал.
z2k_ow_pkg_manager() {
    if command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    else
        return 1
    fi
}

# z2k_ow_pkg_install <пакеты...> — ставит через доступный менеджер.
z2k_ow_pkg_install() {
    local _pm
    _pm="$(z2k_ow_pkg_manager)" || return 1
    case "$_pm" in
        apk) apk add "$@" ;;
        # opkg update — только если install не встал (протухшие списки),
        # а не при каждом вызове: обновление списков медленное и сетевое.
        opkg) opkg install "$@" || { opkg update >/dev/null 2>&1; opkg install "$@"; } ;;
    esac
}

# z2k_ow_pkg_is_installed <пакет> — 0 если уже стоит.
z2k_ow_pkg_is_installed() {
    local _pm
    _pm="$(z2k_ow_pkg_manager)" || return 1
    case "$_pm" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
    esac
}
