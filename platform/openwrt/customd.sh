#!/bin/sh
# platform/openwrt/customd.sh - the upstream zapret2 custom.d bridge.
#
# The two files below are the upstream Linux examples shipped by z2k's
# installer.  They are deliberately sourced by zapret2's own custom_runner:
# that keeps allocation, nft/NFQUEUE rule construction, and teardown in the
# runtime that owns the zapret2 table.  This file only supplies the OpenWrt
# procd adapter for the extra nfqws2 instances and their health predicate.

Z2K_CUSTOM_DIR="${Z2K_CUSTOM_DIR:-${Z2K_ADAPTER_DIR:-/usr/lib/z2k/platform/openwrt}/custom.d}"
Z2K_CUSTOM_PID_DIR="${Z2K_CUSTOM_PID_DIR:-${Z2K_RUN:-/tmp/z2k/runtime}/customd}"
Z2K_CUSTOM_NFQWS2="${Z2K_CUSTOM_NFQWS2:-${Z2K_NFQWS2:-${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/nfq2/nfqws2}}"
Z2K_CUSTOM_NFQWS2_Q_STUN="${Z2K_CUSTOM_NFQWS2_Q_STUN:-65300}"
Z2K_CUSTOM_NFQWS2_Q_DISCORD="${Z2K_CUSTOM_NFQWS2_Q_DISCORD:-65301}"
Z2K_CUSTOM_NFQWS2_D_STUN="${Z2K_CUSTOM_NFQWS2_D_STUN:-2000}"
Z2K_CUSTOM_NFQWS2_D_DISCORD="${Z2K_CUSTOM_NFQWS2_D_DISCORD:-2001}"
export Z2K_CUSTOM_DIR Z2K_CUSTOM_PID_DIR Z2K_CUSTOM_NFQWS2

z2k_ow_customd_available() {
    [ -d "$Z2K_CUSTOM_DIR" ] || return 1
    [ -f "$Z2K_CUSTOM_DIR/50-stun4all" ] && [ -x "$Z2K_CUSTOM_DIR/50-stun4all" ] || return 1
    [ -f "$Z2K_CUSTOM_DIR/50-discord-media" ] && [ -x "$Z2K_CUSTOM_DIR/50-discord-media" ] || return 1
    [ -x "$Z2K_CUSTOM_NFQWS2" ] || return 1
    [ -f "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/init.d/openwrt/functions" ] || return 1
    command -v nft >/dev/null 2>&1 || return 1
    _z2k_ow_customd_source_runtime || return 1
    return 0
}

_z2k_ow_customd_source_runtime() {
    if ! command -v custom_runner >/dev/null 2>&1; then
        # The panel has not loaded firewall.sh, so source the same zapret2
        # functions file here only to verify the runner component.  The init
        # path still sources it through z2k_ow_fw_source before any mutation.
        . "${Z2K_ZAPRET2_RUNTIME:-/opt/zapret2}/init.d/openwrt/functions" \
            >/dev/null 2>&1 || return 1
    fi
    command -v custom_runner >/dev/null 2>&1
}

z2k_ow_customd_wanted() {
    local _v="${DISABLE_CUSTOM:-}"
    if [ -z "$_v" ] && [ -f "${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}" ]; then
        _v=$(sed -n 's/^DISABLE_CUSTOM=\(.*\)$/\1/p' "${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}" \
            2>/dev/null | tail -1 | sed 's/^"//;s/"$//' | tr -d ' \t\r\n')
    fi
    [ "${_v:-1}" = "0" ]
}

z2k_ow_customd_pidfile() {
    case "$1" in
        "$Z2K_CUSTOM_NFQWS2_Q_STUN") printf '%s/nfqws2_%s.pid\n' "$Z2K_CUSTOM_PID_DIR" "$Z2K_CUSTOM_NFQWS2_D_STUN" ;;
        "$Z2K_CUSTOM_NFQWS2_Q_DISCORD") printf '%s/nfqws2_%s.pid\n' "$Z2K_CUSTOM_PID_DIR" "$Z2K_CUSTOM_NFQWS2_D_DISCORD" ;;
        *) return 1 ;;
    esac
}

_z2k_ow_customd_owner_ready() {
    local _q="$1" _pid="$2" _qnum _owner _rest
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null || return 1
    while read -r _qnum _owner _rest; do
        [ "$_qnum" = "$_q" ] && [ "$_owner" = "$_pid" ] && return 0
    done < "${Z2K_NFQUEUE_PROC:-/proc/net/netfilter/nfnetlink_queue}" 2>/dev/null
    return 1
}

_z2k_ow_customd_rule_ready() {
    nft list ruleset 2>/dev/null \
        | grep -qE "queue[[:space:]]+(num[[:space:]]+$1[[:space:]]+bypass|flags[[:space:]]+bypass[[:space:]]+to[[:space:]]+$1)([[:space:];]|$)"
}

z2k_ow_customd_runtime_ready() {
    z2k_ow_customd_wanted || return 0
    z2k_ow_customd_available || return 1
    local _q _pidfile _pid
    for _q in "$Z2K_CUSTOM_NFQWS2_Q_STUN" "$Z2K_CUSTOM_NFQWS2_Q_DISCORD"; do
        _pidfile=$(z2k_ow_customd_pidfile "$_q") || return 1
        _pid=$(cat "$_pidfile" 2>/dev/null)
        _z2k_ow_customd_owner_ready "$_q" "$_pid" || return 1
        _z2k_ow_customd_rule_ready "$_q" || return 1
    done
    return 0
}

_z2k_ow_customd_load_runtime() {
    command -v custom_runner >/dev/null 2>&1 && return 0
    command -v z2k_ow_fw_source >/dev/null 2>&1 || return 1
    z2k_ow_fw_source || return 1
    command -v custom_runner >/dev/null 2>&1
}

_z2k_ow_customd_run_daemon() {
    local _id="$1" _opt="$2" _base
    mkdir -p "$Z2K_CUSTOM_PID_DIR" 2>/dev/null || return 1
    if command -v z2k_ow_optbase >/dev/null 2>&1; then
        _base=$(z2k_ow_optbase) || return 1
    else
        _base="--user=${WS_USER:-nobody} --fwmark=${DESYNC_MARK:-0x40000000}"
    fi
    procd_open_instance "z2k-custom-${_id}" || return 1
    # shellcheck disable=SC2086
    procd_set_param command "$Z2K_CUSTOM_NFQWS2" $_base $_opt
    procd_set_param pidfile "$Z2K_CUSTOM_PID_DIR/nfqws2_${_id}.pid"
    procd_set_param respawn 3600 5 5
    procd_close_instance
}

z2k_ow_customd_stop_instances() {
    local _q _id _pidfile _pid
    for _q in "$Z2K_CUSTOM_NFQWS2_Q_STUN" "$Z2K_CUSTOM_NFQWS2_Q_DISCORD"; do
        _pidfile=$(z2k_ow_customd_pidfile "$_q") || continue
        _pid=$(cat "$_pidfile" 2>/dev/null)
        case "$_q" in
            "$Z2K_CUSTOM_NFQWS2_Q_STUN") _id="$Z2K_CUSTOM_NFQWS2_D_STUN" ;;
            "$Z2K_CUSTOM_NFQWS2_Q_DISCORD") _id="$Z2K_CUSTOM_NFQWS2_D_DISCORD" ;;
        esac
        # If the service is still registered, stop the named procd instance
        # first so a direct kill cannot be immediately respawned. The PID /
        # NFQUEUE-owner predicate remains the authority for the fallback kill.
        if command -v procd_running >/dev/null 2>&1 && command -v procd_kill >/dev/null 2>&1; then
            procd_running z2k "z2k-custom-${_id}" >/dev/null 2>&1 \
                && procd_kill z2k "z2k-custom-${_id}" >/dev/null 2>&1 || true
        fi
        if [ -n "$_pid" ] && _z2k_ow_customd_owner_ready "$_q" "$_pid"; then
            kill "$_pid" 2>/dev/null || true
        fi
        rm -f "$_pidfile" 2>/dev/null
    done
}

# The upstream examples call this exact zapret2 hook.  stop is intentionally a
# no-op: procd owns every instance of this service and kills it during stop,
# just as init.d/openwrt/zapret2 does.
do_nfqws() {
    [ "$1" = "0" ] && return 0
    shift
    _z2k_ow_customd_run_daemon "$1" "$2"
}

z2k_ow_custom_daemons() {
    local _action="$1"
    if [ "$_action" = "0" ]; then
        # The upstream stop hook is intentionally a no-op because zapret2's
        # procd service owns its instances. Keep an explicit bounded cleanup
        # for adapter rollback and old/orphaned PID files, including when
        # DISABLE_CUSTOM was already flipped before teardown.
        if [ "${DISABLE_CUSTOM:-1}" != "1" ] && _z2k_ow_customd_load_runtime; then
            custom_runner zapret_custom_daemons 0 || true
        fi
        z2k_ow_customd_stop_instances
        return 0
    fi
    [ "${DISABLE_CUSTOM:-1}" = "1" ] && return 0
    if ! z2k_ow_customd_available; then
        [ "$_action" = "0" ] && return 0
        echo "z2k-openwrt: custom.d prerequisites are missing" >&2
        return 1
    fi
    _z2k_ow_customd_load_runtime || {
        [ "$_action" = "0" ] && return 0
        echo "z2k-openwrt: zapret2 custom_runner is unavailable" >&2
        return 1
    }
    custom_runner zapret_custom_daemons "$_action"
}

# Webpanel seam: the API uses the upstream positive value (1 = enabled), while
# zapret2 persists the inverse DISABLE_CUSTOM flag.
toggle_customd() {
    z2k_ow_customd_available || {
        echo "custom.d недоступен на OpenWrt: обязательные файлы или runtime отсутствуют" >&2
        return 1
    }
    local want="$1" _running=0
    if [ "$want" = "0" ]; then
        # Stop first while DISABLE_CUSTOM is still 0, otherwise zapret2 skips
        # its own nft teardown and leaves qnum 65300/65301 orphaned.
        ensure_init_exec
        is_running && _running=1
        if [ "$_running" = "1" ]; then
            "$INIT_SCRIPT" stop 2>&1 || return 1
        fi
        set_flag "DISABLE_CUSTOM" "1" "$CONFIG_FILE" || return 1
        if [ "$_running" = "1" ]; then
            "$INIT_SCRIPT" start 2>&1 || return 1
        fi
        return 0
    fi
    set_flag "DISABLE_CUSTOM" "0" "$CONFIG_FILE" || return 1
    restart_service_if_running
}
