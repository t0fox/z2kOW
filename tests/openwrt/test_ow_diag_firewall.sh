#!/bin/sh
# Regression coverage for OpenWrt NFQUEUE path ownership and traffic counters.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag-firewall"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-firewall.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/proc/4242"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_CONFIG="$T/config" Z2K_DIAG_PROC_ROOT="$T/proc"
export Z2K_NFQUEUE_PROC="$T/nfqueue" Z2K_NFT_RULESET_FIXTURE="$T/ruleset"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
  "list ruleset"|"-a list ruleset") cat "$Z2K_NFT_RULESET_FIXTURE"; exit 0 ;;
  "list chain inet zapret2 "*)
    chain=${5:-}
    awk -v wanted="$chain" '$1=="chain" && $2==wanted {inside=1} inside {print} inside && /}/ {exit}' \
        "$Z2K_NFT_RULESET_FIXTURE"
    exit 0 ;;
  "list set inet zapret2 wanif") printf 'elements = { "wan0" }\n'; exit 0 ;;
  "list set inet zapret2 "*) exit 0 ;;
  "list table inet fw4") exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/nft"
cat > "$T/nfqueue" <<'EOF'
200 4242 2 65535 0 0 0
201 5252 2 65535 0 0 0
EOF
printf '%s\000' "$T/runtime/nfq2/nfqws2" > "$T/proc/4242/cmdline"
cat > "$T/config" <<'EOF'
QNUM=200
EOF
cat > "$T/ruleset" <<'EOF'
table inet zapret2 {
 chain postnat_hook { type filter hook postrouting priority 101; jump postnat; }
 chain prenat_hook { type filter hook prerouting priority -101; jump prenat; }
 chain postnat { ip daddr @wanif tcp dport 443 queue flags bypass to 200 counter packets 5 bytes 500; udp dport 443 queue flags bypass to 2000 counter packets 99 bytes 9900; }
 chain prenat { ip saddr @wanif tcp sport 443 queue flags bypass to 200 counter packets 7 bytes 700; }
}
table inet fw4 {
 chain forward { counter packets 100 bytes 10000 queue flags bypass to 200 counter packets 77 bytes 7700; }
}
EOF

run_diag() { sh "$REPO/platform/openwrt/diag.sh" firewall > "$T/output" 2>&1; }
assert_out() { assert_contains "$1" "$T/output" "$2"; }
assert_not_out() { assert_not_contains "$1" "$T/output" "$2"; }
run_diag
assert_out "OpenWrt reports outgoing queue rules in the owned postnat chain" 'NFQUEUE исходящие : 1'
assert_out "OpenWrt proves outgoing hook reachability" 'OUT path           : reachable'
assert_out "OpenWrt reports incoming queue rules in the owned prenat chain" 'NFQUEUE входящие  : 1'
assert_out "OpenWrt proves incoming hook reachability" 'IN path            : reachable'
assert_out "queue consumer is tied to the matching queue process" 'queue 200 consumer: PID 4242'
assert_out "detailed state reuses the canonical z2k firewall verifier" 'static contract    : proven (z2k_ow_fw_verify)'
assert_out "outgoing traffic packet and byte counters are shown" 'NFQUEUE OUT packets=5 bytes=500'
assert_out "incoming traffic packet and byte counters are shown" 'NFQUEUE IN  packets=7 bytes=700'
assert_not_out "wrong queue number and fw4 queue counters are excluded" 'packets=99|packets=77'

# A queue rule without a hook jump is present but unreachable.
sed 's/jump prenat;/comment "jump prenat removed";/' "$T/ruleset" > "$T/ruleset.new"
mv "$T/ruleset.new" "$T/ruleset"
run_diag
assert_out "incoming queue rule behind a missing hook is unreachable" 'IN path            : unreachable'
sh "$REPO/platform/openwrt/diag.sh" health > "$T/output" 2>&1
assert_out "health summary uses the same missing incoming path proof" 'NFQUEUE входящий path unreachable'

# Wrong queue and foreign rules do not inflate the owned OUT count.
sed 's/to 200 counter packets 5 bytes 500/to 201 counter packets 5 bytes 500/' "$T/ruleset" > "$T/ruleset.new"
mv "$T/ruleset.new" "$T/ruleset"
run_diag
assert_out "wrong-qnum outgoing rule is not counted" 'NFQUEUE исходящие : 0'
assert_out "wrong-qnum outgoing rule does not prove a path" 'OUT path           : unreachable'

_t_done
