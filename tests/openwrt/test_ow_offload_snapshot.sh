#!/bin/sh
# Canonical Selective FLOWOFFLOAD snapshot: one observed runtime source for
# status API, CLI diagnostics and benchmark health checks.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-offload-snapshot"
ow_fixture_init || { echo "FAIL[ow-offload-snapshot]: fixture" >&2; exit 1; }
trap 'ow_fixture_done' EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
mkdir -p "$T/bin" "$T/chains" "$T/proc" "$T/sys-module" "$T/modules" "$T/state" "$T/tmp"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_CONFIG="$T/config" Z2K_NFT_RULESET_FIXTURE="$T/ruleset"
export CONFIG_FILE="$T/config"
export Z2K_NFT_FLOWTABLE_FIXTURE="$T/flowtable" Z2K_NFT_CHAIN_DIR="$T/chains"
export Z2K_CONNTRACK_FILE="$T/conntrack" Z2K_HW_NAT_FILE="$T/proc/hw_nat"
export Z2K_PROC_MODULES="$T/proc/modules" Z2K_SYS_MODULE_DIR="$T/sys-module"
export Z2K_MODULE_DIR="$T/modules" Z2K_DIAG_PROC_ROOT="$T/proc"
export Z2K_DIAG_AUTOCIRCULAR_DEFAULT_FALLBACK_DIR="$T/tmp"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
  "list ruleset")
    [ "${NFT_FAIL:-0}" = 1 ] && exit 1
    cat "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null
    exit 0 ;;
  "list flowtable inet "*)
    [ -r "$Z2K_NFT_FLOWTABLE_FIXTURE" ] || exit 1
    cat "$Z2K_NFT_FLOWTABLE_FIXTURE"
    exit 0 ;;
  "list chain inet "*)
    _chain=${5:-}
    [ -r "$Z2K_NFT_CHAIN_DIR/$_chain" ] || exit 1
    cat "$Z2K_NFT_CHAIN_DIR/$_chain"
    exit 0 ;;
  "list table inet fw4")
    sed -n '/^table inet fw4 {/,/^}/p' "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null
    exit 0 ;;
  "list table inet zapret2")
    cat "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
  *flow_offloading_hw*) printf '%s\n' "${UCI_FLOW_HW:-0}" ;;
  *flow_offloading*) printf '%s\n' "${UCI_FLOW_SOFT:-0}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
cat > "$T/bin/conntrack" <<'EOF'
#!/bin/sh
[ "${CT_FAIL:-0}" = 1 ] && exit 1
cat "$Z2K_CONNTRACK_FILE" 2>/dev/null
EOF
chmod +x "$T/bin/conntrack"
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
[ "${UBUS_FAIL:-0}" = 1 ] && exit 1
cat "$Z2K_DIAG_PROCD_FIXTURE" 2>/dev/null
EOF
chmod +x "$T/bin/ubus"
cat > "$T/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "$*" in
  *@.z2k.instances.z2k.running*) sed -n 's/.*"running":[[:space:]]*\([^,}]*\).*/\1/p' "$Z2K_DIAG_PROCD_FIXTURE" ;;
  *@.z2k.instances.z2k.pid*) sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$Z2K_DIAG_PROCD_FIXTURE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/jsonfilter"

snapshot_field() {
    _snapshot=$1 _key=$2
    printf '%s\n' "$_snapshot" | tr ';' '\n' | sed -n "s/^[[:space:]]*${_key}=//p" | head -1 | tr -d ' \t\r\n'
}
write_runtime() {
    cat > "$T/ruleset" <<'EOF'
table inet zapret2 {
 chain forward_hook { queue flags bypass to 200 counter packets 8 bytes 800 }
}
table inet fw4 {
}
EOF
    cat > "$T/flowtable" <<'EOF'
flowtable ft {
 hook ingress priority -1;
 devices = { eth1, lan1, lan2 }
 flags offload
}
EOF
    cat > "$T/chains/flow_offload" <<'EOF'
chain flow_offload {
 jump flow_offload_zapret
}
EOF
    cat > "$T/chains/flow_offload_zapret" <<'EOF'
chain flow_offload_zapret {
 ip daddr 198.51.100.1 return comment "direct flow offloading exemption"
 tcp dport 443 return comment "direct flow offloading exemption"
 goto flow_offload_always
}
EOF
    cat > "$T/chains/flow_offload_always" <<'EOF'
chain flow_offload_always {
 flow add @ft
 counter comment "if offload works here must not be too much traffic"
}
EOF
    printf 'FLOWOFFLOAD=hardware\nQNUM=200\nNFQWS2_OPT="--lua-desync=none"\n"\n' > "$T/config"
    printf 'tcp 6 100 ESTABLISHED src=192.0.2.1 dst=198.51.100.2 [OFFLOAD] [HW_OFFLOAD]\n' > "$T/conntrack"
    : > "$T/proc/modules"
}

write_runtime
_facts=$(z2k_ow_flowoffload_status)
printf '%s\n' "$_facts" > "$T/status"
assert_eq "snapshot reads configured mode" hardware "$(snapshot_field "$_facts" configured_mode)"
assert_eq "flowtable is observed" present "$(snapshot_field "$_facts" flowtable_state)"
assert_eq "hardware request comes from flowtable flags" offload "$(snapshot_field "$_facts" flowtable_flags)"
assert_eq "flowtable devices are reported as configured" eth1,lan1,lan2 "$(snapshot_field "$_facts" flowtable_devices)"
assert_eq "HW marker is the observed dataplane evidence" hardware "$(snapshot_field "$_facts" actual_dataplane)"
assert_eq "exemptions are counted only in zapret chain" 2 "$(snapshot_field "$_facts" exemption_rules)"
assert_eq "NFQUEUE counters are observed" active "$(snapshot_field "$_facts" packet_visibility)"
assert_eq "selective chain structure is verified" complete "$(snapshot_field "$_facts" selective_state)"
assert_eq "hardware request is separate from observation" 1 "$(snapshot_field "$_facts" hardware_requested)"
assert_eq "hardware observed is separate from capability" observed "$(snapshot_field "$_facts" hardware_observed)"
assert_eq "offload markers are counted" 1 "$(snapshot_field "$_facts" offloaded_connections)"
assert_eq "hardware markers are counted" 1 "$(snapshot_field "$_facts" hw_offloaded_connections)"

printf 'FLOWOFFLOAD=software\nQNUM=200\n' > "$T/config"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "software does not present hardware as unverified" not-applicable "$(snapshot_field "$_facts" hardware_observed)"
assert_eq "software exposes hardware as unused" not-applicable "$(snapshot_field "$_facts" hardware_state)"
assert_eq "configured software can differ from observed hardware" hardware "$(snapshot_field "$_facts" actual_dataplane)"

printf 'FLOWOFFLOAD=software\nQNUM=200\n' > "$T/config"
sed 's/packets 8 bytes 800/packets 0 bytes 0/' "$T/ruleset" > "$T/ruleset.new" && mv "$T/ruleset.new" "$T/ruleset"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "NFQUEUE rules with zero packets are not observed" not-observed "$(snapshot_field "$_facts" packet_visibility)"
: > "$T/ruleset"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "no NFQUEUE rules means inactive" inactive "$(snapshot_field "$_facts" packet_visibility)"
_facts=$(NFT_FAIL=1 z2k_ow_flowoffload_status)
assert_eq "unreadable nft runtime is unavailable" unavailable "$(snapshot_field "$_facts" packet_visibility)"
unset NFT_FAIL
printf 'FLOWOFFLOAD=none\n' > "$T/config"
cat > "$T/ruleset" <<'EOF'
table inet zapret2 {
 chain input { queue flags bypass to 200 counter packets 2450 bytes 500000 }
}
EOF
rm -f "$T/flowtable"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "none mode still observes an active NFQUEUE path" active "$(snapshot_field "$_facts" packet_visibility)"
assert_eq "none mode retains NFQUEUE rule count" 1 "$(snapshot_field "$_facts" nfqueue_rules)"
assert_eq "none mode retains NFQUEUE packet count" 2450 "$(snapshot_field "$_facts" nfqueue_packets)"

printf 'FLOWOFFLOAD=software\nENABLED=1\nNFQWS2_OPT="\n--lua-desync=circular:fails=3\n"\n' > "$T/config"
mkdir -p "$T/proc/4242" "$T/circular-cache/extra_strats/cache/autocircular" "$T/circular-state"
printf '{"z2k":{"instances":{"z2k":{"running":true,"pid":4242}}}}\n' > "$T/diag-procd.json"
export Z2K_DIAG_PROCD_FIXTURE="$T/diag-procd.json"
printf '%s\000' "$T/circular-cache/nfq2/nfqws2" '--lua-desync=circular:fails=3' > "$T/proc/4242/cmdline"
printf 'Z2K_STATE_DIR_OVERRIDE=%s\000Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE=%s\000' "$T/circular-state" "$T/tmp" > "$T/proc/4242/environ"
printf '192.0.2.1\t198.51.100.1\t443\n' > "$T/circular-state/state.tsv"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "configured and observed circular runtime is active" active "$(snapshot_field "$_facts" circular_state)"
sed 's/^FLOWOFFLOAD=software$/FLOWOFFLOAD=none/' "$T/config" > "$T/config.new" && mv "$T/config.new" "$T/config"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "none mode continues to observe Circular independently" active "$(snapshot_field "$_facts" circular_state)"
assert_eq "none mode continues to observe NFQUEUE independently" active "$(snapshot_field "$_facts" packet_visibility)"
printf 'FLOWOFFLOAD=software\nENABLED=1\nNFQWS2_OPT="\n--lua-desync=circular:fails=3\n"\n' > "$T/config"
printf '{"z2k":{"instances":{"z2k":{"running":false,"pid":4242}}}}\n' > "$T/diag-procd.json"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "configured circular with stopped procd is broken" broken "$(snapshot_field "$_facts" circular_state)"
printf '{"z2k":{"instances":{"z2k":{"running":true,"pid":4242}}}}\n' > "$T/diag-procd.json"
_facts=$(UBUS_FAIL=1 z2k_ow_flowoffload_status)
assert_eq "unreadable circular procd state is unavailable" unavailable "$(snapshot_field "$_facts" circular_state)"
_facts=$(CONFIG_FILE="$T/missing-config" z2k_ow_flowoffload_status)
assert_eq "unreadable circular configuration is unknown" unknown "$(snapshot_field "$_facts" circular_state)"
export CONFIG_FILE="$T/config"

printf 'FLOWOFFLOAD=software\nQNUM=200\n' > "$T/config"
UCI_FLOW_SOFT=1 _facts=$(UCI_FLOW_SOFT=1 z2k_ow_flowoffload_status)
assert_eq "global fw4 flow offload is visible" enabled "$(snapshot_field "$_facts" global_fw4_offload)"
assert_eq "global fw4 and zapret2 are a reported conflict" global_fw4+zapret2 "$(snapshot_field "$_facts" owner_conflict)"

write_runtime
rm -f "$T/chains/flow_offload_always"
_facts=$(z2k_ow_flowoffload_status)
assert_eq "missing required selective chain marks path incomplete" incomplete "$(snapshot_field "$_facts" selective_state)"
_t_done
