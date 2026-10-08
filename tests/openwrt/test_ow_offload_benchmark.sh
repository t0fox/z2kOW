#!/bin/sh
# FLOWOFFLOAD benchmark adapter contract: rollback, numeric aggregation and
# truthful unknowns. The worker is exercised with a deterministic browser
# sample seam; no router or external speed-test endpoint is contacted.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-offload-benchmark"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTER="$REPO/platform/openwrt/offload-benchmark.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-bench.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

[ -f "$ADAPTER" ] || { _t_bad "benchmark adapter exists"; _t_done; exit 1; }
. "$ADAPTER"
. "$REPO/platform/openwrt/offload-observe.sh"

assert_ne() {
    if [ "$2" != "$3" ]; then _t_ok; else _t_bad "$1: expected value other than [$2]"; fi
}

assert_eq "median ignores order" "2" "$(z2k_ow_offload_benchmark_median 3 1 2)"
assert_eq "even median averages middle values" "2.5" "$(z2k_ow_offload_benchmark_median 4 1 3 2)"
assert_eq "relative improvement is a percentage" "20" "$(z2k_ow_offload_benchmark_delta_pct 100 120)"
assert_eq "small but real percentage deltas are preserved" "0.1" "$(z2k_ow_offload_benchmark_delta_pct 100 100.1)"
assert_eq "small but real latency deltas are preserved" "0.05" "$(z2k_ow_offload_benchmark_delta_value 5.5 5.55)"
assert_eq "zero denominator is unknown" "null" "$(z2k_ow_offload_benchmark_delta_pct 0 20)"
assert_eq "JSON text escapes exact quotes in observer errors" '"observer said \"denied\""' "$(z2k_ow_offload_benchmark_json_text 'observer said "denied"')"
assert_eq "invalid metric is null" "null" "$(z2k_ow_offload_benchmark_number_or_null 'not-a-number')"
assert_eq "router-wide conntrack marker is not accepted as sample proof" "unknown" "$(z2k_ow_offload_benchmark_sample_actual hardware)"

# OpenWrt BusyBox may omit `od`; nonce generation should use the kernel UUID
# source and keep working with a deliberately minimal PATH.
mkdir -p "$T/token-bin"
ln -s "$(command -v sed)" "$T/token-bin/sed"
printf '%s\n' '00112233-4455-6677-8899-aabbccddeeff' > "$T/kernel-uuid"
_token=$(PATH="$T/token-bin" Z2K_BENCH_UUID_FILE="$T/kernel-uuid" z2k_ow_offload_benchmark_new_token 2>"$T/token.err")
assert_eq "nonce generation works without od" "00112233445566778899aabbccddeeff" "$_token"
[ ! -s "$T/token.err" ] && _t_ok || _t_bad "nonce generation without od emits no command error"

mkdir -p "$T/state" "$T/tmp" "$T/jobs"
Z2K_STATE="$T/state" Z2K_TMP="$T/tmp" Z2K_JOB_DIR="$T/jobs"
Z2K_CONFIG="$T/config"
CONFIG_FILE="$Z2K_CONFIG"
Z2K_BENCH_SETTLE_SECONDS=0
Z2K_BENCH_ROUTER_MODEL='Fixture Router'
Z2K_BENCH_OPENWRT_VERSION='OpenWrt 24.10 fixture'
Z2K_BENCH_Z2KOW_VERSION='p-86.14'
Z2K_BENCH_WAN_INTERFACE='wan0'
export Z2K_STATE Z2K_TMP Z2K_JOB_DIR Z2K_CONFIG CONFIG_FILE Z2K_BENCH_SETTLE_SECONDS \
    Z2K_BENCH_ROUTER_MODEL Z2K_BENCH_OPENWRT_VERSION Z2K_BENCH_Z2KOW_VERSION Z2K_BENCH_WAN_INTERFACE
mkdir -p "$T/state/flowoffload-benchmark"
printf '%s\n' '{"status":"completed","timestamp":"legacy","validity":{"complete":true,"unstable":true}}' \
    > "$T/state/flowoffload-benchmark/last-success.json"
assert_eq "legacy unstable result is not exposed as accepted history" null "$(z2k_ow_offload_benchmark_last_success_json)"
z2k_ow_offload_benchmark_status_json > "$T/status.json"
assert_contains "legacy unstable result has no accepted timestamp" "$T/status.json" '"last_success_timestamp":""'
printf '%s\n' '{"status":"completed","timestamp":"old-rule","validity":{"complete":true,"unstable":false,"accepted":true}}' \
    > "$T/state/flowoffload-benchmark/last-success.json"
assert_eq "pre-rule accepted result is not exposed as stable history" null "$(z2k_ow_offload_benchmark_last_success_json)"
cp "$T/state/flowoffload-benchmark/last-success.json" "$T/state/flowoffload-benchmark/last-result.json"
assert_eq "pre-rule result is not exposed through the result API" '{"ok":true,"result":null}' "$(z2k_ow_offload_benchmark_result_json)"
z2k_ow_offload_benchmark_status_json > "$T/status.json"
assert_contains "pre-rule accepted result has no current-rule timestamp" "$T/status.json" '"last_success_timestamp":""'
assert_contains "pre-rule result is not exposed through status API" "$T/status.json" '"result":null'
printf '%s\n' '{"schema":1,"stability_rule":"two_of_five_over_10pct","status":"completed","timestamp":"2026-10-07T21:36:20Z","system":{"z2kow_version":"p-86.16"},"validity":{"complete":true,"unstable":false,"accepted":true},"recommendation":{"mode":"hardware"},"modes":{"none":{"runs":[{"download_mbps":97}]}}}' \
    > "$T/state/flowoffload-benchmark/last-result.json"
_legacy_result=$(z2k_ow_offload_benchmark_result_json)
printf '%s\n' "$_legacy_result" > "$T/legacy-result.json"
assert_contains "legacy result is explicitly marked historical" "$T/legacy-result.json" '"runtime_evidence_state":"historical"'
assert_contains "legacy result data is preserved" "$T/legacy-result.json" '"download_mbps":97'
python3 -m json.tool "$T/legacy-result.json" >/dev/null 2>&1 && _t_ok || _t_bad "legacy result API remains valid JSON after historical annotation"
z2k_ow_offload_benchmark_status_json > "$T/status.json"
assert_contains "status API marks persisted legacy result historical" "$T/status.json" '"runtime_evidence_state":"historical"'
cp "$T/state/flowoffload-benchmark/last-result.json" "$T/state/flowoffload-benchmark/last-success.json"
_legacy_success=$(z2k_ow_offload_benchmark_last_success_json)
printf '%s\n' "$_legacy_success" > "$T/legacy-success.json"
assert_contains "last-success API marks legacy evidence historical" "$T/legacy-success.json" '"runtime_evidence_state":"historical"'
z2k_ow_offload_benchmark_status_json > "$T/status.json"
assert_contains "legacy result is not advertised as current accepted history" "$T/status.json" '"last_success_timestamp":""'
assert_contains "legacy accepted history remains available with a historical label" "$T/status.json" '"last_success_state":"historical"'
printf '%s\n' 'Fixture File Router' > "$T/model"
printf "%s\n" "DISTRIB_DESCRIPTION='OpenWrt 24.10 file fixture'" > "$T/openwrt_release"
printf '%s\n' 'tag=p-86.14-file' > "$T/installed-release"
_system=$(Z2K_BENCH_ROUTER_MODEL= Z2K_BENCH_OPENWRT_VERSION= Z2K_BENCH_Z2KOW_VERSION= \
    Z2K_BENCH_WAN_INTERFACE= Z2K_BENCH_MODEL_FILE="$T/model" \
    Z2K_OPENWRT_RELEASE_FILE="$T/openwrt_release" Z2K_OW_INSTALLED_RELEASE_FILE="$T/installed-release" \
    z2k_ow_offload_benchmark_system_json)
assert_eq "system metadata reads installed release context and leaves unknown WAN null" \
    '{"router_model":"Fixture File Router","openwrt_version":"OpenWrt 24.10 file fixture","z2kow_version":"p-86.14-file","wan_interface":null}' \
    "$_system"
printf 'FLOWOFFLOAD=software\n' > "$Z2K_CONFIG"
z2k_ow_flowoffload_available() { return 0; }
is_running() { return 0; }
z2k_ow_flowoffload_mode() { sed -n 's/^FLOWOFFLOAD=//p' "$Z2K_CONFIG" | tail -1; }
toggle_flowoffload() {
    printf '%s\n' "$1" >> "$T/applied.log"
    if [ "${BENCH_APPLY_FAIL:-}" = "$1" ]; then return 1; fi
    sed "s/^FLOWOFFLOAD=.*/FLOWOFFLOAD=$1/" "$Z2K_CONFIG" > "$Z2K_CONFIG.new" && mv "$Z2K_CONFIG.new" "$Z2K_CONFIG"
}
z2k_ow_flowoffload_status() {
    _status_count=$(cat "$T/status-calls" 2>/dev/null); _status_count=$((${_status_count:-0}+1))
    printf '%s\n' "$_status_count" > "$T/status-calls"
    if [ "${BENCH_OBSERVER_FAIL_ON:-}" = "$_status_count" ]; then
        printf '%s\n' 'fixture nft permission denied' >&2
        return 42
    fi
    [ "${BENCH_OBSERVER_EMPTY_ON:-}" != "$_status_count" ] || return 0
    case "$(z2k_ow_flowoffload_mode)" in
        hardware)
            if [ "${BENCH_HW_UNSUPPORTED:-}" = 1 ]; then
                printf 'configured_mode=hardware; flowtable_state=present; flowtable_flags=software; flowtable_devices=wan; actual_dataplane=not-observed; exemption_rules=1; nfqueue_rules=1; nfqueue_packets=5; packet_visibility=active; circular_state=disabled; hardware_capability=available; hardware_requested=0; hardware_observed=not-observed; hardware_state=available; global_fw4_offload=disabled; global_fw4_flowtables=0; owner_state=zapret2; owner_conflict=none; offloaded_connections=0; hw_offloaded_connections=0; software_offloaded_connections=0; flow_offload_chain=present; flow_offload_zapret_chain=present; flow_offload_always_chain=present; flow_add_rules=1; selective_state=complete; software_capability=available; runtime_health=broken; runtime_health_reason=flowtable-mode-mismatch\n'
            else
                printf 'configured_mode=hardware; flowtable_state=present; flowtable_flags=offload; flowtable_devices=wan; actual_dataplane=hardware; exemption_rules=1; nfqueue_rules=1; nfqueue_packets=5; packet_visibility=active; circular_state=disabled; hardware_capability=available; hardware_requested=1; hardware_observed=observed; hardware_state=observed; global_fw4_offload=disabled; global_fw4_flowtables=0; owner_state=zapret2; owner_conflict=none; offloaded_connections=3; hw_offloaded_connections=3; software_offloaded_connections=0; flow_offload_chain=present; flow_offload_zapret_chain=present; flow_offload_always_chain=present; flow_add_rules=1; selective_state=complete; software_capability=available; runtime_health=healthy; runtime_health_reason=confirmed\n'
            fi
            ;;
        software)
            _bench_status=$(z2k_ow_offload_benchmark_field status 2>/dev/null)
            if [ "${BENCH_NFQUEUE_INACTIVE:-}" = 1 ] && { [ "$_bench_status" = applying ] || [ "$_bench_status" = awaiting_sample ]; }; then
                printf 'configured_mode=software; flowtable_state=present; flowtable_flags=software; flowtable_devices=wan; actual_dataplane=software; exemption_rules=1; nfqueue_rules=0; nfqueue_packets=0; packet_visibility=inactive; circular_state=disabled; hardware_capability=unavailable; hardware_requested=0; hardware_observed=not-applicable; hardware_state=not-applicable; global_fw4_offload=disabled; global_fw4_flowtables=0; owner_state=zapret2; owner_conflict=none; offloaded_connections=3; hw_offloaded_connections=0; software_offloaded_connections=3; flow_offload_chain=present; flow_offload_zapret_chain=present; flow_offload_always_chain=present; flow_add_rules=1; selective_state=complete; software_capability=available; runtime_health=broken; runtime_health_reason=nfqueue-inactive\n'
            else
                printf 'configured_mode=software; flowtable_state=present; flowtable_flags=software; flowtable_devices=wan; actual_dataplane=software; exemption_rules=1; nfqueue_rules=1; nfqueue_packets=5; packet_visibility=active; circular_state=disabled; hardware_capability=unavailable; hardware_requested=0; hardware_observed=not-applicable; hardware_state=not-applicable; global_fw4_offload=disabled; global_fw4_flowtables=0; owner_state=zapret2; owner_conflict=none; offloaded_connections=3; hw_offloaded_connections=0; software_offloaded_connections=3; flow_offload_chain=present; flow_offload_zapret_chain=present; flow_offload_always_chain=present; flow_add_rules=1; selective_state=complete; software_capability=available; runtime_health=healthy; runtime_health_reason=confirmed\n'
            fi
            ;;
        *) printf 'configured_mode=none; flowtable_state=absent; flowtable_flags=none; flowtable_devices=none; actual_dataplane=not-observed; exemption_rules=0; nfqueue_rules=0; nfqueue_packets=0; packet_visibility=not-applicable; circular_state=disabled; hardware_capability=unavailable; hardware_requested=0; hardware_observed=not-applicable; hardware_state=not-applicable; global_fw4_offload=disabled; global_fw4_flowtables=0; owner_state=none; owner_conflict=none; offloaded_connections=0; hw_offloaded_connections=0; software_offloaded_connections=0; flow_offload_chain=absent; flow_offload_zapret_chain=absent; flow_offload_always_chain=absent; flow_add_rules=0; selective_state=not-applicable; software_capability=available; runtime_health=disabled; runtime_health_reason=disabled\n' ;;
    esac
}
z2k_ow_offload_benchmark_wait_sample() {
    if [ "${BENCH_STOP_ON_SAMPLE:-}" = "$2" ]; then
        : > "$(z2k_ow_offload_benchmark_stop_file)"
        return 2
    fi
    if [ "${BENCH_SAMPLE_FAIL_ON:-}" = "$1:$2" ]; then return 1; fi
    _download=100
    _upload=40
    if [ "${BENCH_HARDWARE_FAST:-}" = 1 ]; then
        case "$1" in none) _download=70 ;; software) _download=100 ;; hardware) _download=120 ;; esac
    fi
    if [ "${BENCH_NOISY:-}" = 1 ]; then
        case "$1:$2" in
            none:1) _download=70 ;; none:2) _download=100 ;; none:3) _download=130 ;; none:4) _download=75 ;; none:5) _download=125 ;;
            software:1) _download=140 ;; software:2) _download=200 ;; software:3) _download=260 ;; software:4) _download=150 ;; software:5) _download=250 ;;
            hardware:1) _download=150 ;; hardware:2) _download=220 ;; hardware:3) _download=290 ;; hardware:4) _download=160 ;; hardware:5) _download=280 ;;
        esac
    fi
    if [ "${BENCH_UPLOAD_NOISY:-}" = 1 ]; then
        case "$1:$2" in none:1) _upload=15 ;; none:2) _upload=40 ;; none:3) _upload=85 ;; none:4) _upload=20 ;; none:5) _upload=80 ;; software:1) _upload=20 ;; software:2) _upload=50 ;; software:3) _upload=90 ;; software:4) _upload=25 ;; software:5) _upload=80 ;; hardware:1) _upload=15 ;; hardware:2) _upload=40 ;; hardware:3) _upload=85 ;; hardware:4) _upload=20 ;; hardware:5) _upload=80 ;; esac
    fi
    if [ "${BENCH_TWO_OUTLIERS:-}" = 1 ]; then
        case "$1:$2" in software:3) _download=88 ;; software:4) _download=89 ;; esac
    fi
    if [ "${BENCH_SINGLE_OUTLIER:-}" = 1 ] && [ "$1:$2" = software:5 ]; then _download=85; fi
    printf 'download_mbps=%s\nupload_mbps=%s\nidle_ms=8\ndownload_loaded_ms=20\nupload_loaded_ms=24\njitter_ms=2\nloss_pct=0\nduration_s=4\nserver=speed.cloudflare.com\n' "$_download" "$_upload"
}
z2k_ow_offload_benchmark_cpu_monitor() {
    [ "${BENCH_CPU_UNKNOWN:-}" = 1 ] || printf 'avg=12\npeak=18\n' > "$1"
}
uci() {
    if [ "${BENCH_SQM:-}" = 1 ] && [ "${2:-}" = get ] && [ "${3:-}" = 'sqm.@queue[0].enabled' ]; then printf '1'; return 0; fi
    return 1
}

run_case() {
    _case="$1"
    _preserved_success=
    if [ "$_case" = error-after-success ] || [ "$_case" = noisy ] || [ "$_case" = noisy-upload ] || [ "$_case" = two-outliers ]; then
      if [ -s "$T/state/flowoffload-benchmark/last-success.json" ]; then
        _preserved_success="$T/last-success-preserved.json"
        cp "$T/state/flowoffload-benchmark/last-success.json" "$_preserved_success"
      fi
    fi
    rm -rf "$T/state/flowoffload-benchmark" "$T/tmp/flowoffload-benchmark" "$T/applied.log"
    mkdir -p "$T/state" "$T/tmp"
    : > "$T/status-calls"
    if [ -n "$_preserved_success" ]; then
        mkdir -p "$T/state/flowoffload-benchmark"
        cp "$_preserved_success" "$T/state/flowoffload-benchmark/last-success.json"
    fi
    printf 'FLOWOFFLOAD=software\n' > "$Z2K_CONFIG"
    BENCH_SAMPLE_FAIL_ON="" BENCH_STOP_ON_SAMPLE="" BENCH_APPLY_FAIL="" BENCH_HW_UNSUPPORTED="" BENCH_NFQUEUE_INACTIVE="" BENCH_OBSERVER_FAIL_ON="" BENCH_OBSERVER_EMPTY_ON=""
    BENCH_HARDWARE_FAST="" BENCH_CPU_UNKNOWN="" BENCH_SQM="" BENCH_NOISY="" BENCH_UPLOAD_NOISY="" BENCH_TWO_OUTLIERS="" BENCH_SINGLE_OUTLIER=""
    case "$_case" in
        success) ;;
        error|error-after-success) BENCH_SAMPLE_FAIL_ON="software:2" ;;
        stop) BENCH_STOP_ON_SAMPLE="2" ;;
        hardware-apply-fail) BENCH_APPLY_FAIL=hardware ;;
        hardware-unsupported) BENCH_HW_UNSUPPORTED=1 ;;
        hardware-fast) BENCH_HARDWARE_FAST=1 ;;
        hardware-conflict) BENCH_HARDWARE_FAST=1; BENCH_SQM=1 ;;
        hardware-unobserved) BENCH_HARDWARE_FAST=1; BENCH_HW_UNSUPPORTED=1 ;;
        health-broken) BENCH_NFQUEUE_INACTIVE=1 ;;
        observer-failure) BENCH_OBSERVER_FAIL_ON=1 ;;
        observer-empty) BENCH_OBSERVER_EMPTY_ON=1 ;;
        cpu-unknown) BENCH_CPU_UNKNOWN=1 ;;
        noisy) BENCH_HARDWARE_FAST=1; BENCH_NOISY=1 ;;
        noisy-upload) BENCH_HARDWARE_FAST=1; BENCH_UPLOAD_NOISY=1 ;;
        two-outliers) BENCH_TWO_OUTLIERS=1 ;;
        single-outlier) BENCH_SINGLE_OUTLIER=1 ;;
    esac
    export BENCH_SAMPLE_FAIL_ON BENCH_STOP_ON_SAMPLE BENCH_APPLY_FAIL BENCH_HW_UNSUPPORTED BENCH_NFQUEUE_INACTIVE \
        BENCH_OBSERVER_FAIL_ON BENCH_OBSERVER_EMPTY_ON BENCH_HARDWARE_FAST BENCH_CPU_UNKNOWN BENCH_SQM BENCH_NOISY BENCH_UPLOAD_NOISY BENCH_TWO_OUTLIERS BENCH_SINGLE_OUTLIER
    if [ "$_case" = hardware-conflict ]; then
        cat > "$T/sqm-active" <<'EOF'
#!/bin/sh
[ "${1:-}" = running ]
EOF
        chmod +x "$T/sqm-active"
        Z2K_SQM_INIT="$T/sqm-active"
    else
        Z2K_SQM_INIT="$T/no-sqm-service"
    fi
    export Z2K_SQM_INIT
    _session="$(z2k_ow_offload_benchmark_start cloudflare)" || { _t_bad "$_case: benchmark starts"; return 1; }
    z2k_ow_offload_benchmark_worker "$_session" >/dev/null 2>&1
    _rc=$?
    assert_eq "$_case: original mode restored" "software" "$(z2k_ow_offload_benchmark_mode_from_config)"
    assert_eq "$_case: restore marker cleared after verified restore" "" "$(cat "$T/state/flowoffload-benchmark.restore" 2>/dev/null)"
    case "$_case" in
        success)
            assert_eq "success: worker exits zero" "0" "$_rc"
            assert_eq "success: final status completed" "completed" "$(z2k_ow_offload_benchmark_field status)"
            assert_contains "success: result has real fixture measurements" "$T/state/flowoffload-benchmark/last-result.json" '"download_mbps":100'
            assert_contains "success: new result versions its runtime evidence" "$T/state/flowoffload-benchmark/last-result.json" '"schema":2,"runtime_evidence_version":1'
            assert_contains "success: each run carries before and after snapshots" "$T/state/flowoffload-benchmark/last-result.json" '"health_accepted":true,"rejection_reason":null,"health_before":'
            assert_contains "success: NFQUEUE evidence retains its actual counter" "$T/state/flowoffload-benchmark/last-result.json" '"nfqueue_packets":5'
            assert_contains "success: acceptance records the active stability rule" "$T/state/flowoffload-benchmark/last-result.json" '"stability_rule":"two_of_five_over_10pct"'
            assert_contains "success: software and hardware modes are present" "$T/state/flowoffload-benchmark/last-result.json" '"software":{"runs":[{'
            assert_contains "success: sub-noise differences produce no winner" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":null'
            assert_contains "success: stable complete series is accepted" "$T/state/flowoffload-benchmark/last-result.json" '"accepted":true'
            assert_contains "success: system metadata is stored" "$T/state/flowoffload-benchmark/last-result.json" '"system":{"router_model":"Fixture Router","openwrt_version":"OpenWrt 24.10 fixture","z2kow_version":"p-86.14","wan_interface":"wan0"}'
            assert_contains "success: last successful result is retained" "$T/state/flowoffload-benchmark/last-success.json" '"status":"completed"'
            python3 -m json.tool "$T/state/flowoffload-benchmark/last-result.json" >/dev/null 2>&1 && _t_ok || _t_bad "success: result is valid JSON"
            ;;
        error|error-after-success)
            assert_ne "error: worker reports failure" "0" "$_rc"
            assert_eq "error: final status failed" "failed" "$(z2k_ow_offload_benchmark_field status)"
            assert_contains "error: incomplete series has no percentage comparisons" "$T/state/flowoffload-benchmark/last-result.json" '"software_vs_none":{"download_pct":null,"upload_pct":null,"cpu_pct":null}'
            if [ "$_case" = error-after-success ]; then
                cmp -s "$_preserved_success" "$T/state/flowoffload-benchmark/last-success.json" && _t_ok || _t_bad "error: failed attempt preserves last successful result"
            fi
            ;;
        stop)
            assert_ne "stop: worker reports stopped" "0" "$_rc"
            assert_eq "stop: final status stopped" "stopped" "$(z2k_ow_offload_benchmark_field status)"
            ;;
        hardware-apply-fail|hardware-unsupported)
            assert_eq "$_case: unsupported hardware is skipped without failing comparison" "0" "$_rc"
            assert_eq "$_case: terminal status completed" "completed" "$(z2k_ow_offload_benchmark_field status)"
            assert_contains "$_case: no false hardware measurements" "$T/state/flowoffload-benchmark/last-result.json" '"hardware":{"runs":[],"available":false'
            ;;
        hardware-fast)
            assert_eq "hardware-fast: completed" "completed" "$(z2k_ow_offload_benchmark_field status)"
            assert_contains "hardware-fast: hardware recommended only after observed HW_OFFLOAD" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":{"mode":"hardware"'
            assert_contains "hardware-fast: comparison is against software median" "$T/state/flowoffload-benchmark/last-result.json" '"hardware_vs_software":{"download_pct":20'
            assert_contains "hardware-fast: hardware-versus-none uses raw medians" "$T/state/flowoffload-benchmark/last-result.json" '"hardware_vs_none":{"download_pct":71'
            assert_eq "hardware-fast: interleaves five balanced rounds" 'none software hardware software hardware none hardware none software none hardware software hardware software none' "$(sed -n '1,15p' "$T/applied.log" | tr '\n' ' ' | sed 's/ $//')"
            ;;
        hardware-conflict)
            assert_contains "hardware-conflict: SQM detected" "$T/state/flowoffload-benchmark/last-result.json" '"sqm":"confirmed"'
            assert_not_contains "hardware-conflict: hardware is not recommended" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":\{"mode":"hardware"'
            assert_contains "hardware-conflict: software remains recommendation" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":{"mode":"software"'
            ;;
        hardware-unobserved)
            assert_contains "hardware-unobserved: request alone is not proof" "$T/state/flowoffload-benchmark/last-result.json" '"offload_observed":false'
            assert_not_contains "hardware-unobserved: hardware is not recommended" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":\{"mode":"hardware"'
            ;;
        health-broken)
            assert_contains "health-broken: NFQUEUE inactivity is recorded per mode" "$T/state/flowoffload-benchmark/last-result.json" '"software":{"accepted":false,"reason":"nfqueue-inactive"}'
            assert_contains "health-broken: unhealthy runtime blocks overall acceptance" "$T/state/flowoffload-benchmark/last-result.json" '"health_accepted":false'
            assert_contains "health-broken: raw software samples remain available" "$T/state/flowoffload-benchmark/last-result.json" '"software":{"runs":[{'
            assert_contains "health-broken: recommendation is blocked" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":null'
            ;;
        observer-failure)
            assert_contains "observer failure: the exact snapshot collection error is retained" "$T/state/flowoffload-benchmark/last-result.json" '"snapshot_error":"observer exited with status 42: fixture nft permission denied"'
            assert_contains "observer failure: missing before snapshot blocks health acceptance" "$T/state/flowoffload-benchmark/last-result.json" '"none":{"accepted":false,"reason":"health-snapshot-missing"}'
            assert_contains "observer failure: the affected run retains its rejection reason" "$T/state/flowoffload-benchmark/last-result.json" '"health_accepted":false,"rejection_reason":"health-snapshot-missing"'
            assert_contains "observer failure: measured network samples remain available" "$T/state/flowoffload-benchmark/last-result.json" '"download_mbps":100'
            ;;
        observer-empty)
            assert_contains "empty observer result: collection cause is retained" "$T/state/flowoffload-benchmark/last-result.json" '"snapshot_error":"observer returned an empty snapshot"'
            assert_contains "empty observer result: health remains fail-closed" "$T/state/flowoffload-benchmark/last-result.json" '"none":{"accepted":false,"reason":"health-snapshot-missing"}'
            ;;
        cpu-unknown)
            assert_contains "cpu-unknown: unavailable CPU remains null" "$T/state/flowoffload-benchmark/last-result.json" '"cpu_avg":null'
            ;;
        noisy)
            assert_contains "noisy: large run spread is reported" "$T/state/flowoffload-benchmark/last-result.json" '"unstable":true'
            assert_contains "noisy: unstable series is explicitly rejected" "$T/state/flowoffload-benchmark/last-result.json" '"accepted":false'
            assert_contains "noisy: unstable series has no winner" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":null'
            cmp -s "$_preserved_success" "$T/state/flowoffload-benchmark/last-success.json" && _t_ok || _t_bad "noisy: unstable series is not recorded as a last successful benchmark"
            ;;
        noisy-upload)
            assert_contains "noisy-upload: large upload spread is reported" "$T/state/flowoffload-benchmark/last-result.json" '"unstable":true'
            assert_contains "noisy-upload: unstable upload series is rejected" "$T/state/flowoffload-benchmark/last-result.json" '"accepted":false'
            assert_contains "noisy-upload: no performance recommendation is emitted" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":null'
            cmp -s "$_preserved_success" "$T/state/flowoffload-benchmark/last-success.json" && _t_ok || _t_bad "noisy-upload: unstable series is not recorded as a last successful benchmark"
            ;;
        two-outliers)
            assert_contains "two-outliers: repeated deviations beyond 10% make series unstable" "$T/state/flowoffload-benchmark/last-result.json" '"unstable":true'
            assert_contains "two-outliers: unstable series is rejected" "$T/state/flowoffload-benchmark/last-result.json" '"accepted":false'
            assert_contains "two-outliers: unstable series has no recommendation" "$T/state/flowoffload-benchmark/last-result.json" '"recommendation":null'
            assert_contains "two-outliers: unstable series has no percentage comparisons" "$T/state/flowoffload-benchmark/last-result.json" '"software_vs_none":{"download_pct":null,"upload_pct":null,"cpu_pct":null}'
            assert_contains "two-outliers: full download range is retained in result" "$T/state/flowoffload-benchmark/last-result.json" '"run_range_pct":{"download":12.0,"upload":0.0}'
            cmp -s "$_preserved_success" "$T/state/flowoffload-benchmark/last-success.json" && _t_ok || _t_bad "two-outliers: unstable series is not recorded as a last successful benchmark"
            ;;
        single-outlier)
            assert_contains "single-outlier: one deviation is tolerated by the robust stability check" "$T/state/flowoffload-benchmark/last-result.json" '"accepted":true'
            assert_contains "single-outlier: full range remains visible" "$T/state/flowoffload-benchmark/last-result.json" '"run_range_pct":{"download":15.0,"upload":0.0}'
            ;;
    esac
}

run_case success
run_case error-after-success
run_case error
run_case stop
run_case hardware-apply-fail
run_case hardware-unsupported
run_case hardware-fast
run_case hardware-conflict
run_case hardware-unobserved
run_case health-broken
run_case observer-failure
run_case observer-empty
run_case cpu-unknown
run_case noisy
run_case noisy-upload
run_case two-outliers
run_case single-outlier
run_case success

printf 'FLOWOFFLOAD=software\n' > "$Z2K_CONFIG"
rm -rf "$T/state/flowoffload-benchmark" "$T/tmp/flowoffload-benchmark"
_session="$(z2k_ow_offload_benchmark_start cloudflare)" || { _t_bad "initial benchmark accepted"; _t_done; exit 1; }
if z2k_ow_offload_benchmark_start cloudflare >/dev/null 2>&1; then
    _t_bad "concurrent benchmark rejected"
else
    _t_ok
fi
rm -rf "$(z2k_ow_offload_benchmark_lock_dir)" "$(z2k_ow_offload_benchmark_session_dir)"

# Boot/stale recovery uses the persisted original mode and does not claim the
# marker until the config mode has been restored and verified.
printf 'FLOWOFFLOAD=none\n' > "$Z2K_CONFIG"
printf 'mode=software\npid=99999999\nboot=%s\nsession=stale\n' \
    "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$(z2k_ow_offload_benchmark_restore_file)"
z2k_ow_offload_benchmark_recover
assert_eq "stale recovery restores saved mode" "software" "$(z2k_ow_offload_benchmark_mode_from_config)"
[ ! -f "$(z2k_ow_offload_benchmark_restore_file)" ] && _t_ok || _t_bad "verified stale recovery clears marker"

_t_done
