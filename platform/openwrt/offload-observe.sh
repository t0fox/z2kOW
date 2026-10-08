#!/bin/sh
# Read-only runtime observation shared by the OpenWrt status API, diagnostics,
# and FLOWOFFLOAD benchmark. This file never creates or changes firewall rules.

z2k_ow_offload_field() {
    local _snapshot="$1" _key="$2" _tail
    case "$_snapshot" in
        *"$_key="*) _tail=${_snapshot#*"$_key="} ;;
        *) return 1 ;;
    esac
    _tail=${_tail%%;*}
    printf '%s' "$_tail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

z2k_ow_flowoffload_health_reason() {
    local _snapshot="$1" _expected="${2:-}" _configured _ft _flags _actual _selective _visibility _conflict _circular _hardware
    _configured=$(z2k_ow_offload_field "$_snapshot" configured_mode)
    [ -n "$_expected" ] || _expected=$_configured
    _ft=$(z2k_ow_offload_field "$_snapshot" flowtable_state)
    _flags=$(z2k_ow_offload_field "$_snapshot" flowtable_flags)
    _actual=$(z2k_ow_offload_field "$_snapshot" actual_dataplane)
    _selective=$(z2k_ow_offload_field "$_snapshot" selective_state)
    _visibility=$(z2k_ow_offload_field "$_snapshot" packet_visibility)
    _conflict=$(z2k_ow_offload_field "$_snapshot" owner_conflict)
    _circular=$(z2k_ow_offload_field "$_snapshot" circular_state)
    _hardware=$(z2k_ow_offload_field "$_snapshot" hardware_observed)
    [ "$_configured" = "$_expected" ] || { printf 'mode-mismatch'; return; }
    case "$_expected" in
        unknown|donttouch|'') printf 'mode-unavailable'; return ;;
    esac
    if [ "$_expected" = none ]; then
        if [ "$_ft" = unavailable ]; then printf 'state-unavailable'
        elif [ "$_ft" = present ]; then printf 'flowtable-unexpected'
        elif [ "$_conflict" != none ]; then printf 'owner-conflict'
        elif [ "$_actual" = software ] || [ "$_actual" = hardware ]; then printf 'dataplane-unexpected'
        else printf 'disabled'; fi
        return
    fi
    if [ "$_ft" = unavailable ] || [ "$_visibility" = unavailable ] || [ "$_actual" = unavailable ] \
        || [ "$_selective" = unavailable ] || [ "$_conflict" = unavailable ]; then
        printf 'state-unavailable'; return
    fi
    [ "$_ft" = present ] || { printf 'flowtable-missing'; return; }
    if { [ "$_expected" = software ] && [ "$_flags" != software ]; } \
        || { [ "$_expected" = hardware ] && [ "$_flags" != offload ]; }; then
        printf 'flowtable-mode-mismatch'; return
    fi
    [ "$_selective" = complete ] || { printf 'selective-path-broken'; return; }
    [ "$_conflict" = none ] || { printf 'owner-conflict'; return; }
    [ "$_visibility" != inactive ] || { printf 'nfqueue-inactive'; return; }
    [ "$_circular" != broken ] || { printf 'circular-broken'; return; }
    [ "$_actual" = "$_expected" ] || {
        case "$_actual" in software|hardware) printf 'dataplane-mismatch' ;; *) printf 'dataplane-not-observed' ;; esac
        return
    }
    [ "$_visibility" = active ] || { printf 'nfqueue-not-observed'; return; }
    case "$_circular" in
        unavailable|unknown) printf 'circular-unavailable'; return ;;
        enabled-not-observed) printf 'circular-not-observed'; return ;;
    esac
    if [ "$_expected" = hardware ] && [ "$_hardware" != observed ]; then
        printf 'hardware-not-observed'; return
    fi
    printf 'confirmed'
}

z2k_ow_flowoffload_health() {
    case "$(z2k_ow_flowoffload_health_reason "$1" "${2:-}")" in
        confirmed) printf healthy ;;
        disabled) printf disabled ;;
        state-unavailable|circular-unavailable|mode-unavailable) printf unavailable ;;
        dataplane-not-observed|nfqueue-not-observed|circular-not-observed|hardware-not-observed) printf attention ;;
        *) printf broken ;;
    esac
}

z2k_ow_offload_count_marker() {
    printf '%s\n' "$1" | awk -v marker="$2" 'index($0, marker) {n++} END {print n+0}'
}

z2k_ow_offload_count_any_marker() {
    printf '%s\n' "$1" | awk 'index($0, "[OFFLOAD]") || index($0, "[HW_OFFLOAD]") {n++} END {print n+0}'
}

z2k_ow_offload_queue_stats() {
    awk -v q="$2" '
        /queue/ {
            to_rule = "queue.*to[[:space:]]+" q "([[:space:];]|$)"
            num_rule = "queue.*num[[:space:]]+" q "([[:space:];]|$)"
            if ($0 ~ to_rule || $0 ~ num_rule) {
                rules++
                line = $0
                if (match(line, /counter packets [0-9]+/)) {
                    packets = substr(line, RSTART, RLENGTH)
                    sub(/^counter packets /, "", packets)
                    total += packets
                }
            }
        }
        END {printf "%d %d\n", rules+0, total+0}
    ' <<EOF
$1
EOF
}

z2k_ow_offload_flowtable_devices() {
    local _raw
    _raw=$(printf '%s\n' "$1" | sed -n 's/.*devices[[:space:]]*=[[:space:]]*[{][[:space:]]*\([^}]*\)[}].*/\1/p' | tail -1)
    _raw=$(printf '%s' "$_raw" | tr -d '"' | tr -d ' \t\r\n')
    [ -n "$_raw" ] && printf '%s' "$_raw" || printf 'none'
}

z2k_ow_autocircular_configured() {
    local _cfg="${1:-${Z2K_CONFIG:-${CONFIG_FILE:-/etc/z2k/config}}}" _master
    [ -r "$_cfg" ] || return 2
    _master=$(sed -n 's/^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*//p' "$_cfg" 2>/dev/null \
        | tail -1 | tr -d "'\" \t\r")
    [ "$_master" = 0 ] && return 1
    awk '
        /^NFQWS2_OPT="/ { in_opt=1; next }
        in_opt && /^"[[:space:]]*$/ { in_opt=0; next }
        in_opt && /--lua-desync=circular([:[:space:]]|$)/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$_cfg" 2>/dev/null
}

z2k_ow_autocircular_procd_pid() {
    local _json _running _pid
    command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1 || return 2
    _json=$(ubus call service list '{"name":"z2k"}' 2>/dev/null) || return 2
    [ -n "$_json" ] || return 2
    _running=$(printf '%s\n' "$_json" | jsonfilter -e '@.z2k.instances.z2k.running' 2>/dev/null)
    case "$_running" in
        true) ;;
        false) return 1 ;;
        *) case "$_json" in \{*\}) return 1 ;; *) return 2 ;; esac ;;
    esac
    _pid=$(printf '%s\n' "$_json" | jsonfilter -e '@.z2k.instances.z2k.pid' 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 2 ;; esac
    printf '%s' "$_pid"
}

z2k_ow_autocircular_live() {
    local _pid _rc _proc_root _cmdline _exe
    _pid=$(z2k_ow_autocircular_procd_pid)
    _rc=$?
    [ "$_rc" -eq 0 ] || return "$_rc"
    OW_AUTOCIRCULAR_PID="$_pid"
    _proc_root=${Z2K_DIAG_PROC_ROOT:-/proc}
    [ -r "$_proc_root/$_pid/cmdline" ] || return 2
    _cmdline=$(tr '\000' '\n' < "$_proc_root/$_pid/cmdline" 2>/dev/null) || return 2
    [ -n "$_cmdline" ] || return 2
    _exe=$(printf '%s\n' "$_cmdline" | sed -n '1p')
    [ "${_exe##*/}" = nfqws2 ] || return 1
    OW_AUTOCIRCULAR_BINARY="$_exe"
    printf '%s\n' "$_cmdline" | grep -Eq '^--lua-desync=circular([:[:space:]]|$)'
}

z2k_ow_autocircular_proc_env() {
    local _pid="$1" _key="$2" _file="${Z2K_DIAG_PROC_ROOT:-/proc}/$1/environ"
    [ -r "$_file" ] || return 1
    tr '\000' '\n' < "$_file" 2>/dev/null | sed -n "s/^${_key}=//p" | head -1
}

z2k_ow_autocircular_state_paths() {
    local _primary_dir _fallback_dir _runtime_root
    _primary_dir=
    _fallback_dir=
    if [ -r "${Z2K_DIAG_PROC_ROOT:-/proc}/$OW_AUTOCIRCULAR_PID/environ" ]; then
        _primary_dir=$(z2k_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_STATE_DIR_OVERRIDE)
        [ -n "$_primary_dir" ] || _primary_dir=$(z2k_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_AUTOCIRCULAR_DIR_OVERRIDE)
        _fallback_dir=$(z2k_ow_autocircular_proc_env "$OW_AUTOCIRCULAR_PID" Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE)
    fi
    if [ -z "$_primary_dir" ]; then
        _runtime_root=${OW_AUTOCIRCULAR_BINARY%/nfq2/nfqws2}
        if [ "$_runtime_root" != "$OW_AUTOCIRCULAR_BINARY" ]; then
            _primary_dir="$_runtime_root/extra_strats/cache/autocircular"
        else
            _primary_dir="${ZAPRET2_DIR:-${Z2K_ROOT:-/usr/lib/z2k}}/extra_strats/cache/autocircular"
        fi
    fi
    [ -n "$_fallback_dir" ] || _fallback_dir=${Z2K_DIAG_AUTOCIRCULAR_DEFAULT_FALLBACK_DIR:-/tmp}
    OW_AUTOCIRCULAR_PRIMARY_PATH="$_primary_dir/state.tsv"
    OW_AUTOCIRCULAR_FALLBACK_PATH="$_fallback_dir/z2k-autocircular-state.tsv"
    return 0
}

z2k_ow_autocircular_rows() {
    [ -r "$1" ] || { printf '0'; return 0; }
    awk -F '\t' '$1 !~ /^#/ && $1 != "pool" && NF >= 3 {n++} END {print n+0}' "$1" 2>/dev/null
}

z2k_ow_autocircular_detect() {
    local _cfg="${1:-${Z2K_CONFIG:-${CONFIG_FILE:-/etc/z2k/config}}}" _configured_rc _live_rc
    local _primary_rows _fallback_rows
    OW_AUTOCIRCULAR_STATE=unknown
    OW_AUTOCIRCULAR_PID=
    OW_AUTOCIRCULAR_BINARY=
    OW_AUTOCIRCULAR_PERSISTENT_PATH="${STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/state.tsv}"
    OW_AUTOCIRCULAR_PRIMARY_PATH=
    OW_AUTOCIRCULAR_FALLBACK_PATH=
    OW_AUTOCIRCULAR_STATE_FILE=
    OW_AUTOCIRCULAR_STATE_STORAGE=none
    OW_AUTOCIRCULAR_STATE_ROWS=0

    z2k_ow_autocircular_configured "$_cfg"
    _configured_rc=$?
    case "$_configured_rc" in
        1) OW_AUTOCIRCULAR_STATE=disabled; return 0 ;;
        2) OW_AUTOCIRCULAR_STATE=unknown; return 0 ;;
    esac
    z2k_ow_autocircular_live
    _live_rc=$?
    case "$_live_rc" in
        1) OW_AUTOCIRCULAR_STATE=broken; return 0 ;;
        2) OW_AUTOCIRCULAR_STATE=unavailable; return 0 ;;
    esac
    z2k_ow_autocircular_state_paths || { OW_AUTOCIRCULAR_STATE=unavailable; return 0; }
    _primary_rows=$(z2k_ow_autocircular_rows "$OW_AUTOCIRCULAR_PRIMARY_PATH")
    _fallback_rows=$(z2k_ow_autocircular_rows "$OW_AUTOCIRCULAR_FALLBACK_PATH")
    if [ "${_primary_rows:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_PRIMARY_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=persistent
        OW_AUTOCIRCULAR_STATE_ROWS="$_primary_rows"
    elif [ "${_fallback_rows:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_FALLBACK_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=fallback
        OW_AUTOCIRCULAR_STATE_ROWS="$_fallback_rows"
    elif [ -r "$OW_AUTOCIRCULAR_PRIMARY_PATH" ]; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_PRIMARY_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=persistent
    elif [ -r "$OW_AUTOCIRCULAR_FALLBACK_PATH" ]; then
        OW_AUTOCIRCULAR_STATE_FILE="$OW_AUTOCIRCULAR_FALLBACK_PATH"
        OW_AUTOCIRCULAR_STATE_STORAGE=fallback
    fi
    if [ "${OW_AUTOCIRCULAR_STATE_ROWS:-0}" -gt 0 ] 2>/dev/null; then
        OW_AUTOCIRCULAR_STATE=active
    else
        OW_AUTOCIRCULAR_STATE=enabled-not-observed
    fi
    return 0
}

_ow_autocircular_configured() { z2k_ow_autocircular_configured "$@"; }
_ow_autocircular_procd_pid() { z2k_ow_autocircular_procd_pid "$@"; }
_ow_autocircular_live() { z2k_ow_autocircular_live "$@"; }
_ow_autocircular_proc_env() { z2k_ow_autocircular_proc_env "$@"; }
_ow_autocircular_state_paths() { z2k_ow_autocircular_state_paths "$@"; }
_ow_autocircular_rows() { z2k_ow_autocircular_rows "$@"; }
_ow_autocircular_detect() { z2k_ow_autocircular_detect "$@"; }
_ow_autocircular_state() { z2k_ow_autocircular_detect "${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}"; printf '%s' "$OW_AUTOCIRCULAR_STATE"; }

z2k_ow_flowoffload_snapshot() {
    local _mode _tab _rules _rules_rc _zap_table _zap_rc _ft _ft_rc _flags _devices _flowtable
    local _flow_chain _flow_rc _zap_chain _zap_chain_rc _always_chain _always_rc
    local _exemptions _flow_add _flow_route _always_route _selective
    local _qnum _queue_stats _queue_rules _queue_packets _packet_visibility
    local _fw4 _fw4_rc _fw4_flowtables _uci_soft _uci_hw _uci_ok _global _owner _conflict
    local _module_file _sys_modules _module_dir _modules _software_cap _hardware_cap
    local _ct _ct_rc _offloaded _hw_offloaded _software_offloaded _actual _requested _observed _hardware_state
    local _circular _snapshot _health _health_reason _v

    _mode=$(z2k_ow_flowoffload_mode)
    _tab=${Z2K_ZAPRET_NFT_TABLE:-zapret2}
    _qnum=$(sed -n 's/^[[:space:]]*QNUM[[:space:]]*=[[:space:]]*//p' "${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}" 2>/dev/null \
        | tail -1 | tr -d "'\" \t\r")
    case "$_qnum" in ''|*[!0-9]*) _qnum=${QNUM:-200} ;; esac
    _rules=; _rules_rc=127
    if command -v nft >/dev/null 2>&1; then
        _rules=$(nft list ruleset 2>/dev/null); _rules_rc=$?
    fi
    _zap_table=; _zap_rc=127
    _ft=; _ft_rc=127
    _flow_chain=; _flow_rc=127
    _zap_chain=; _zap_chain_rc=127
    _always_chain=; _always_rc=127
    if command -v nft >/dev/null 2>&1; then
        _zap_table=$(nft list table inet "$_tab" 2>/dev/null); _zap_rc=$?
        _ft=$(nft list flowtable inet "$_tab" ft 2>/dev/null); _ft_rc=$?
        _flow_chain=$(nft list chain inet "$_tab" flow_offload 2>/dev/null); _flow_rc=$?
        _zap_chain=$(nft list chain inet "$_tab" flow_offload_zapret 2>/dev/null); _zap_chain_rc=$?
        _always_chain=$(nft list chain inet "$_tab" flow_offload_always 2>/dev/null); _always_rc=$?
    fi

    if [ "$_rules_rc" -ne 0 ]; then
        _flowtable=unavailable; _flags=unavailable; _devices=unavailable
        _flow_state=unavailable; _zap_state=unavailable; _always_state=unavailable
        _exemptions=unavailable; _flow_add=unavailable; _flow_route=unavailable; _always_route=unavailable
        _queue_rules=unavailable; _queue_packets=unavailable
    else
        if [ "$_ft_rc" -eq 0 ]; then
            _flowtable=present
            if printf '%s\n' "$_ft" | grep -Eq '(^|[[:space:]])flags[[:space:]]+offload([;[:space:]]|$)'; then
                _flags=offload
            else
                _flags=software
            fi
            _devices=$(z2k_ow_offload_flowtable_devices "$_ft")
        else
            _flowtable=absent; _flags=none; _devices=none
        fi
        [ "$_flow_rc" -eq 0 ] && _flow_state=present || _flow_state=absent
        [ "$_zap_chain_rc" -eq 0 ] && _zap_state=present || _zap_state=absent
        [ "$_always_rc" -eq 0 ] && _always_state=present || _always_state=absent
        if [ "$_zap_rc" -eq 0 ]; then
            _exemptions=$(printf '%s\n' "$_zap_chain" | grep -ciF 'direct flow offloading exemption' || true)
            _flow_add=$(printf '%s\n' "$_always_chain" | grep -ciE '(^|[[:space:]])flow[[:space:]]+add[[:space:]]+@ft([;[:space:]]|$)' || true)
            printf '%s\n' "$_flow_chain" | grep -qE 'jump[[:space:]]+flow_offload_zapret([;[:space:]]|$)' \
                && _flow_route=present || _flow_route=missing
            printf '%s\n' "$_zap_chain" | grep -qE '(goto|jump)[[:space:]]+flow_offload_always([;[:space:]]|$)' \
                && _always_route=present || _always_route=missing
            _queue_stats=$(z2k_ow_offload_queue_stats "$_zap_table" "$_qnum")
            _queue_rules=${_queue_stats%% *}; _queue_packets=${_queue_stats#* }
        else
            _exemptions=0; _flow_add=0; _flow_route=missing; _always_route=missing
            _queue_rules=0; _queue_packets=0
        fi
    fi

    # FLOWOFFLOAD=none disables only flow offload. NFQUEUE rules and packet
    # counters, like Circular runtime, are independent zapret2 observations.
    if [ "$_rules_rc" -ne 0 ]; then
        _queue_rules=unavailable; _queue_packets=unavailable; _packet_visibility=unavailable
    elif [ "${_queue_rules:-0}" -gt 0 ] 2>/dev/null; then
        if [ "${_queue_packets:-0}" -gt 0 ] 2>/dev/null; then _packet_visibility=active
        else _packet_visibility=not-observed; fi
    else
        _packet_visibility=inactive
    fi

    _fw4=; _fw4_rc=127
    if command -v nft >/dev/null 2>&1; then
        _fw4=$(nft list table inet fw4 2>/dev/null); _fw4_rc=$?
    fi
    if [ "$_rules_rc" -eq 0 ]; then
        if [ "$_fw4_rc" -eq 0 ]; then
            _fw4_flowtables=$(printf '%s\n' "$_fw4" | grep -ciE '^[[:space:]]*flowtable[[:space:]]' || true)
        else
            _fw4_flowtables=0
        fi
    else
        _fw4_flowtables=unavailable
    fi
    _uci_soft=unset; _uci_hw=unset; _uci_ok=0
    if command -v uci >/dev/null 2>&1; then
        _uci_ok=1
        _v=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || true)
        [ -n "$_v" ] && _uci_soft=$_v
        _v=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || true)
        [ -n "$_v" ] && _uci_hw=$_v
    fi
    if [ "$_uci_soft" = 1 ] || [ "$_uci_hw" = 1 ] || { [ "$_fw4_flowtables" != unavailable ] && [ "$_fw4_flowtables" -gt 0 ] 2>/dev/null; }; then
        _global=enabled
    elif [ "$_rules_rc" -ne 0 ]; then
        _global=unavailable
    elif [ "$_uci_ok" = 1 ]; then
        _global=disabled
    else
        _global=not-observed
    fi

    _module_file=${Z2K_PROC_MODULES:-/proc/modules}
    _sys_modules=${Z2K_SYS_MODULE_DIR:-/sys/module}
    _module_dir=${Z2K_MODULE_DIR:-/lib/modules/$(uname -r 2>/dev/null)}
    _modules=$(awk '$1 ~ /^(nf_flow_table|nf_flow_table_inet)$/ {n++} END {print n+0}' "$_module_file" 2>/dev/null)
    [ -n "$_modules" ] || _modules=0
    _software_cap=unavailable
    if [ "$_modules" -gt 0 ] 2>/dev/null || [ -d "$_sys_modules/nf_flow_table" ] || [ -d "$_sys_modules/nf_flow_table_inet" ]; then
        _software_cap=available
    elif [ ! -r "$_module_file" ] && [ ! -d "$_sys_modules" ] && [ ! -d "$_module_dir" ]; then
        _software_cap=unknown
    fi
    _hardware_cap=unavailable
    [ -r "${Z2K_HW_NAT_FILE:-/proc/driver/hw_nat}" ] && _hardware_cap=available

    _ct=; _ct_rc=127
    if command -v conntrack >/dev/null 2>&1; then
        _ct=$(conntrack -L 2>/dev/null); _ct_rc=$?
    elif [ -r "${Z2K_CONNTRACK_FILE:-/proc/net/nf_conntrack}" ]; then
        _ct=$(cat "${Z2K_CONNTRACK_FILE:-/proc/net/nf_conntrack}" 2>/dev/null); _ct_rc=$?
    fi
    if [ "$_ct_rc" -eq 0 ]; then
        _software_offloaded=$(z2k_ow_offload_count_marker "$_ct" '[OFFLOAD]')
        _hw_offloaded=$(z2k_ow_offload_count_marker "$_ct" '[HW_OFFLOAD]')
        _offloaded=$(z2k_ow_offload_count_any_marker "$_ct")
        if [ "$_hw_offloaded" -gt 0 ]; then _actual=hardware
        elif [ "$_software_offloaded" -gt 0 ]; then _actual=software
        else _actual=not-observed; fi
        # Runtime evidence is stronger than a vendor-specific capability
        # marker. Keep capability, request and observation as separate fields.
        [ "$_software_offloaded" -gt 0 ] && _software_cap=available
        [ "$_hw_offloaded" -gt 0 ] && _hardware_cap=available
        if [ "$_mode" = software ] || [ "$_mode" = none ]; then
            _observed=not-applicable
        elif [ "$_hw_offloaded" -gt 0 ]; then
            _observed=observed
        else
            _observed=not-observed
        fi
    else
        _offloaded=unavailable; _hw_offloaded=unavailable; _software_offloaded=unavailable
        _actual=unavailable; _observed=unavailable
    fi
    _requested=0
    [ "$_flags" = offload ] && _requested=1
    case "$_mode" in
        none|software) _hardware_state=not-applicable ;;
        hardware|donttouch)
            if [ "$_observed" = observed ]; then _hardware_state=observed
            elif [ "$_requested" = 1 ]; then _hardware_state=requested
            elif [ "$_hardware_cap" = available ]; then _hardware_state=available
            elif [ "$_ct_rc" -ne 0 ] || [ "$_rules_rc" -ne 0 ]; then _hardware_state=unavailable
            else _hardware_state=not-observed; fi
            ;;
        *) _hardware_state=unavailable ;;
    esac

    _circular=$(_ow_autocircular_state)
    _selective=not-applicable
    case "$_mode" in
        software|hardware)
            if [ "$_rules_rc" -ne 0 ]; then _selective=unavailable
            elif [ "$_flowtable" = present ] && [ "$_flow_state" = present ] \
                && [ "$_zap_state" = present ] && [ "$_always_state" = present ] \
                && [ "${_exemptions:-0}" -gt 0 ] 2>/dev/null && [ "${_flow_add:-0}" -gt 0 ] 2>/dev/null \
                && [ "$_flow_route" = present ] && [ "$_always_route" = present ]; then
                _selective=complete
            else
                _selective=incomplete
            fi
            ;;
        *) ;;
    esac

    _owner=none; _conflict=none
    if [ "$_global" = enabled ]; then
        case "$_mode" in
            software|hardware) _owner=multiple; _conflict=global_fw4+zapret2 ;;
            *)
                if [ "${_queue_rules:-0}" -gt 0 ] 2>/dev/null; then
                    _owner=multiple; _conflict=global_fw4+nfqueue
                else
                    _owner=fw4
                fi
                ;;
        esac
    elif [ "$_global" = unavailable ]; then
        _owner=unknown; _conflict=unavailable
    elif [ "$_flowtable" = present ]; then
        _owner=zapret2
    fi

    _snapshot=$(printf 'configured_mode=%s; flowtable_state=%s; flowtable_flags=%s; flowtable_devices=%s; actual_dataplane=%s; exemption_rules=%s; nfqueue_rules=%s; nfqueue_packets=%s; packet_visibility=%s; circular_state=%s; hardware_capability=%s; hardware_requested=%s; hardware_observed=%s; hardware_state=%s; global_fw4_offload=%s; global_fw4_flowtables=%s; owner_state=%s; owner_conflict=%s; offloaded_connections=%s; hw_offloaded_connections=%s; software_offloaded_connections=%s; flow_offload_chain=%s; flow_offload_zapret_chain=%s; flow_offload_always_chain=%s; flow_add_rules=%s; selective_state=%s; software_capability=%s' \
        "${_mode:-unknown}" "${_flowtable:-unavailable}" "${_flags:-unavailable}" "${_devices:-unavailable}" \
        "${_actual:-unavailable}" "${_exemptions:-unavailable}" "${_queue_rules:-unavailable}" "${_queue_packets:-unavailable}" \
        "${_packet_visibility:-unavailable}" "${_circular:-unknown}" "${_hardware_cap:-unavailable}" "$_requested" \
        "${_observed:-unavailable}" "${_hardware_state:-unavailable}" "${_global:-unavailable}" \
        "${_fw4_flowtables:-unavailable}" "${_owner:-unknown}" "${_conflict:-unavailable}" \
        "${_offloaded:-unavailable}" "${_hw_offloaded:-unavailable}" "${_software_offloaded:-unavailable}" \
        "${_flow_state:-unavailable}" "${_zap_state:-unavailable}" "${_always_state:-unavailable}" \
        "${_flow_add:-unavailable}" "${_selective:-unavailable}" "${_software_cap:-unavailable}")
    _health=$(z2k_ow_flowoffload_health "$_snapshot")
    _health_reason=$(z2k_ow_flowoffload_health_reason "$_snapshot")
    printf '%s; runtime_health=%s; runtime_health_reason=%s\n' "$_snapshot" "$_health" "$_health_reason"
}
