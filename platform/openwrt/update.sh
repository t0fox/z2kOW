#!/bin/sh
# OpenWrt update UI/cron adapter. All deployment goes through install_release.
set -eu
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
. "$Z2K_ROOT/platform/openwrt/paths.sh"
. "$Z2K_ROOT/platform/openwrt/env.sh"
. "$Z2K_LIB/utils.sh"
. "$Z2K_LIB/auto_update.sh"
. "$Z2K_ADAPTER_DIR/manifest.sh"
. "$Z2K_ADAPTER_DIR/release_state.sh"
. "$Z2K_ADAPTER_DIR/release.sh"

ACTION="${1:-apply}"
AU_MANUAL="${Z2K_AU_MANUAL:-0}"
AU_NO_JITTER="${Z2K_AU_NO_JITTER:-0}"
unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER

z2k_ow_auto_update_disabled() {
    [ -r "${Z2K_CONFIG:-/etc/z2k/config}" ] || return 1
    awk '
        { line=$0; gsub(/\r/,"",line)
          if (line !~ /^[ \t]*(export[ \t]+)?Z2K_AUTO_UPDATE_ENABLED[ \t]*=/) next
          sub(/^[ \t]*/,"",line); sub(/^export[ \t]+/,"",line)
          sub(/^Z2K_AUTO_UPDATE_ENABLED[ \t]*=[ \t]*/,"",line)
          sub(/[ \t]*#.*/,"",line); sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
          if (line == "0" || line == "\"0\"" || line == "\0470\047") found=1
        }
        END { exit(found ? 0 : 1) }
    ' "${Z2K_CONFIG:-/etc/z2k/config}" 2>/dev/null
}

case "$ACTION" in
    check|apply) ;;
    *) echo "usage: update.sh [check|apply]" >&2; exit 2 ;;
esac
if [ "$ACTION" = apply ] && [ "$AU_MANUAL" != 1 ] && z2k_ow_auto_update_disabled; then
    echo "Автообновление отключено — обновление пропущено."
    exit 0
fi
if [ "$ACTION" = apply ] && [ ! -t 0 ] && [ "$AU_NO_JITTER" != 1 ] && [ "$AU_MANUAL" != 1 ]; then
    sleep "$(z2k_host_jitter 3600)"
fi

MANIFEST="${Z2K_AU_TMP_DIR:-/tmp/z2k/update}/UPDATES.json"
STATE="$(z2k_ow_path "${Z2K_OW_INSTALLED_RELEASE_FILE:-$Z2K_STATE/installed-release}")"
z2k_ow_release_state_read "$STATE" >/dev/null 2>&1 || {
    echo "z2k-openwrt: $(z2k_ow_release_state_error "$STATE"); release check requires a registered installation" >&2
    exit 1
}
z2k_ow_manifest_prepare_production "$MANIFEST"
DECISION="$(z2k_ow_release_decision "$MANIFEST" "$STATE")"
set -- $DECISION
case "$1" in
    none) echo "Установлен актуальный выпуск: $2"; exit 0 ;;
    resync)
        echo "z2k-openwrt: release metadata requires a full install_release convergence" >&2
        exit 1
        ;;
    update)
        if [ "$ACTION" = check ]; then
            printf 'Доступен полный выпуск %s\n' "$2"
            exit 0
        fi
        printf 'Устанавливается полный выпуск %s\n' "$2"
        exec "${Z2K_INSTALL_RELEASE_BIN:-/usr/sbin/install_release}" "$2"
        ;;
    *) echo "z2k-openwrt: некорректное решение обновления" >&2; exit 1 ;;
esac
