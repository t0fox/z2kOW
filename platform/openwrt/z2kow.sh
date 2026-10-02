#!/bin/sh
# Small operator CLI for the single OpenWrt release installer.
set -eu
_command="${1:-status}"
case "$_command" in
    install|i)
        [ "$#" -eq 2 ] || { echo "usage: z2kow install <release-tag>" >&2; exit 2; }
        exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" "$2"
        ;;
    update|u) shift; exec "${Z2K_UPDATE_BIN:-/usr/lib/z2k/platform/openwrt/update.sh}" apply "$@" ;;
    check) shift; exec "${Z2K_UPDATE_BIN:-/usr/lib/z2k/platform/openwrt/update.sh}" check "$@" ;;
    restart|r)
        [ "$#" -eq 1 ] || { echo "usage: z2kow restart" >&2; exit 2; }
        exec "${Z2K_INIT:-/etc/init.d/z2k}" restart
        ;;
    status|s)
        _state="${Z2K_OW_INSTALLED_RELEASE_FILE:-/etc/z2k/state/installed-release}"
        _first="$(sed -n '1p' "$_state" 2>/dev/null | tr -d '\r')"
        case "$_first" in tag=*) _tag="${_first#tag=}" ;; *=*) _tag="" ;; *) _tag="$_first" ;; esac
        _seq="$(sed -n 's/^seq=//p' "$_state" 2>/dev/null | head -1 | tr -d ' \t\r\n')"
        printf 'installed_release=%s\n' "${_tag:-none}"
        [ -z "$_seq" ] || printf 'installed_seq=%s\n' "$_seq"
        if [ -x "${Z2K_INIT:-/etc/init.d/z2k}" ]; then
            "${Z2K_INIT:-/etc/init.d/z2k}" status
        fi
        ;;
    help|-h|--help)
        printf '%s\n' 'z2kow: install <tag> | check | update | status | restart'
        ;;
    *) echo "z2kow: unknown command: $_command" >&2; exit 2 ;;
esac
