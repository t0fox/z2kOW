#!/bin/sh
# Проверяет, что повторный stop во время teardown не запускает teardown ещё раз.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-stop-gate"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-stop-gate.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/run" "$T/etc"
printf '%s\n' '00000000-0000-0000-0000-000000000001' > "$T/boot-id"
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_RUN="$T/run" Z2K_CONFIG="$T/etc/config"
export Z2K_START_BOOT_ID_FILE="$T/boot-id" INIT_APPLY_FW=0
: > "$Z2K_CONFIG"

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/files/etc/init.d/z2k" || exit 1
z2k_load_adapter() { return 0; }
z2k_ow_tiktok_cron_remove() { _cron_runs=$((_cron_runs + 1)); return 0; }
z2k_ow_tiktok_stop() {
    if [ "$_nested_stop" = 0 ]; then
        _nested_stop=1
        stop_service ""
        _nested_rc=$?
        [ "$_nested_rc" = 0 ] || return 1
    fi
    return 0
}
z2k_ow_autohostlist_sync() { return 0; }
z2k_ow_custom_daemons() { return 0; }
z2k_ow_customd_stop_instances() { return 0; }
z2k_ow_tg() { return 0; }
z2k_ow_rt() { return 0; }
z2k_ow_warp() { return 0; }
z2k_ow_offload_restore() { return 0; }
z2k_ow_stop_verify() { return 0; }

_nested_stop=0
_cron_runs=0
stop_service ""
assert_eq "вложенный stop не запускает teardown повторно" "1" "$_cron_runs"
if [ ! -e "$Z2K_RUN/start.lock" ]; then _t_ok; else _t_bad "lifecycle-блокировка снята после stop"; fi

_nested_stop=1
stop_service ""
assert_eq "последующий stop снова выполняет teardown" "2" "$_cron_runs"
if [ ! -e "$Z2K_RUN/start.lock" ]; then _t_ok; else _t_bad "блокировка снята после второго stop"; fi

_t_done
