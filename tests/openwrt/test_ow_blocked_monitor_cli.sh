#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-blocked-monitor-cli"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-blocked-monitor.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/root/platform/openwrt" "$T/etc/state" "$T/tmp"
cat > "$T/root/platform/openwrt/paths.sh" <<EOF
Z2K_ROOT="$T/root"
Z2K_ETC="$T/etc"
Z2K_CONFIG="$T/etc/config"
Z2K_STATE="$T/etc/state"
Z2K_TMP="$T/tmp"
EOF
cat > "$T/monitor.sh" <<'EOF'
#!/bin/sh
printf 'cache=%s\nconfig=%s\nargs=%s\n' \
    "$Z2K_BLOCKED_MONITOR_CACHE" "$ZAPRET_CONFIG" "$*"
EOF
chmod 0755 "$T/monitor.sh"

_out=$(Z2K_ROOT="$T/root" Z2K_BLOCKED_MONITOR_SCRIPT="$T/monitor.sh" \
    sh "$REPO/platform/openwrt/z2kow.sh" blocked-monitor status)
printf '%s\n' "$_out" > "$T/out"
assert_contains "operator CLI forwards blocked monitor action" "$T/out" 'args=status'
assert_contains "blocked monitor cache is on tmpfs" "$T/out" "cache=$T/tmp/blocked-monitor"
assert_contains "blocked monitor reads OpenWrt config" "$T/out" "config=$T/etc/config"
assert_contains "CLI documents the optional monitor command" "$REPO/platform/openwrt/z2kow.sh" 'blocked-monitor <start|stop|status|tail>'
assert_contains "tcpdump remains a real OpenWrt system dependency" \
    "$REPO/platform/openwrt/release.sh" 'apk add kmod-nft-queue kmod-tun kmod-nfnetlink-log conntrack openssl-util jsonfilter tcpdump-mini'

_t_done
