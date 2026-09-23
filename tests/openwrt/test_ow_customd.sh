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
# Mirror stock custom_runner's lexical glob order: Discord is first, then STUN.
alloc_dnum() { case "$1" in DNUM_DISCORD_MEDIA) eval "$1=2000" ;; DNUM_STUN4ALL) eval "$1=2001" ;; esac; }
alloc_qnum() { case "$1" in QNUM_DISCORD_MEDIA) eval "$1=65300" ;; QNUM_STUN4ALL) eval "$1=65301" ;; esac; }
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

# Live r55 acceptance reproduced a Discord discovery datagram being queued to
# both custom.d's NFQUEUE and the generic core UDP queue.  The live runtime
# emits Discord IPv4 and STUN IPv4/IPv6 rules in postnat only. Model its parsed
# nft output and run the adapter firewall apply path.
. "$AD/firewall.sh"
z2k_ow_fw_source() { :; }
_rebuild_fixture=1
zapret_apply_firewall() {
    [ "$_rebuild_fixture" = 1 ] || return 0
    cp "$T/nft.postnat.before" "$T/nft.postnat"
}
nft() {
    case "$1 $2 $3 $4 $5 $6" in
        "-a list chain inet zapret2 postnat") cat "$T/nft.postnat" ;;
        "insert rule inet zapret2 postnat position")
            _chain="$5"
            _pos="$7"
            shift 7
            _new=$(printf '%s ' "$@" | sed \
                's/ comment z2k-openwrt: customd overlap guard $/ comment "z2k-openwrt: customd overlap guard"/')
            _mock_handle=$((100 + $(wc -l < "$T/nft.calls" | tr -d ' ')))
            _new=" $_new # handle $_mock_handle"
            printf '%s\n' "$_chain|$*" >> "$T/nft.calls"
            awk -v pos="# handle $_pos" -v new="$_new" \
                'index($0,pos) { print new; inserted=1 } { print }
                 END { if (!inserted) exit 1 }' "$T/nft.$_chain" > "$T/nft.next" \
                && mv "$T/nft.next" "$T/nft.$_chain"
            ;;
        "delete rule inet zapret2 postnat handle")
            _handle="$7"
            awk -v h="# handle $_handle" 'index($0,h) { next } { print }' \
                "$T/nft.postnat" > "$T/nft.next" && mv "$T/nft.next" "$T/nft.postnat"
            ;;
        *) echo "unexpected nft invocation: $*" >&2; return 1 ;;
    esac
}
cat > "$T/nft.postnat.before" <<'EOF'
table inet zapret2 {
 chain postnat {
  meta nfproto ipv6 udp length >= 28 @ih,32,32 0x2112a442 @ih,0,8 & 0xc0 == 0x0 @ih,30,2 0x0 meta mark set meta mark | 0x20000000 queue flags bypass to 65301 # handle 41
  meta nfproto ipv4 udp length >= 28 @ih,32,32 0x2112a442 @ih,0,8 & 0xc0 == 0x0 @ih,30,2 0x0 meta mark set meta mark | 0x20000000 queue flags bypass to 65301 # handle 42
  meta nfproto ipv4 udp dport { 19294-19344, 50000-50099 } udp length 82 @ih,0,32 0x10046 @ih,64,128 0x0 @ih,192,128 0x0 @ih,320,128 0x0 @ih,448,128 0x0 meta mark set meta mark | 0x20000000 queue flags bypass to 65300 # handle 43
  meta nfproto ipv6 udp dport { 443, 1400, 3478-3481, 5349, 19294-19344, 50000-50099 } ct original packets 0-8 meta mark set meta mark | 0x20000000 queue flags bypass to 200 # handle 44
  meta nfproto ipv4 udp dport { 443, 1400, 3478-3481, 5349, 19294-19344, 50000-50099 } ct original packets 0-8 meta mark set meta mark | 0x20000000 queue flags bypass to 200 # handle 45
 }
}
EOF
: > "$T/nft.calls"
DISABLE_CUSTOM=0; export DISABLE_CUSTOM
z2k_ow_fw_apply && _t_ok || _t_bad "custom.d guards applied with stock firewall"
_discord_guard=$(grep -nF '@ih,0,32 0x10046' "$T/nft.postnat" | grep -F 'customd overlap guard' | cut -d: -f1 | head -1)
_discord_core=$(grep -nF 'ct original packets 0-8' "$T/nft.postnat" | cut -d: -f1 | head -1)
[ -n "$_discord_guard" ] && [ -n "$_discord_core" ] && [ "$_discord_guard" -lt "$_discord_core" ] \
    && _t_ok || _t_bad "Discord exact return follows custom queue and precedes core queue"
_stun_out=$(grep -nF 'udp length >= 28 @ih,32,32 0x2112a442' "$T/nft.postnat" | grep -F 'customd overlap guard' | cut -d: -f1 | head -1)
_stun_out_core=$(grep -nF 'ct original packets 0-8' "$T/nft.postnat" | cut -d: -f1 | head -1)
[ -n "$_stun_out" ] && [ -n "$_stun_out_core" ] && [ "$_stun_out" -lt "$_stun_out_core" ] \
    && _t_ok || _t_bad "STUN outbound exact return precedes core queue"
_guard_pairs=$(awk '
    index($0,"queue flags bypass to 65300") && index($0,"@ih,0,32 0x10046") { pending="@ih,0,32 0x10046"; q++; next }
    index($0,"queue flags bypass to 65301") && index($0,"@ih,32,32 0x2112a442") { pending="@ih,32,32 0x2112a442"; q++; next }
    pending != "" {
        if (index($0,"customd overlap guard") && index($0,pending) && index($0," return")) ok++
        pending=""
    }
    END { if (q == 3 && ok == 3) print "3/3" }
' "$T/nft.postnat")
assert_eq "every Discord/STUN family queue has exact following return" "3/3" "$_guard_pairs"
assert_eq "three customd exact guards installed" "3" "$(grep -c 'customd overlap guard' "$T/nft.postnat")"

# Applying the same adapter path without a firewall rebuild is idempotent.
_rebuild_fixture=0
z2k_ow_fw_apply && _t_ok || _t_bad "custom.d guard reapply"
assert_eq "guard reapply adds no duplicate rules" "3" "$(grep -c 'customd overlap guard' "$T/nft.postnat")"

# With the user toggle off, remove adapter-owned guards without touching core
# UDP queue rules, even if the surrounding zapret2 table was not rebuilt.
_rebuild_fixture=0
DISABLE_CUSTOM=1; export DISABLE_CUSTOM
z2k_ow_fw_apply && _t_ok || _t_bad "disabled custom.d leaves stock firewall intact"
! grep -q 'customd overlap guard' "$T/nft.postnat" \
    && _t_ok || _t_bad "disabled custom.d removes adapter guards"
grep -q 'queue flags bypass to 200' "$T/nft.postnat" \
    && _t_ok || _t_bad "disabled custom.d preserves core UDP NFQUEUE"

_t_done
