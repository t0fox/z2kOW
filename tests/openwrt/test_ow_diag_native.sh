#!/bin/sh
# End-to-end OpenWrt diagnostics must use OpenWrt facts and native probes.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag-native"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIAG="$REPO/files/z2k-diag.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-native.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root" "$T/etc/state" "$T/etc/webpanel" "$T/tmp/runtime" "$T/bin"
printf "DISTRIB_RELEASE='23.05.5'\nDISTRIB_TARGET='mediatek/filogic'\n" > "$T/openwrt_release"
printf 'tag=p-86.11\nseq=134\n' > "$T/etc/state/installed-release"
printf 'tag=p-86.10\n' > "$T/root/.z2k-installed-tag"
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
printf '9091\n' > "$T/etc/webpanel/port"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
  "-q get system.@system[0].hostname") echo router ;;
  "-q get firewall.@defaults[0].flow_offloading") echo 0 ;;
  "-q get firewall.@defaults[0].flow_offloading_hw") echo 0 ;;
esac
EOF
chmod +x "$T/bin/uci"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
  "list ruleset") cat "$NFT_FIXTURE" ;;
  "list set inet zapret2 z2k_warp_dst4") exit 1 ;;
esac
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/netstat" <<'EOF'
#!/bin/sh
printf 'tcp 0 0 0.0.0.0:9091 0.0.0.0:* LISTEN 1234/lighttpd\n'
EOF
chmod +x "$T/bin/netstat"
cat > "$T/nft" <<'EOF'
table inet zapret2 {
 chain forward_hook { type filter hook forward priority filter; policy accept; }
}
table inet fw4 {
 chain forward { type filter hook forward priority filter; policy accept; }
}
EOF
_out=$(PATH="$T/bin:$PATH" NFT_FIXTURE="$T/nft" Z2K_PLATFORM=openwrt \
  Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" \
  Z2K_TMP="$T/tmp" Z2K_RUN="$T/tmp/runtime" Z2K_CONFIG="$T/etc/config" \
  Z2K_NFQWS2="$T/root/nfqws2" Z2K_INIT="$T/init" ZAPRET2_DIR="$T/root" \
  Z2K_ADAPTER_DIR="$REPO/platform/openwrt" \
  Z2K_OPENWRT_RELEASE_FILE="$T/openwrt_release" \
  Z2K_DIAG_HOOK="$REPO/platform/openwrt/diag.sh" \
  sh "$DIAG" --full)
printf '%s\n' "$_out" > "$T/output"
_legacy_findings="Ent""ware|NDM"" hook|/opt не"" смонтирован|NOT MOUNTED"
assert_not_contains "OpenWrt output omits all legacy platform findings" "$T/output" "$_legacy_findings"
assert_contains "OpenWrt report uses installed-release as product version" "$T/output" 'z2kOW product     : p-86.11'
assert_contains "OpenWrt report includes native platform section" "$T/output" 'platform           : OpenWrt'
assert_contains "OpenWrt report includes release metadata" "$T/output" 'OpenWrt release'
assert_contains "OpenWrt report reads release from OpenWrt release file" "$T/output" '23.05.5'
assert_contains "OpenWrt report reads target from OpenWrt release file" "$T/output" 'mediatek/filogic'
assert_contains "OpenWrt report includes overlay facts" "$T/output" 'overlay'
assert_contains "OpenWrt report includes swap facts" "$T/output" 'swap'
assert_contains "OpenWrt report includes procd probe" "$T/output" 'procd'
assert_contains "OpenWrt report includes netifd probe" "$T/output" 'netifd'
assert_contains "OpenWrt report includes ubus probe" "$T/output" 'ubus'
assert_contains "OpenWrt report includes UCI probe" "$T/output" 'UCI'
assert_contains "OpenWrt report identifies fw4" "$T/output" 'fw4'
assert_contains "OpenWrt report identifies nftables" "$T/output" 'nftables'
assert_contains "OpenWrt report inspects panel listener" "$T/output" 'panel listener'
assert_contains "panel probe uses the configured webpanel port" "$T/output" 'panel port         : 9091'
assert_contains "panel probe reports the process bound to that port" "$T/output" '1234/lighttpd'
_legacy_findings_more="unknown arch|Ent""ware|/opt|iptables.*missing"
assert_not_contains "OpenWrt report avoids legacy architecture and iptables findings" "$T/output" "$_legacy_findings_more"

_t_done
