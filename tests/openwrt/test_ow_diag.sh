#!/bin/sh
# tests/openwrt/test_ow_diag.sh - diagnostics platform seam.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-diag"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DIAG="$REPO/files/z2k-diag.sh"
AD="$REPO/platform/openwrt/diag.sh"
ENV="$REPO/platform/openwrt/env.sh"
STAGE="$REPO/scripts/openwrt/stage-rootfs.sh"

assert_file "OpenWrt diagnostics adapter exists" "$AD"
assert_contains "common diagnostic has neutral hook" "$DIAG" 'Z2K_DIAG_HOOK='
assert_contains "health delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" health'
assert_contains "firewall delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" firewall'
assert_contains "telegram delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" tunnel'
assert_contains "WARP delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" warp'
assert_contains "platform delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" platform'
assert_contains "offload delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" offload'
assert_contains "autocircular delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" autocircular'
assert_contains "lists delegate through hook" "$DIAG" '"$Z2K_DIAG_HOOK" lists'
assert_contains "network path delegates through hook" "$DIAG" '"$Z2K_DIAG_HOOK" netpath'
assert_contains "adapter hook exported" "$ENV" 'Z2K_DIAG_HOOK='
assert_contains "adapter hook reads procd state" "$AD" '"$_init" running'
assert_contains "p-86.10 diagnostic reports queued Telegram CONNECT drops" "$AD" 'CONNECT throttled'
assert_contains "OpenWrt diagnostic falls back to procd logread" "$AD" 'logread'
assert_contains "adapter hook uses canonical core-ready predicate" "$AD" 'z2k_ow_core_ready'
assert_contains "adapter hook checks nft NFQUEUE" "$AD" 'queue flags bypass to 200'
assert_contains "adapter hook uses OpenWrt nfq path" "$AD" 'Z2K_NFQWS2'
assert_contains "common diagnostic uses canonical nfq path" "$DIAG" 'Z2K_NFQWS2:-'
assert_contains "direct OpenWrt diagnostic bootstraps platform env" "$DIAG" 'platform/openwrt/paths.sh'
assert_contains "direct OpenWrt diagnostic loads hook" "$DIAG" 'platform/openwrt/env.sh'
assert_contains "canonical nfq path is exported" "$ENV" 'export Z2K_NFQWS2'
assert_contains "adapter hook selects architecture TG binary" "$REPO/platform/openwrt/tg.sh" \
    'z2k_ow_tg_bin_path "${Z2K_BIN:-/usr/lib/z2k/bin}"'
assert_contains "adapter hook resolves architecture WARP runtime path" "$AD" 'z2k_ow_warp_bin_path "$_warp_adapter"'
assert_contains "adapter hook uses explicit disabled/unknown states" "$AD" 'conclusion=disabled'
assert_contains "adapter hook reports unavailable backend" "$AD" 'backend=unavailable'
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
assert_contains "OpenWrt error scan includes the actual Insta refresh log" "$ENV" '/tmp/z2k-log/z2k-insta-refresh.log'
assert_contains "OpenWrt error scan includes all webpanel error logs" "$ENV" 'z2k-webpanel-startcheck.log'
assert_contains "complete rootfs stages diagnostic hook source" "$STAGE" 'files/z2k-diag.sh" usr/lib/z2k/z2k-diag.sh'
assert_contains "complete rootfs marks diagnostic hook executable" "$STAGE" 'usr/lib/z2k/z2k-diag.sh 0755'
assert_contains "complete rootfs stages adapter diag hook" "$STAGE" 'platform/openwrt/*.sh'

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-diag-version.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/root" "$T/etc/z2k/state"
printf 'tag=p-86.11\nseq=134\n' > "$T/etc/z2k/state/installed-release"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
_diag=$(Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" \
    Z2K_STATE="$T/etc/z2k/state" Z2K_OPENWRT_RELEASE_FILE="$T/openwrt_release" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --short 2>/dev/null)
printf '%s\n' "$_diag" > "$T/diag-short.txt"
assert_contains "short OpenWrt diagnostics reads the one installed-release state" \
    "$T/diag-short.txt" 'z2kOW=p-86.11 '
assert_contains "short OpenWrt diagnostics reads the native OpenWrt architecture" \
    "$T/diag-short.txt" 'arch=aarch64_cortex-a53'
_diag_json=$(Z2K_PLATFORM=openwrt Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" \
    Z2K_STATE="$T/etc/z2k/state" Z2K_OPENWRT_RELEASE_FILE="$T/openwrt_release" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --json 2>/dev/null)
printf '%s\n' "$_diag_json" > "$T/diag.json"
assert_contains "JSON diagnostics includes only installed release version" "$T/diag.json" '"version":"p-86.11"'
assert_not_contains "JSON diagnostics has no secondary version axes" "$T/diag.json" '"(engine|build|product)"'
assert_contains "JSON diagnostics reads native OpenWrt architecture without opkg" "$T/diag.json" \
    '"arch":"aarch64_cortex-a53"'

# The common log scanner must read the OpenWrt updater's actual log location.
mkdir -p "$T/log" "$T/tmp" "$T/bin"
cat > "$T/bin/ping" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${Z2K_PING_ARGS_FILE:-/dev/null}"
printf '%s\n' '3 packets transmitted, 2 received, 33% packet loss' \
    'rtt min/avg/max/mdev = 10.0/12.5/15.0/2.5 ms'
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\r\n' 'HTTP/2 200' 'Date: Thu, 01 Jan 1970 00:00:00 GMT'
EOF
cat > "$T/bin/date" <<'EOF'
#!/bin/sh
if [ "${1:-}" = +%s ]; then printf '%s\n' "${Z2K_TEST_NOW:-0}"; else exec /usr/bin/date "$@"; fi
EOF
chmod +x "$T/bin/ping" "$T/bin/curl" "$T/bin/date"
_today=$(date '+%Y-%m-%d')
printf '%s 12:00:00 FAIL: warp games index unavailable — keeping current lists\n' "$_today" \
    > "$T/log/z2k-warp-games.log"
printf '%s\n' 'identity registered for 203.0.113.7' 'CONNECT_OK' > "$T/log/tg-tunnel.log"
printf '{"ts":%s,"results":[{"name":"Резолвер роутера","udp":"works","verdict":"works"}]}' \
    "$(date +%s)" > "$T/dns-check.json"
_diag_full=$(PATH="$T/bin:$PATH" Z2K_TEST_NOW=0 VPS_IP=198.51.100.7 Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" Z2K_ETC="$T/etc/z2k" \
    Z2K_STATE="$T/etc/z2k/state" Z2K_TMP="$T/tmp" Z2K_LOG="$T/log" \
    Z2K_DIAG_LOGS="$T/log/z2k-warp-games.log" \
    Z2K_DIAG_STARTUP_LOG="$T/log/z2k-warp-games.log" \
    Z2K_DIAG_TUNNEL_LOG="$T/log/tg-tunnel.log" \
    Z2K_DIAG_DNS_CHECK_JSON="$T/dns-check.json" Z2K_PING_ARGS_FILE="$T/ping-args" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --full 2>/dev/null)
printf '%s\n' "$_diag_full" > "$T/diag-full.txt"
assert_contains "OpenWrt diag sees the actual WARP game-list failure" "$T/diag-full.txt" \
    'FAIL: warp games index unavailable'
assert_contains "OpenWrt diag identifies the native WARP log" "$T/diag-full.txt" \
    'z2k-warp-games.log'
assert_contains "OpenWrt tunnel probes parse the upstream three-packet ping" "$T/diag-full.txt" \
    'VPS ping 198.51.100.7     : avg 12.5 ms, loss 33%'
assert_contains "OpenWrt tunnel clock compares against the relay date" "$T/diag-full.txt" \
    'clock vs relay    : +0 s (ок)'
assert_contains "OpenWrt tunnel shows its actual log path" "$T/diag-full.txt" \
    "tunnel log        : $T/log/tg-tunnel.log"
assert_contains "OpenWrt tunnel shows recent CONNECT events" "$T/diag-full.txt" 'CONNECT_OK'
assert_eq "OpenWrt tunnel ping uses exactly three short-timeout packets" '-c 3 -W 2 198.51.100.7' "$(cat "$T/ping-args")"
awk '
  /^=== что не так ===$/ { health=1; next }
  health && /^=== / { exit }
  health { print }
' "$T/diag-full.txt" > "$T/health-section.txt"
assert_not_contains "OpenWrt issue summary contains no DNS or Insta detail" "$T/health-section.txt" \
    'dns check|dnsmasq addnhosts|Insta IP refresh'
awk '
  /^=== network path ===$/ { netpath=1; next }
  netpath && /^=== / { exit }
  netpath { print }
' "$T/diag-full.txt" > "$T/network-path-section.txt"
assert_contains "OpenWrt network path includes the common DNS checker snapshot" "$T/network-path-section.txt" \
    'dns check         : снимок'
assert_contains "OpenWrt network path includes the DNS resolver verdict" "$T/network-path-section.txt" \
    'резолвер роутера честен'
assert_contains "OpenWrt network path includes the DNS pin probe" "$T/network-path-section.txt" \
    'dnsmasq addnhosts:'
assert_contains "OpenWrt network path includes Insta refresh state" "$T/network-path-section.txt" \
    'Insta IP refresh'

# The OpenWrt replacement for Keenetic ip host must inspect its owned dnsmasq
# addnhosts file and registration, not skip the shared IP-refresh evidence.
mkdir -p "$T/insta-state"
printf '203.0.113.10 instagram.com\n203.0.113.11 www.instagram.com\n' > "$T/insta-state/insta-hosts"
printf 'HOSTS="a b c d e f g h i j k l"\n' > "$T/insta-state/z2k-insta-ip-refresh.sh"
cat > "$T/bin/uci" <<EOF
#!/bin/sh
case "\$*" in
  '-q show dhcp') printf 'dhcp.@dnsmasq[0].addnhosts=$T/insta-state/insta-hosts\\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
_diag_insta=$(PATH="$T/bin:$PATH" Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" \
    Z2K_ETC="$T/etc/z2k" Z2K_STATE="$T/insta-state" \
    Z2K_CONFIG="$T/etc/config" Z2K_INSTA_HOSTS_FILE="$T/insta-state/insta-hosts" \
    Z2K_INSTA_UCI_BIN="$T/bin/uci" Z2K_INSTA_REFRESH_SCRIPT="$T/insta-state/z2k-insta-ip-refresh.sh" \
    Z2K_ADAPTER_DIR="$REPO/platform/openwrt" \
    ZAPRET2_DIR="$REPO" sh "$DIAG" insta 2>/dev/null)
printf '%s\n' "$_diag_insta" > "$T/diag-insta.txt"
assert_contains "OpenWrt diag checks dnsmasq addnhosts registration and record count" \
    "$T/diag-insta.txt" 'dnsmasq addnhosts: registered; 2 records'
assert_contains "OpenWrt Insta report counts refresh-managed hostnames" \
    "$T/diag-insta.txt" 'managed hostnames=12'
assert_contains "OpenWrt diag distinguishes an unproven running DNS configuration" \
    "$T/diag-insta.txt" 'runtime=inactive'

mkdir -p "$T/runtime"
printf 'addn-hosts=%s\n' "$T/insta-state/insta-hosts" > "$T/runtime/dnsmasq.conf"
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
printf ' 123 root 1234 S /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg123\n'
EOF
chmod +x "$T/bin/ps"
_diag_insta_live=$(PATH="$T/bin:$PATH" Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" \
    Z2K_ETC="$T/etc/z2k" Z2K_STATE="$T/insta-state" \
    Z2K_CONFIG="$T/etc/config" Z2K_INSTA_HOSTS_FILE="$T/insta-state/insta-hosts" \
    Z2K_INSTA_UCI_BIN="$T/bin/uci" Z2K_INSTA_REFRESH_SCRIPT="$T/insta-state/z2k-insta-ip-refresh.sh" \
    Z2K_INSTA_DNSMASQ_RUNTIME_CONFIGS="$T/runtime/dnsmasq.conf" \
    Z2K_ADAPTER_DIR="$REPO/platform/openwrt" ZAPRET2_DIR="$REPO" \
    sh "$DIAG" insta 2>/dev/null)
printf '%s\n' "$_diag_insta_live" > "$T/diag-insta-live.txt"
assert_contains "OpenWrt diag confirms dnsmasq loaded the registered host file" \
    "$T/diag-insta-live.txt" 'runtime=active'

printf 'Z2K_INSTA_DNS=0\nZ2K_INSTA_IP_REFRESH=0\n' > "$T/etc/config"
_diag_insta_disabled=$(PATH="$T/bin:$PATH" Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" \
    Z2K_ETC="$T/etc/z2k" Z2K_STATE="$T/insta-state" \
    Z2K_CONFIG="$T/etc/config" Z2K_INSTA_HOSTS_FILE="$T/insta-state/insta-hosts" \
    Z2K_INSTA_UCI_BIN="$T/bin/uci" Z2K_INSTA_REFRESH_SCRIPT="$T/insta-state/z2k-insta-ip-refresh.sh" \
    Z2K_ADAPTER_DIR="$REPO/platform/openwrt" \
    ZAPRET2_DIR="$REPO" sh "$DIAG" insta 2>/dev/null)
printf '%s\n' "$_diag_insta_disabled" > "$T/diag-insta-disabled.txt"
assert_contains "OpenWrt diag respects the user's disabled Insta pins state" \
    "$T/diag-insta-disabled.txt" 'disabled by user'
assert_contains "OpenWrt diag respects the user's disabled refresh state" \
    "$T/diag-insta-disabled.txt" 'Insta IP refresh  : disabled by user'

# The shared PID predicate must ignore the HTTP-only :1444 process.
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
printf '%s\n' ' 123 root 1000 S tg-mtproxy-client --listen=:1444'
EOF
chmod +x "$T/bin/ps"
_diag_tunnel_1444=$(PATH="$T/bin:$PATH" Z2K_ROOT="$REPO" Z2K_DIAG_TUNNEL_LOG="$T/log/tg-tunnel.log" \
    sh "$AD" tunnel 2>/dev/null)
printf '%s\n' "$_diag_tunnel_1444" > "$T/diag-tunnel-1444.txt"
assert_contains "HTTP-only :1444 process is not mistaken for Telegram :1443" \
    "$T/diag-tunnel-1444.txt" 'process :1443      : 0'
assert_contains "HTTP-only :1444 process does not make tunnel ready" \
    "$T/diag-tunnel-1444.txt" 'state              : down'
cat > "$T/bin/ps" <<'EOF'
#!/bin/sh
printf '%s\n' ' 123 root 1000 S tg-mtproxy-client --listen=:1443 --timeout=15m'
EOF
_diag_tunnel_1443=$(PATH="$T/bin:$PATH" Z2K_ROOT="$REPO" Z2K_DIAG_TUNNEL_LOG="$T/log/tg-tunnel.log" \
    sh "$AD" tunnel 2>/dev/null)
printf '%s\n' "$_diag_tunnel_1443" > "$T/diag-tunnel-1443.txt"
assert_contains "Telegram listener process on :1443 is counted" \
    "$T/diag-tunnel-1443.txt" 'process :1443      : 1'
assert_contains "Telegram listener process on :1443 is ready" \
    "$T/diag-tunnel-1443.txt" 'state              : ready'

_diag_report=$(PATH="$T/bin:$PATH" Z2K_TEST_NOW=121 VPS_IP=198.51.100.7 Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" \
    Z2K_ETC="$T/etc/z2k" Z2K_STATE="$T/etc/z2k/state" Z2K_TMP="$T/tmp" Z2K_LOG="$T/log" \
    Z2K_DIAG_LOGS="$T/log/z2k-warp-games.log" Z2K_DIAG_STARTUP_LOG="$T/log/z2k-warp-games.log" \
    Z2K_DIAG_TUNNEL_LOG="$T/log/tg-tunnel.log" Z2K_DIAG_DNS_CHECK_JSON="$T/dns-check.json" \
    ZAPRET2_DIR="$T/root" sh "$DIAG" --report 2>/dev/null)
printf '%s\n' "$_diag_report" > "$T/diag-report.txt"
assert_contains "clock skew beyond the upstream 120 second threshold is unhealthy" \
    "$T/diag-report.txt" 'clock vs relay    : +121 s — ВНЕ ДОПУСКА (±120)'
assert_contains "report mode masks addresses in Telegram logs" "$T/diag-report.txt" 'identity registered for x.x.x.x'
assert_not_contains "report mode does not expose raw addresses in Telegram logs" \
    "$T/diag-report.txt" 'identity registered for 203\.0\.113\.7'

_t_done
