#!/bin/sh
# tests/openwrt/test_ow_customd.sh - upstream custom.d parity and lifecycle.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-customd"
ow_fixture_init || { echo "FAIL[ow-customd]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
Z2K_CUSTOM_DIR="$T/custom.d"
Z2K_ZAPRET2_RUNTIME="$T/zapret2"
Z2K_NFQWS2="$T/zapret2/nfq2/nfqws2"
Z2K_CUSTOM_PID_DIR="$T/custom-pids"
export Z2K_CUSTOM_DIR Z2K_ZAPRET2_RUNTIME Z2K_NFQWS2 Z2K_CUSTOM_PID_DIR
mkdir -p "$Z2K_CUSTOM_DIR" "$Z2K_ZAPRET2_RUNTIME/init.d/openwrt" "$Z2K_ZAPRET2_RUNTIME/nfq2"
cp "$AD/custom.d/50-stun4all" "$AD/custom.d/50-discord-media" "$Z2K_CUSTOM_DIR/"
chmod +x "$Z2K_CUSTOM_DIR"/*
printf '#!/bin/sh\ncustom_runner() { :; }\n' > "$Z2K_ZAPRET2_RUNTIME/init.d/openwrt/functions"
printf '#!/bin/sh\n' > "$Z2K_NFQWS2"
chmod +x "$Z2K_NFQWS2"
cat > "$T/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/nft"
PATH="$T:$PATH"; export PATH
. "$AD/customd.sh"

# A complete component set is advertised; a missing upstream example is not.
z2k_ow_customd_available && _t_ok || _t_bad "обязательные custom.d компоненты не признаны"
rm -f "$Z2K_CUSTOM_DIR/50-discord-media"
z2k_ow_customd_available && _t_bad "отсутствующий Discord helper выдан за capability" || _t_ok
cp "$AD/custom.d/50-discord-media" "$Z2K_CUSTOM_DIR/"
chmod +x "$Z2K_CUSTOM_DIR/50-discord-media"

# Execute the upstream runner contract with small test doubles.  This proves
# the helpers preserve their own queues/options and nft predicates, rather
# than merely existing in the package.
alloc_dnum() { case "$1" in DNUM_STUN4ALL) eval "$1=2000" ;; DNUM_DISCORD_MEDIA) eval "$1=2001" ;; esac; }
alloc_qnum() { case "$1" in QNUM_STUN4ALL) eval "$1=65300" ;; QNUM_DISCORD_MEDIA) eval "$1=65301" ;; esac; }
do_nfqws() { printf 'daemon:%s:%s:%s\n' "$1" "$2" "$3" >> "$T/calls"; }
replace_char() { _a="$1"; _b="$2"; shift 2; printf '%s\n' "$@" | tr "$_a" "$_b"; }
fw_nfqws_post() { printf 'ipt:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "$T/calls"; }
nft_fw_nfqws_post() { printf 'nft:%s:%s:%s\n' "$1" "$2" "$3" >> "$T/calls"; }
custom_runner() {
    _fn="$1"; _arg="$2"
    for _script in "$Z2K_CUSTOM_DIR"/*; do
        unset -f "$_fn"
        . "$_script"
        "$_fn" "$_arg"
    done
}
DISABLE_CUSTOM=0; export DISABLE_CUSTOM
: > "$T/calls"
custom_runner zapret_custom_daemons 1
custom_runner zapret_custom_firewall_nft 1
assert_contains "STUN queue/options" "$T/calls" 'daemon:1:2000:--qnum=65300'
assert_contains "Discord queue/options" "$T/calls" 'daemon:1:2001:--qnum=65301'
assert_contains "STUN magic predicate" "$T/calls" '0x2112A442'
assert_contains "Discord media predicate" "$T/calls" '0x00010046'
assert_contains "Discord media port range" "$T/calls" '50000-50099,19294-19344'

# The adapter delegates the daemon hook to the same upstream custom_runner.
z2k_ow_custom_daemons 0 && _t_ok || _t_bad "stop hook"
assert_contains "stop goes through runner" "$T/calls" 'daemon:0'

# DISABLE_CUSTOM=1 suppresses both helper instances without deleting the
# package files; the service stop path remains procd-owned.
DISABLE_CUSTOM=1; export DISABLE_CUSTOM
: > "$T/calls"
z2k_ow_custom_daemons 1
assert_eq "DISABLE_CUSTOM=1 — runner тихий" "" "$(cat "$T/calls")"

DISABLE_CUSTOM=0; export DISABLE_CUSTOM
[ -x "$Z2K_CUSTOM_DIR/50-stun4all" ] && [ -x "$Z2K_CUSTOM_DIR/50-discord-media" ] \
    && _t_ok || _t_bad "upstream custom.d filenames/permissions"

# A crashed/orphaned helper is removed by the same PID+NFQUEUE-owner predicate;
# DISABLE_CUSTOM=1 must not make an old instance immortal.
mkdir -p "$Z2K_CUSTOM_PID_DIR"
sleep 60 & _orphan_pid=$!
printf '%s\n' "$_orphan_pid" > "$Z2K_CUSTOM_PID_DIR/nfqws2_2000.pid"
printf '65300 %s 0\n' "$_orphan_pid" > "$T/nfqueue"
Z2K_NFQUEUE_PROC="$T/nfqueue"; export Z2K_NFQUEUE_PROC
DISABLE_CUSTOM=1; export DISABLE_CUSTOM
z2k_ow_custom_daemons 0
wait "$_orphan_pid" 2>/dev/null || true
[ ! -e "$Z2K_CUSTOM_PID_DIR/nfqws2_2000.pid" ] && ! kill -0 "$_orphan_pid" 2>/dev/null \
    && _t_ok || _t_bad "orphan custom instance survives stop"

# Static lifecycle gates: bounded procd respawn, health ownership, rollback,
# and package delivery are all part of the regression contract.
assert_contains "customd bounded respawn" "$AD/customd.sh" "procd_set_param respawn 3600 5 5"
assert_contains "customd health checks queue owner" "$AD/customd.sh" "_z2k_ow_customd_owner_ready"
assert_contains "customd health gates ready" "$REPO/platform/openwrt/env.sh" "z2k_ow_customd_runtime_ready"
assert_contains "customd rollback cleanup" "$REPO/package/openwrt/files/etc/init.d/z2k" "z2k_ow_customd_stop_instances"
assert_contains "customd package install" "$REPO/package/openwrt/Makefile" "custom.d/50-stun4all"
assert_contains "customd flag survives config regeneration" "$REPO/lib/config_official.sh" "saved_DISABLE_CUSTOM"

_t_done
