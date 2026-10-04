#!/bin/sh
# Small operator CLI for the single OpenWrt release installer.
set -eu
_command="${1:-status}"
case "$_command" in
    install|i)
        [ "$#" -eq 2 ] || { echo "usage: z2kow install <release-tag>" >&2; exit 2; }
        exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" "$2"
        ;;
    uninstall|remove)
        shift
        exec /bin/sh "${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt/uninstall.sh" "$@"
        ;;
    reinstall)
        [ "$#" -eq 1 ] || { echo "usage: z2kow reinstall" >&2; exit 2; }
        exec env Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1 \
            "${Z2K_UPDATE_BIN:-/usr/lib/z2k/platform/openwrt/update.sh}" reinstall
        ;;
    update|u) shift; exec "${Z2K_UPDATE_BIN:-/usr/lib/z2k/platform/openwrt/update.sh}" apply "$@" ;;
    check) shift; exec "${Z2K_UPDATE_BIN:-/usr/lib/z2k/platform/openwrt/update.sh}" check "$@" ;;
    tiktok)
        shift
        _root="${Z2K_ROOT:-/usr/lib/z2k}"
        . "$_root/platform/openwrt/paths.sh"
        . "$_root/platform/openwrt/env.sh"
        . "$_root/lib/utils.sh"
        . "$_root/platform/openwrt/schedule.sh"
        . "$_root/platform/openwrt/tiktok.sh"
        _action="${1:-status}"
        _previous=$(awk -F= '$1 == "Z2K_TIKTOK_FEED_ENABLED" { v=$2; gsub(/[" '\''\r]/, "", v) } END { print v }' "$Z2K_CONFIG" 2>/dev/null)
        [ "$_previous" = 1 ] || _previous=0
        case "$_action" in
            status) z2k_ow_tiktok_status ;;
            check) z2k_ow_tiktok_check ;;
            enable)
                set_flag Z2K_TIKTOK_FEED_ENABLED 1 "$Z2K_CONFIG"
                if [ -e "$Z2K_CORE_READY" ]; then
                    if z2k_ow_tiktok_cron_install && z2k_ow_tiktok_enable; then :; else
                        set_flag Z2K_TIKTOK_FEED_ENABLED "$_previous" "$Z2K_CONFIG"
                        z2k_ow_tiktok_cron_remove >/dev/null 2>&1 || true
                        exit 1
                    fi
                fi
                ;;
            disable)
                set_flag Z2K_TIKTOK_FEED_ENABLED 0 "$Z2K_CONFIG"
                if z2k_ow_tiktok_cron_remove && z2k_ow_tiktok_disable; then :; else
                    set_flag Z2K_TIKTOK_FEED_ENABLED "$_previous" "$Z2K_CONFIG"
                    [ "$_previous" != 1 ] || { [ ! -e "$Z2K_CORE_READY" ] || z2k_ow_tiktok_cron_install >/dev/null 2>&1 || true; }
                    exit 1
                fi
                ;;
            *) echo "usage: z2kow tiktok <status|check|enable|disable>" >&2; exit 2 ;;
        esac
        ;;
    blocked-monitor|bm)
        shift
        _root="${Z2K_ROOT:-/usr/lib/z2k}"
        [ -r "$_root/platform/openwrt/paths.sh" ] && . "$_root/platform/openwrt/paths.sh"
        [ -r "$_root/platform/openwrt/env.sh" ] && . "$_root/platform/openwrt/env.sh"
        ZAPRET_BASE="$_root"
        ZAPRET_CONFIG="${Z2K_CONFIG:-/etc/z2k/config}"
        Z2K_BLOCKED_MONITOR_CACHE="${Z2K_BLOCKED_MONITOR_CACHE:-${Z2K_TMP:-/tmp/z2k}/blocked-monitor}"
        MAX_TSV_LINES="${MAX_TSV_LINES:-25000}"
        export ZAPRET_BASE ZAPRET_CONFIG Z2K_BLOCKED_MONITOR_CACHE MAX_TSV_LINES
        exec sh "${Z2K_BLOCKED_MONITOR_SCRIPT:-$_root/z2k-blocked-monitor.sh}" "$@"
        ;;
    restart|r)
        [ "$#" -eq 1 ] || { echo "usage: z2kow restart" >&2; exit 2; }
        exec "${Z2K_INIT:-/etc/init.d/z2k}" restart
        ;;
    status|s)
        _state="${Z2K_OW_INSTALLED_RELEASE_FILE:-/etc/z2k/state/installed-release}"
        _state_lib="${Z2K_RELEASE_STATE_LIB:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt/release_state.sh}"
        . "$_state_lib" || { echo "z2kow: release state reader unavailable: $_state_lib" >&2; exit 1; }
        _record="$(z2k_ow_release_state_read "$_state")" || {
            echo "z2kow: $(z2k_ow_release_state_error "$_state")" >&2
            exit 1
        }
        _tag=$(printf '%s\n' "$_record" | sed -n 's/^tag=//p' | head -1)
        _seq=$(printf '%s\n' "$_record" | sed -n 's/^seq=//p' | head -1)
        printf 'installed_release=%s\n' "${_tag:-none}"
        printf 'installed_seq=%s\n' "$_seq"
        if [ -x "${Z2K_INIT:-/etc/init.d/z2k}" ]; then
            "${Z2K_INIT:-/etc/init.d/z2k}" status
        fi
        ;;
    help|-h|--help)
        printf '%s\n' 'z2kow: install <tag> | reinstall | check | update | uninstall | status | restart | tiktok <status|check|enable|disable> | blocked-monitor <start|stop|status|tail>'
        ;;
    *) echo "z2kow: unknown command: $_command" >&2; exit 2 ;;
esac
