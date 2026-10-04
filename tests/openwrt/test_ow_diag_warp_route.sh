#!/bin/sh
# z2k diag must explain the platform route proof independently of the WARP tunnel.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag-warp-route"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-warp-route.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/state/warp" "$T/tmp/warp" "$T/proc/777"
export PATH="$T/bin:/usr/bin:/bin"
export Z2K_ROOT="$REPO" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp"
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc"
export WARP_BIN="$T/bin/z2k-warpd" WARP_PBR_OWNER="$T/tmp/warp/pbr.owner"
export Z2K_WARP_SOURCE_ONLY=1
printf '#!/bin/sh\nexit 0\n' > "$WARP_BIN"
chmod +x "$WARP_BIN"
printf 'GAME_WARP_ENABLED=1\n' > "$Z2K_CONFIG"
printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg","endpoint":"162.159.192.6:2408"}\n' > "$T/tmp/warp/status.json"
printf '%s\000' "$WARP_BIN" run > "$T/proc/777/cmdline"

cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
printf '777\n'
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  'link show dev z2ktun0') exit 0 ;;
  'rule show') cat "${IP_RULES:-/dev/null}" ;;
  'route show table 989') cat "${IP_ROUTE:-/dev/null}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
  'list chain inet zapret2 z2k_warp_mss')
    [ "${NFT_FULL:-0}" = 1 ] || exit 1
    printf '%s\n' 'oifname "z2ktun0" tcp flags syn tcp option maxseg size set rt mtu' 'iifname "z2ktun0" tcp flags syn tcp option maxseg size set 1240' ;;
  'list chain inet zapret2 z2k_warp_fwd')
    [ "${NFT_FULL:-0}" = 1 ] || exit 1
    printf '%s\n' 'oifname "z2ktun0" accept' ;;
  'list chain inet zapret2 z2k_warp_nat')
    [ "${NFT_FULL:-0}" = 1 ] || exit 1
    printf '%s\n' 'oifname "z2ktun0" masquerade' ;;
  'list chain inet fw4 forward')
    [ "${NFT_FULL:-0}" = 1 ] || exit 1
    printf '%s\n' 'meta mark & 0x80000000 == 0x80000000 oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/pidof" "$T/bin/ip" "$T/bin/nft"

run_diag() {
    Z2K_ROOT="$REPO" Z2K_ADAPTER_DIR="$REPO/platform/openwrt" \
      Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp" \
      Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc" \
      WARP_BIN="$T/bin/z2k-warpd" WARP_PBR_OWNER="$T/tmp/warp/pbr.owner" \
      PATH="$T/bin:/usr/bin:/bin" \
      "$REPO/platform/openwrt/diag.sh" warp > "$T/output" 2>&1
}

run_diag
assert_contains "transport ready but absent nft plumbing is explicitly unrouted" "$T/output" 'route_ready       : 0'
assert_contains "diag names the missing nft/tun layer" "$T/output" 'routing reason   : nft/tun rules absent or inconsistent'
assert_contains "missing edge metadata is explicit" "$T/output" 'edge             : colo=unavailable country=unavailable rtt_ms=unavailable selection=unavailable'

printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg","endpoint":"162.159.192.6:2408","edge_colo":"FRA","edge_country":"DE","edge_rtt_ms":31,"edge_selection":"foreign"}\n' > "$T/tmp/warp/status.json"
printf '499: from 172.16.9.9/32 lookup 989\n500: from all fwmark 0x80000000/0x80000000 lookup 989\n' > "$T/ip-rules"
printf 'default dev z2ktun0\n' > "$T/ip-route"
printf 'mark=0x80000000\nmask=0x80000000\npref=500\ntable=989\niface=z2ktun0\n' > "$WARP_PBR_OWNER"
NFT_FULL=1 IP_RULES="$T/ip-rules" IP_ROUTE="$T/ip-route" run_diag
assert_contains "all OpenWrt route probes promote tunnel to routing-ready" "$T/output" 'route_ready       : 1'
assert_contains "healthy route has no failure reason" "$T/output" 'routing reason   : confirmed'
assert_contains "diag prints actual Cloudflare edge metadata" "$T/output" 'edge             : colo=FRA country=DE rtt_ms=31 selection=foreign'

_t_done
