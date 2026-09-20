#!/bin/sh
# tests/openwrt/test_ow_diag.sh - diagnostics platform seam.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIAG="$REPO/files/z2k-diag.sh"
AD="$REPO/platform/openwrt/diag.sh"
ENV="$REPO/platform/openwrt/env.sh"
MK="$REPO/package/openwrt/Makefile"
OWN="$REPO/package/openwrt/ownership.map"

assert_file "OpenWrt diagnostics adapter exists" "$AD"
assert_contains "common diagnostic has neutral hook" "$DIAG" 'Z2K_DIAG_HOOK='
assert_contains "health delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" health'
assert_contains "firewall delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" firewall'
assert_contains "telegram delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" tunnel'
assert_contains "WARP delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" warp'
assert_contains "platform delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" platform'
assert_contains "offload delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" offload'
assert_contains "lists delegate through hook" "$DIAG" '"$Z2K_DIAG_HOOK" lists'
assert_contains "network path delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" netpath'
assert_contains "adapter hook exported" "$ENV" 'Z2K_DIAG_HOOK='
assert_contains "adapter hook reads procd state" "$AD" '"$_init" running'
assert_contains "adapter hook uses canonical core-ready predicate" "$AD" 'z2k_ow_core_ready'
assert_contains "adapter hook checks nft NFQUEUE" "$AD" 'queue flags bypass to 200'
assert_contains "adapter hook uses OpenWrt nfq path" "$AD" 'Z2K_NFQWS2'
assert_contains "common diagnostic uses canonical nfq path" "$DIAG" 'Z2K_NFQWS2:-'
assert_contains "direct OpenWrt diagnostic bootstraps platform env" "$DIAG" 'platform/openwrt/paths.sh'
assert_contains "direct OpenWrt diagnostic loads hook" "$DIAG" 'platform/openwrt/env.sh'
assert_contains "canonical nfq path is exported" "$ENV" 'export Z2K_NFQWS2'
assert_contains "adapter hook uses package TG path" "$AD" '$_bin/tg-mtproxy-client'
assert_contains "adapter hook uses package WARP path" "$AD" '$_bin/z2k-warpd'
assert_contains "adapter hook classifies offload" "$AD" 'OFFLOAD_NOT_ACTIVE'
assert_contains "adapter hook reports unknown backend" "$AD" 'BACKEND_UNKNOWN'
assert_contains "adapter hook reports selected FLOWOFFLOAD" "$AD" 'flowoffload mode'
assert_contains "adapter hook reports zapret2 flowtable" "$AD" 'zapret2 flowtable'
assert_contains "adapter hook reports exemptions" "$AD" 'exemptions'
assert_contains "adapter hook reports owner conflict" "$AD" 'owner conflict'
assert_contains "adapter hook separates packet visibility" "$AD" 'packet visibility'
assert_contains "adapter hook does not claim circular proof" "$AD" 'circular'
assert_contains "offload mode trim is BusyBox-safe" "$AD" "tr -d ' \t\r\n'"
assert_contains "adapter hook checks fastroute presence" "$AD" 'nf_conntrack_fastroute'
assert_contains "adapter hook uses canonical WARP status" "$AD" 'warp/status.json'
assert_not_contains "adapter hook never prints WARP key" "$AD" 'WARP_PLUS_KEY'
assert_not_contains "adapter hook never prints private key" "$AD" 'private_key'
assert_contains "Makefile installs executable diag hook" "$MK" 'platform/openwrt/diag.sh $(1)/usr/lib/z2k/platform/openwrt/'
assert_contains "ownership map has diag hook" "$OWN" '/usr/lib/z2k/platform/openwrt/diag.sh package'

_t_done
