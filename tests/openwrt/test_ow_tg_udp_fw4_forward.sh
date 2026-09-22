#!/bin/sh
# Regression: ACCEPT in zapret2's independent forward base chain does not
# override a later fw4 forward-policy drop. The package must install a narrow
# fw4 admission for the dedicated Telegram UDP TUN in both directions.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-udp-fw4-forward"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FW4="$REPO/package/openwrt/files/usr/share/nftables.d/chain-pre/forward/90-z2k-tg-udp.nft"
MK="$REPO/package/openwrt/Makefile"

assert_file "package-owned fw4 Telegram UDP include exists" "$FW4"
assert_contains "outbound admission requires Telegram mark, TUN, and UDP" "$FW4" \
    'meta mark & 0x08000000 == 0x08000000 oifname "z2ktg0" meta l4proto udp accept comment "!z2k: Telegram UDP forwarded traffic"'
assert_contains "IPv4 return admission is limited to Telegram servers" "$FW4" \
    'iifname "z2ktg0" meta l4proto udp ip saddr { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24 } accept comment "!z2k: Telegram UDP forwarded traffic"'
assert_contains "IPv6 return admission is limited to Telegram servers" "$FW4" \
    'iifname "z2ktg0" meta l4proto udp ip6 saddr { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280::/32 } accept comment "!z2k: Telegram UDP forwarded traffic"'
assert_not_contains "fw4 include does not use parser-invalid bare udp" "$FW4" \
    '" udp (accept|ip[46]?[[:space:]])'
assert_eq "fw4 include adds exactly three narrow admission rules" "3" \
    "$(grep -Ec 'accept comment "!z2k: Telegram UDP forwarded traffic"' "$FW4" 2>/dev/null || printf 0)"
assert_not_contains "include does not admit TCP" "$FW4" 'tcp accept'
assert_not_contains "include does not admit the LAN or WAN interface" "$FW4" \
    '(oifname|iifname) "(br-|wan|eth)'
assert_contains "adapter package installs the fw4 Telegram include" "$MK" \
    '90-z2k-tg-udp.nft'

_t_done
