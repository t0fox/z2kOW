#!/bin/sh
# Подмена Googlevideo: nftables-таблица принадлежит gvsub, lifecycle — procd.

Z2K_GVSUB_QUEUE="${Z2K_GVSUB_QUEUE:-210}"
Z2K_GVSUB_MARK="${Z2K_GVSUB_MARK:-0x10000000}"
Z2K_GVSUB_STATUS="${Z2K_GVSUB_STATUS:-$Z2K_TMP/gvsub.json}"
Z2K_GVSUB_IPS="${Z2K_GVSUB_IPS:-$Z2K_TMP/gv-ips.txt}"
Z2K_GVSUB_PID="${Z2K_GVSUB_PID:-${Z2K_RUN:-/tmp/z2k/runtime}/gvsub.pid}"
Z2K_GVSUB_TABLE="${Z2K_GVSUB_TABLE:-z2k_gvsub}"
Z2K_GVSUB_GUARD='z2k-openwrt: gvsub core queue guard'

z2k_ow_gvsub_wanted() {
    [ "${Z2K_GV_SUBST:-0}" = 1 ] && [ "${Z2K_CATEGORY_YOUTUBE:-1}" != 0 ]
}

z2k_ow_gvsub_guard_remove() {
    local _tab="${Z2K_ZAPRET_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}" _chain="postnat" _dump _handles _handle
    _dump=$(nft -a list chain inet "$_tab" "$_chain" 2>/dev/null) || return 0
    _handles=$(printf '%s\n' "$_dump" | sed -n "/comment \"$Z2K_GVSUB_GUARD\"/s/.*# handle \([0-9][0-9]*\).*/\1/p")
    while IFS= read -r _handle; do
        [ -n "$_handle" ] || continue
        nft delete rule inet "$_tab" "$_chain" handle "$_handle" || return 1
    done <<EOF_GVSUB_HANDLES
$_handles
EOF_GVSUB_HANDLES
}

z2k_ow_gvsub_guard_apply() {
    local _tab="${Z2K_ZAPRET_NFT_TABLE:-${ZAPRET_NFT_TABLE:-zapret2}}"
    if ! z2k_ow_gvsub_wanted; then
        z2k_ow_gvsub_guard_remove
        return $?
    fi
    [ "${INIT_APPLY_FW:-1}" = 1 ] || return 1
    nft list chain inet "$_tab" postnat >/dev/null 2>&1 || return 1
    z2k_ow_gvsub_guard_remove || return 1
    nft insert rule inet "$_tab" postnat \
        ct mark "&" "$Z2K_GVSUB_MARK" == "$Z2K_GVSUB_MARK" return \
        comment "\"$Z2K_GVSUB_GUARD\""
}

_z2k_ow_gvsub_owner_ready() {
    local _pid="$1" _qnum _owner _rest
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null || return 1
    while read -r _qnum _owner _rest; do
        [ "$_qnum" = "$Z2K_GVSUB_QUEUE" ] && [ "$_owner" = "$_pid" ] && return 0
    done < "${Z2K_NFQUEUE_PROC:-/proc/net/netfilter/nfnetlink_queue}" 2>/dev/null
    return 1
}

z2k_ow_gvsub_running() {
    local _pid
    _pid=$(cat "$Z2K_GVSUB_PID" 2>/dev/null)
    _z2k_ow_gvsub_owner_ready "$_pid"
}

z2k_ow_gvsub_stop() {
    local _pid
    _pid=$(cat "$Z2K_GVSUB_PID" 2>/dev/null)
    if command -v procd_running >/dev/null 2>&1 && command -v procd_kill >/dev/null 2>&1 \
        && procd_running z2k gvsub >/dev/null 2>&1; then
        procd_kill z2k gvsub >/dev/null 2>&1 || true
    fi
    if _z2k_ow_gvsub_owner_ready "$_pid"; then
        kill "$_pid" 2>/dev/null || true
    fi
    z2k_ow_gvsub_guard_remove || return 1
    nft delete table inet "$Z2K_GVSUB_TABLE" >/dev/null 2>&1 || true
    rm -f "$Z2K_GVSUB_PID" 2>/dev/null || true
}

z2k_ow_gvsub_start_instance() {
    local _qnum="${QNUM:-200}" _no6=""
    [ -x "$Z2K_DETECT_BIN" ] || return 1
    [ "${INIT_APPLY_FW:-1}" = 1 ] || return 1
    case "$_qnum" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_qnum" -gt 0 ] && [ "$_qnum" -le 65535 ] || return 1
    [ "${DISABLE_IPV6:-0}" = 1 ] && _no6="-no-ipv6"
    mkdir -p "$(dirname "$Z2K_GVSUB_PID")" "$Z2K_TMP" || return 1
    # shellcheck disable=SC2086
    procd_open_instance "gvsub" || return 1
    # shellcheck disable=SC2086
    procd_set_param command "$Z2K_DETECT_BIN" gvsub \
        "-queue=$Z2K_GVSUB_QUEUE" "-engine-queue=$_qnum" \
        "-status=$Z2K_GVSUB_STATUS" "-config=$Z2K_CONFIG" \
        "-ipfile=$Z2K_GVSUB_IPS" "-whitelist=$Z2K_LISTS_DIR/whitelist.txt" $_no6
    procd_set_param pidfile "$Z2K_GVSUB_PID"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

z2k_ow_gvsub_verify() {
    z2k_ow_gvsub_wanted || return 0
    z2k_ow_gvsub_running || {
        echo "z2k-openwrt: gvsub_verify: очередь DNS не зарегистрирована" >&2
        return 1
    }
    nft list table inet "$Z2K_GVSUB_TABLE" >/dev/null 2>&1 || {
        echo "z2k-openwrt: gvsub_verify: нет таблицы $Z2K_GVSUB_TABLE" >&2
        return 1
    }
}

z2k_ow_gvsub() {
    case "${1:-}" in
        1)
            z2k_ow_gvsub_wanted || { z2k_ow_gvsub_guard_remove; return $?; }
            z2k_ow_gvsub_guard_apply || return 1
            z2k_ow_gvsub_start_instance
            ;;
        0)
            z2k_ow_gvsub_stop
            ;;
        rules)
            z2k_ow_gvsub_guard_apply
            ;;
        cleanup)
            z2k_ow_gvsub_guard_remove >/dev/null 2>&1 || true
            nft delete table inet "$Z2K_GVSUB_TABLE" >/dev/null 2>&1 || true
            rm -f "$Z2K_GVSUB_STATUS" "$Z2K_GVSUB_IPS" "$Z2K_GVSUB_PID" 2>/dev/null || true
            return 0
            ;;
        *)
            echo "usage: z2k_ow_gvsub {1|0|rules|cleanup}" >&2
            return 1
            ;;
    esac
}
