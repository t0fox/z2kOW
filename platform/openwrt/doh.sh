#!/bin/sh
# Стабильная точка совместимости. Жизненным циклом DNS управляет dnsproxy.sh.
_z2k_doh_adapter=${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/dnsproxy.sh
[ -r "$_z2k_doh_adapter" ] || _z2k_doh_adapter="$(dirname "$0")/dnsproxy.sh"
[ -r "$_z2k_doh_adapter" ] || _z2k_doh_adapter=./platform/openwrt/dnsproxy.sh
. "$_z2k_doh_adapter"
