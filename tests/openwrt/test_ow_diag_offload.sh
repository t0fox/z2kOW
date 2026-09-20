#!/bin/sh
# test_ow_diag_offload.sh - diagnostic output must describe runtime state and
# owner conflict, without converting config into packet/circular proof.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag-offload"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/run" "$T/tmp"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_RUN="$T/run"
export Z2K_CONFIG="$T/config" Z2K_INIT="$T/init" Z2K_BIN="$T/bin"
printf 'FLOWOFFLOAD=software\n' > "$T/config"
printf '#!/bin/sh\nexit 0\n' > "$T/init"
chmod +x "$T/init"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1" = list ] && [ "$2" = ruleset ]; then
    printf 'table inet zapret2 { flowtable ft { devices = { "wan" } } flow add @ft }\n'
    printf 'table inet fw4 { flowtable ft { devices = { "wan" } } flow add @ft }\n'
    exit 0
fi
if [ "$1" = list ] && [ "$2" = flowtable ]; then
    [ "$4" = zapret2 ] && [ "$5" = ft ] && exit 0
    exit 1
fi
if [ "$1" = list ] && [ "$2" = table ]; then
    [ "$4" = fw4 ] && printf 'flowtable ft { devices = { "wan" } }\n' && exit 0
    exit 1
fi
if [ "$1" = list ] && [ "$2" = chain ]; then
    printf 'flow add @ft\nreturn comment "direct flow offloading exemption"\n'
    exit 0
fi
exit 1
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/conntrack" <<'EOF'
#!/bin/sh
if grep -q '^FLOWOFFLOAD=hardware' "${Z2K_CONFIG:-}" 2>/dev/null; then
    printf 'tcp 6 100 ESTABLISHED src=192.0.2.10 dst=198.51.100.10 [HW_OFFLOAD]\n'
else
    printf 'tcp 6 100 ESTABLISHED src=192.0.2.10 dst=198.51.100.10 [OFFLOAD]\n'
fi
EOF
chmod +x "$T/bin/conntrack"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
    *flow_offloading_hw*) printf '1\n' ;;
    *flow_offloading*) printf '1\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"

_out="$($REPO/platform/openwrt/diag.sh offload 2>&1)"
printf '%s\n' "$_out" > "$T/output"
assert_contains "actual selected mode" "$T/output" "flowoffload mode   : software"
assert_contains "actual selective table" "$T/output" "zapret2 flowtable  : present"
assert_contains "actual exemptions" "$T/output" "zapret2 exemptions  : 1"
assert_contains "global/selective conflict" "$T/output" "owner conflict     : global_fw4+zapret2"
assert_contains "software dataplane observed" "$T/output" "observed dataplane : software"
assert_contains "visibility remains unknown" "$T/output" "packet visibility  : UNKNOWN"
assert_contains "circular remains unknown" "$T/output" "circular           : UNKNOWN"

printf 'FLOWOFFLOAD=hardware\n' > "$T/config"
_out="$($REPO/platform/openwrt/diag.sh offload 2>&1)"
printf '%s\n' "$_out" > "$T/output-hardware"
assert_contains "hardware dataplane observed" "$T/output-hardware" "hardware offload   : observed"
assert_contains "hardware dataplane fact" "$T/output-hardware" "observed dataplane : hardware"

_t_done
