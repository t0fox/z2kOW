#!/bin/sh
# OpenWrt BusyBox nslookup format must be accepted by the shared DNS checker.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-dns-check"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
_dns_source="$REPO/files/z2k-dns-check.sh"

_udp_a_fixture() {
    _fixture=$1
    (
        Z2K_DNS_LIB=1 . "$_dns_source"
        DNS_CHECK_FIXTURE="$_fixture"
        nslookup() { printf '%s\n' "$DNS_CHECK_FIXTURE"; }
        udp_a 127.0.0.1 example.com
    )
}

_openwrt_sample='Server: 127.0.0.1
Address: 127.0.0.1:53

Non-authoritative answer:
Name: example.com
Address: 203.0.113.10
Name: example.com
Address: 198.51.100.20'
_openwrt_got=$(_udp_a_fixture "$_openwrt_sample")
assert_eq "OpenWrt Address: format parses every A record without server address" \
    "$(printf '203.0.113.10\n198.51.100.20')" "$_openwrt_got"

_keenetic_sample='Server: 1.1.1.1
Address 1: 1.1.1.1 one.one.one.one

Name: example.com
Address 1: 203.0.113.10
Address 2: 198.51.100.20 198x51x100x20.static.example.ru'
_keenetic_got=$(_udp_a_fixture "$_keenetic_sample")
assert_eq "Keenetic Address N: format remains supported" \
    "$(printf '203.0.113.10\n198.51.100.20')" "$_keenetic_got"

_t_done
