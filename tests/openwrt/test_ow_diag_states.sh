#!/bin/sh
# Regression coverage for OpenWrt diagnostic probe state semantics.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag-states"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-states.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/state" "$T/tmp" "$T/run" "$T/sys-module" "$T/modules" "$T/proc"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp"
export Z2K_RUN="$T/run" Z2K_CONFIG="$T/config" Z2K_INIT="$T/init" Z2K_BIN="$T/bin"
export Z2K_OPENWRT_RELEASE_FILE="$T/openwrt_release" Z2K_MEMINFO="$T/meminfo"
export Z2K_PROC_MODULES="$T/proc/modules" Z2K_SYS_MODULE_DIR="$T/sys-module"
export Z2K_MODULE_DIR="$T/modules" Z2K_HW_NAT_FILE="$T/proc/hw_nat"
export Z2K_FASTROUTE_FILE="$T/proc/fastroute" Z2K_NFT_RULESET_FIXTURE="$T/nft-ruleset"
export Z2K_DIAG_TEST_PS="$T/ps" Z2K_DIAG_TEST_CONNTRACK="$T/conntrack"
printf '#!/bin/sh\nexit 0\n' > "$T/init"
chmod +x "$T/init"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
  "list ruleset")
    [ "${NFT_FAIL:-0}" = 1 ] && exit 1
    [ -r "$Z2K_NFT_RULESET_FIXTURE" ] && cat "$Z2K_NFT_RULESET_FIXTURE"
    exit 0 ;;
  "list flowtable inet zapret2 ft")
    grep -q 'flowtable ft' "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null ;;
  "list chain inet zapret2 flow_offload"*|"list chain inet zapret2 flow_offload_zapret"*|"list chain inet zapret2 flow_offload_always"*|"list chain inet zapret2 forward_hook"*|"list chain inet zapret2 input_hook"*|"list chain inet zapret2 output_hook"*)
    cat "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null ;;
  "list table inet fw4")
    grep -A20 'table inet fw4' "$Z2K_NFT_RULESET_FIXTURE" 2>/dev/null ;;
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
[ -r "$Z2K_DIAG_TEST_CONNTRACK" ] && cat "$Z2K_DIAG_TEST_CONNTRACK"
EOF
chmod +x "$T/bin/conntrack"
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
[ -r "$Z2K_DIAG_TEST_PS" ] && cat "$Z2K_DIAG_TEST_PS"
EOF
chmod +x "$T/bin/ps"
cat > "$T/bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s\n' 'Server: 127.0.0.1' 'Address: 127.0.0.1:53'
if [ "${DNS_FAIL:-0}" = 1 ]; then exit 1; fi
cat "$DNS_FIXTURE"
EOF
chmod +x "$T/bin/nslookup"

run_diag() {
    sh "$REPO/platform/openwrt/diag.sh" "$1" > "$T/output" 2>&1
}
assert_out() { assert_contains "$1" "$T/output" "$2"; }
assert_not_out() { assert_not_contains "$1" "$T/output" "$2"; }

# none is a known disabled state even when capability modules are loaded.
printf 'FLOWOFFLOAD=none\nGAME_WARP_ENABLED=0\n' > "$T/config"
printf 'nf_flow_table 123 0 - Live 0x0\n' > "$T/proc/modules"
: > "$T/nft-ruleset"
run_diag offload
assert_out "none mode is disabled" 'offload state      : disabled'
assert_out "capability remains separate from runtime" 'offload capability : available'
assert_out "disabled software path is N/A" 'software offload   : N/A'
assert_out "disabled hardware path is N/A" 'hardware offload   : N/A'
assert_out "disabled backend is N/A" 'backend            : N/A'
assert_out "packet probe is N/A when offload is disabled" 'packet visibility  : N/A'
assert_not_out "none does not fall through to backend unknown" 'BACKEND_UNKNOWN|backend[[:space:]]*:[[:space:]]*unknown'
assert_not_out "none does not emit universal unknowns" 'packet visibility[[:space:]]*:[[:space:]]*UNKNOWN|circular[[:space:]]*:[[:space:]]*UNKNOWN'

# Runtime marker, not module presence, is the evidence for active offload.
printf 'FLOWOFFLOAD=software\n' > "$T/config"
cat > "$T/nft-ruleset" <<'EOF'
table inet zapret2 {
 flowtable ft { hook ingress priority filter; devices = { "wan" }; }
 chain flow_offload_zapret { flow add @ft; }
 chain forward_hook { counter packets 7 bytes 700 queue flags bypass to 200; }
}
EOF
printf 'tcp 6 100 ESTABLISHED src=192.0.2.1 dst=198.51.100.1 [OFFLOAD]\n' > "$T/conntrack"
run_diag offload
assert_out "software marker means runtime active" 'offload state      : active'
assert_out "software marker sets selected backend" 'backend            : NFT_FLOW_TABLE'
assert_out "queue packet counter means visibility active" 'packet visibility  : active'
assert_out "selected software reports active" 'software offload   : active'
assert_out "unselected hardware path is N/A" 'hardware offload   : N/A'

# A present flowtable without packet markers is configured but not observed active.
printf '' > "$T/conntrack"
sed 's/counter packets 7 bytes 700/counter packets 0 bytes 0/' "$T/nft-ruleset" > "$T/nft-ruleset.new"
mv "$T/nft-ruleset.new" "$T/nft-ruleset"
run_diag offload
assert_out "configured flowtable without runtime marker is not observed" 'offload state      : not-observed'
assert_out "zero queue packets are not-observed, not universal unknown" 'packet visibility  : not-observed'

# Selected mode with no runtime table is inactive; no queue path is inactive too.
: > "$T/nft-ruleset"
run_diag offload
assert_out "missing runtime flowtable is inactive" 'offload state      : inactive'
assert_out "missing queue path is inactive" 'packet visibility  : inactive'

# Failed probes are unavailable; an absent config is genuinely unknown.
NFT_FAIL=1 run_diag offload
assert_out "nft command failure is unavailable" 'offload state      : unavailable'
assert_out "packet probe failure is unavailable" 'packet visibility  : unavailable'
rm -f "$T/config"
run_diag offload
assert_out "missing config makes mode unknown" 'flowoffload mode   : unknown'
assert_out "missing config is genuinely unknown" 'offload state      : unknown'

# WARP-only transport details are gated on the enabled flag.
printf 'GAME_WARP_ENABLED=0\n' > "$T/config"
mkdir -p "$T/tmp/warp"
printf '{"ready":false,"transport":"unknown","endpoint":"unknown"}\n' > "$T/tmp/warp/status.json"
run_diag warp
assert_out "WARP off is explicitly disabled" 'state             : disabled'
assert_not_out "disabled WARP has no transport or endpoint fields" 'transport=.*endpoint=|transport[[:space:]]*:'
printf 'GAME_WARP_ENABLED=1\n' > "$T/config"
printf '{"ready":true,"transport":"wireguard","endpoint":"engage.cloudflareclient.com:2408"}\n' > "$T/tmp/warp/status.json"
run_diag warp
assert_out "enabled ready WARP is active" 'state             : active'
assert_out "active WARP reports transport" 'transport=wireguard'
printf '{"ready":false,"transport":"wireguard","endpoint":"engage.cloudflareclient.com:2408"}\n' > "$T/tmp/warp/status.json"
run_diag warp
assert_out "enabled not-ready WARP is inactive" 'state             : inactive'
rm "$T/tmp/warp/status.json"
run_diag warp
assert_out "missing WARP status is unavailable" 'state             : unavailable'

# OpenWrt version fields lose exactly one surrounding quote; zero swap is disabled.
printf "DISTRIB_RELEASE='25.12.5'\nDISTRIB_TARGET='mediatek/filogic'\n" > "$T/openwrt_release"
cat > "$T/meminfo" <<'EOF'
MemTotal: 256000 kB
MemAvailable: 128000 kB
SwapTotal: 0 kB
SwapFree: 0 kB
EOF
run_diag platform
assert_out "release quote is trimmed" 'OpenWrt release   : 25.12.5'
assert_not_out "release has no trailing quote" "OpenWrt release.*25\\.12\\.5'"
assert_out "target quote is trimmed" 'OpenWrt target    : mediatek/filogic'
assert_out "zero swap is disabled" 'swap              : disabled'

# DNS result is read after Name:, never from the local DNS server's Address.
printf '%s\n' 'Name: example.com' 'Address 1: 93.184.216.34' > "$T/dns-output"
DNS_FIXTURE="$T/dns-output" run_diag netpath
assert_out "resolved target address is reported" 'resolve check      : active example.com -> 93.184.216.34'
assert_not_out "DNS server address is not mistaken for answer" 'resolve check.*127\\.0\\.0\\.1'
DNS_FAIL=1 DNS_FIXTURE="$T/dns-output" run_diag netpath
assert_out "failed resolution is inactive" 'resolve check      : inactive'

# Autocircular checks feature enablement before inspecting state files.
printf 'NFQWS2_OPT="\n--lua-desync=fake --lua-desync=circular:fails=3\n"\n' > "$T/config"
printf '/opt/zapret2/nfq2/nfqws2 --qnum=200 --lua-desync=circular:fails=3\n' > "$T/ps"
printf 'pool\thost\tstrategy\tts\n' > "$T/etc/state/state.tsv"
run_diag autocircular
assert_out "configured live autocircular is active" 'autocircular      : active'
assert_out "empty autocircular state is not-observed" 'state file        : not-observed'
rm "$T/etc/state/state.tsv"
run_diag autocircular
assert_out "enabled autocircular diagnoses missing state" 'state file        : missing'
assert_out "missing state diagnosis is conditional on enabled mechanism" 'state file is missing while autocircular is enabled'
printf 'NFQWS2_OPT="\n--lua-desync=fake\n"\n' > "$T/config"
: > "$T/ps"
run_diag autocircular
assert_out "autocircular is disabled when not configured" 'autocircular      : disabled'
assert_not_out "disabled autocircular does not diagnose missing state" 'state file.*missing|state file is missing'
rm -f "$T/config"
run_diag autocircular
assert_out "unobservable autocircular configuration stays unknown" 'autocircular      : unknown'

_t_done
