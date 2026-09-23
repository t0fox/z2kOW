#!/bin/sh
# Additive firewall repair must remove only stale z2k WAN-bound NFQUEUE rules.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wan-clean.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
. "$ROOT/lib/wan.sh"

awk '/^z2k_sweep_stale_wan_nfqueue\(\)/{f=1} f{print} f && /^}/{exit}' "$ROOT/files/S99zapret2.new" > "$TMP/fn"
. "$TMP/fn"
awk '/^z2k_sweep_orphan_nfqueue\(\)/{f=1} f{print} f && /^}/{exit}' "$ROOT/files/S99zapret2.new" > "$TMP/orphan"
. "$TMP/orphan"

mkdir "$TMP/bin"
export TMP
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP/ip.log"
case "$1" in
    -6)
        [ "${IP6_FAIL:-0}" = 1 ] && exit 1
        [ -n "${ROUTES6:-}" ] && printf '%s\n' "$ROUTES6"
        ;;
    *)
        [ "${IP4_FAIL:-0}" = 1 ] && exit 1
        [ -n "${ROUTES4:-}" ] && printf '%s\n' "$ROUTES4"
        ;;
esac
exit 0
EOF
cat > "$TMP/bin/iptables-save" <<'EOF'
#!/bin/sh
cat "$TMP/rules4"
EOF
cat > "$TMP/bin/ip6tables-save" <<'EOF'
#!/bin/sh
cat "$TMP/rules6"
EOF
cat > "$TMP/bin/iptables" <<'EOF'
#!/bin/sh
state="$TMP/rules4"
[ "$1" = -w ] && shift
[ "$1" = -t ] && shift 2
[ "$1" = -D ] || exit 1
shift
target="-A $*"
printf '%s\n' "$target" >> "$TMP/deleted"
awk -v target="$target" '!removed && $0==target {removed=1; next} {print}' "$state" > "$state.new"
mv "$state.new" "$state"
EOF
sed 's/rules4/rules6/' "$TMP/bin/iptables" > "$TMP/bin/ip6tables"
chmod +x "$TMP/bin/"*
PATH="$TMP/bin:$PATH"; export PATH
QNUM=200

cat > "$TMP/rules4" <<'EOF'
-A POSTROUTING -o eth3 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A POSTROUTING -o nwg0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A POSTROUTING -o usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A POSTROUTING -o usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A INPUT -i usb0 -p udp -j NFQUEUE --queue-num 200 --queue-bypass
-A FORWARD -i usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A FORWARD -i usb0 -p tcp -j NFQUEUE --queue-num 2000 --queue-bypass
-A PREROUTING -i usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A INPUT -o usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A POSTROUTING -o usb0 -j ACCEPT
EOF
cat > "$TMP/rules6" <<'EOF'
-A POSTROUTING -o wan6 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A INPUT -i old6 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
EOF
: > "$TMP/deleted"
: > "$TMP/ip.log"
ROUTES4='default dev eth3
default dev nwg0'
ROUTES6='default dev wan6'
export ROUTES4 ROUTES6

z2k_sweep_stale_wan_nfqueue
[ "$(wc -l < "$TMP/deleted" | tr -d ' ')" = 5 ]
[ "$(grep -c -- '^-A POSTROUTING -o usb0 .*--queue-num 200 ' "$TMP/rules4")" = 0 ]
! grep -Eq 'queue-num 2000|PREROUTING|INPUT -o| -j ACCEPT' "$TMP/deleted"
grep -q -- '-o eth3 .*queue-num 200 ' "$TMP/rules4"
grep -q -- '-o nwg0 .*queue-num 200 ' "$TMP/rules4"
printf 'PASS: stale WAN sweep removes duplicate stale owned rules and preserves selected/main VPN, foreign, wrong-direction and native rules\n'

: > "$TMP/deleted"
z2k_sweep_stale_wan_nfqueue
[ ! -s "$TMP/deleted" ]
printf 'PASS: stale WAN sweep is idempotent after duplicate removal\n'

# Explicit selection is authoritative. A failed or empty automatic read is
# unknown/no-WAN state and must not delete anything for that family.
cat > "$TMP/rules4" <<'EOF'
-A POSTROUTING -o eth3 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
-A INPUT -i usb0 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
EOF
cat > "$TMP/rules6" <<'EOF'
-A POSTROUTING -o eth3 -p tcp -j NFQUEUE --queue-num 200 --queue-bypass
EOF
: > "$TMP/deleted"
: > "$TMP/ip.log"
WAN_IFACE='eth3,usb0 eth3'
export WAN_IFACE
z2k_sweep_stale_wan_nfqueue
[ ! -s "$TMP/deleted" ]
[ ! -s "$TMP/ip.log" ]
printf 'PASS: explicit selected devices are preserved without route discovery\n'

unset WAN_IFACE
IP4_FAIL=1 IP6_FAIL=1; export IP4_FAIL IP6_FAIL
: > "$TMP/ip.log"
z2k_sweep_stale_wan_nfqueue
[ ! -s "$TMP/deleted" ]
printf 'PASS: failed WAN discovery skips cleanup\n'
unset IP4_FAIL IP6_FAIL

ROUTES4=''; ROUTES6=''; export ROUTES4 ROUTES6
z2k_sweep_stale_wan_nfqueue
[ ! -s "$TMP/deleted" ]
printf 'PASS: empty WAN discovery skips cleanup\n'

# Full stop remains deliberately broad for this queue number.
cat > "$TMP/rules4" <<'EOF'
-A POSTROUTING -o eth3 -j NFQUEUE --queue-num 200 --queue-bypass
-A PREROUTING -i usb0 -j NFQUEUE --queue-num 200 --queue-bypass
-A FORWARD -i usb0 -j NFQUEUE --queue-num 2000 --queue-bypass
EOF
: > "$TMP/rules6"
: > "$TMP/deleted"
z2k_sweep_orphan_nfqueue
[ "$(wc -l < "$TMP/deleted" | tr -d ' ')" = 2 ]
! grep -q 'queue-num 2000' "$TMP/deleted"
printf 'PASS: full stop still removes every own-queue orphan and preserves queue 2000\n'
