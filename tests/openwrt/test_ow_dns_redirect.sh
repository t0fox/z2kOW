#!/bin/sh
# Проверка DNS REDIRECT на nftables, включая fail-open при отказе резолвера.
. "$(dirname "$0")/helper.sh"

_t_plan "ow-dns-redirect"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-dns.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/run" "$T/state" "$T/tmp" || exit 1

cat > "$T/bin/ip" <<'STUB'
#!/bin/sh
[ "$1 $2 $3" = "-4 route show" ] || exit 2
cat "$Z2K_DNS_TEST_ROUTES"
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$4" = "127.0.0.1" ] || exit 3
case "$(cat "$Z2K_DNS_TEST_MODE")" in
    ok) echo "Name: $1"; exit 0 ;;
    nx) echo "** server can't find $1: NXDOMAIN"; exit 1 ;;
    servfail) echo "SERVFAIL"; exit 0 ;;
    *) echo "connection timed out"; exit 1 ;;
esac
STUB
cat > "$T/bin/nft" <<'STUB'
#!/bin/sh
case "$1" in
    list) [ -f "$Z2K_DNS_TEST_TABLE" ] || exit 1; cat "$Z2K_DNS_TEST_TABLE" ;;
    delete) rm -f "$Z2K_DNS_TEST_TABLE" ;;
    -f) cp "$2" "$Z2K_DNS_TEST_TABLE" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$T/bin/"* || exit 1

export PATH="$T/bin:$PATH"
export Z2K_ROOT="$REPO"
export Z2K_CONFIG="$T/config"
export Z2K_RUN="$T/run"
export Z2K_CORE_READY="$T/run/core-ready"
export Z2K_TMP="$T/tmp"
export Z2K_DNS_STATE_DIR="$T/state"
export Z2K_DNS_NFT_TABLE="z2k_dns_test"
export Z2K_DNS_TEST_TABLE="$T/nft-table"
export Z2K_DNS_TEST_MODE="$T/mode"
export Z2K_DNS_TEST_ROUTES="$T/routes"
printf 'ENABLED=1\nINIT_APPLY_FW=1\nZ2K_DNS_REDIRECT=1\n' > "$Z2K_CONFIG"
printf '192.168.1.0/24 dev br-lan scope link src 192.168.1.1\n10.0.0.0/24 dev br-iot scope link src 10.0.0.1\n0.0.0.0/0 via 192.168.1.254 dev wan\n' > "$Z2K_DNS_TEST_ROUTES"
: > "$Z2K_CORE_READY"

_script="$REPO/platform/openwrt/dns-redirect.sh"
echo ok > "$Z2K_DNS_TEST_MODE"
sh "$_script" sync && _t_ok || _t_bad "initial redirect failed"
assert_eq "two LAN bridges produce four rules" "4" "$(grep -c 'redirect to :53' "$Z2K_DNS_TEST_TABLE")"
assert_contains "LAN networks are comma-separated in nft set" "$Z2K_DNS_TEST_TABLE" 'ip daddr != { 10.0.0.0/24, 192.168.1.0/24, 127.0.0.0/8 }'
assert_contains "redirect is limited to LAN ingress" "$Z2K_DNS_TEST_TABLE" 'iifname "br-lan" ip daddr !='
assert_contains "loopback and local LAN are excluded" "$Z2K_DNS_TEST_TABLE" '127.0.0.0/8 } udp dport 53'

echo servfail > "$Z2K_DNS_TEST_MODE"
sh "$_script" check && _t_ok || _t_bad "first resolver failure blocked service"
assert_file "one failure leaves redirect active" "$Z2K_DNS_TEST_TABLE"
sh "$_script" check && _t_ok || _t_bad "second resolver failure blocked service"
assert_eq "two failures pause and remove rules" "0" "$( [ -e "$Z2K_DNS_TEST_TABLE" ] && echo 1 || echo 0 )"
assert_eq "pause marker" "1" "$( [ -f "$Z2K_DNS_STATE_DIR/paused" ] && echo 1 || echo 0 )"

echo nx > "$Z2K_DNS_TEST_MODE"
sh "$_script" check && _t_ok || _t_bad "NXDOMAIN was treated as resolver failure"
assert_eq "one success keeps redirect paused" "0" "$( [ -e "$Z2K_DNS_TEST_TABLE" ] && echo 1 || echo 0 )"
sh "$_script" check && _t_ok || _t_bad "second successful resolver check failed"
assert_file "redirect restored after resolver recovery" "$Z2K_DNS_TEST_TABLE"
assert_eq "pause marker cleared" "0" "$( [ -f "$Z2K_DNS_STATE_DIR/paused" ] && echo 1 || echo 0 )"

printf 'ENABLED=1\nINIT_APPLY_FW=1\nZ2K_DNS_REDIRECT=0\n' > "$Z2K_CONFIG"
sh "$_script" sync && _t_ok || _t_bad "disabled redirect cleanup failed"
assert_eq "disabled toggle removes owned table" "0" "$( [ -e "$Z2K_DNS_TEST_TABLE" ] && echo 1 || echo 0 )"

_t_done
