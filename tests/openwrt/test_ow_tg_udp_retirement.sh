#!/bin/sh
# Upgrade-time retirement of the experimental p-85.8 Telegram UDP path.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-udp-retirement"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tg-retire.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/proc/4242" "$T/opt/bin"
export T
Z2K_OW_PROC_ROOT="$T/proc"
Z2K_OW_CONFIG="$T/config"
Z2K_OW_CORE_INIT="$T/z2k-init"
Z2K_OW_FIREWALL="$T/firewall"
Z2K_OW_TG_READY="$T/tg-udp.ready"
Z2K_OW_LEGACY_SHELL="$T/opt/bin/sh"
Z2K_OW_LEGACY_MARKER="$T/opt/bin/.z2k-tg-udp-legacy-shell-dir-owned"
export Z2K_OW_PROC_ROOT Z2K_OW_CONFIG Z2K_OW_CORE_INIT Z2K_OW_FIREWALL
export Z2K_OW_TG_READY Z2K_OW_LEGACY_SHELL Z2K_OW_LEGACY_MARKER

cat > "$T/z2k-init" <<'INIT'
#!/bin/sh
case "$1" in
    running) [ -f "$T/core-running" ] ;;
    stop)
        printf 'stop\n' >> "$T/service.log"
        rm -f "$T/core-running" "$T/proc/4242/cmdline"
        ;;
    start)
        printf 'start\n' >> "$T/service.log"
        : > "$T/core-running"
        mkdir -p "$T/proc/4343"
        printf '%s\0' '/usr/lib/z2k/bin/tg-mtproxy-client' '--listen=:1443' '--listen=:1444' '--timeout=15m' > "$T/proc/4343/cmdline"
        ;;
    *) exit 2 ;;
esac
INIT
cat > "$T/firewall" <<'FW'
#!/bin/sh
printf '%s\n' "$*" >> "$T/firewall.log"
FW
chmod +x "$T/z2k-init" "$T/firewall"

# These command doubles keep actual decision-making in the migration helper;
# they only expose a small, deterministic snapshot of the old live objects.
ip() {
    printf '%s\n' "$*" >> "$T/ip.log"
    case "$*" in
        '-4 rule show') printf '%s\n' "$IP4_RULES" ;;
        '-6 rule show') printf '%s\n' "$IP6_RULES" ;;
        '-4 route show table 988') printf '%s\n' "$IP4_ROUTES" ;;
        '-6 route show table 988') printf '%s\n' "$IP6_ROUTES" ;;
        *' rule del pref 89 fwmark '*)
            case "$*" in *'-4 '*) IP4_RULES=$(printf '%s\n' "$IP4_RULES" | awk '$1 != "89:"') ;;
                *'-6 '*) IP6_RULES=$(printf '%s\n' "$IP6_RULES" | awk '$1 != "89:"') ;; esac ;;
        *' route del '*) : ;;
        *' -d link show dev z2ktg0') printf '7: z2ktg0: <POINTOPOINT> mtu 1500 tun type tun\n' ;;
        'link delete dev z2ktg0') : ;;
        *) : ;;
    esac
}
nft() {
    printf '%s\n' "$*" >> "$T/nft.log"
    case "$*" in
        '-a list ruleset')
            printf '%s\n' 'meta mark & 0x08000000 == 0x08000000 oifname "z2ktg0" accept comment "!z2k: Telegram UDP forwarded traffic"' ;;
        '-a list chain inet zapret2 prenat')
            printf '%s\n' 'ip daddr @z2k_tg_udp_dc4 meta l4proto udp return # handle 11' 'ip daddr @unrelated meta l4proto udp return # handle 12' ;;
        '-a list chain inet zapret2 postnat')
            printf '%s\n' 'ip6 saddr @z2k_tg_udp_dc6 meta l4proto udp return # handle 13' ;;
        '-a list chain inet zapret2 z2k_tg_udp_mark')
            printf '%s\n' 'chain z2k_tg_udp_mark { type filter hook prerouting priority mangle; policy accept; }' 'iifname "lan" meta l4proto udp ip daddr @z2k_tg_udp_dc4 meta mark 0x00000000 meta mark set 0x08000000 # handle 21' 'iifname "lan" meta l4proto udp ip6 daddr @z2k_tg_udp_dc6 meta mark 0x00000000 meta mark set 0x08000000 # handle 22' ;;
        '-a list chain inet zapret2 z2k_tg_udp_fwd')
            printf '%s\n' 'chain z2k_tg_udp_fwd { type filter hook forward priority mangle; policy accept; }' 'oifname "z2ktg0" meta l4proto udp ip daddr @z2k_tg_udp_dc4 accept # handle 31' 'iifname "z2ktg0" meta l4proto udp ip saddr @z2k_tg_udp_dc4 accept # handle 32' ;;
        'list set inet zapret2 z2k_tg_udp_dc4') printf '%s\n' 'set z2k_tg_udp_dc4 { type ipv4_addr; comment "z2k-openwrt: Telegram UDP"; }' ;;
        'list set inet zapret2 z2k_tg_udp_dc6') printf '%s\n' 'set z2k_tg_udp_dc6 { type ipv6_addr; comment "z2k-openwrt: Telegram UDP"; }' ;;
        *) : ;;
    esac
}
sleep() { :; }
kill() { rm -f "$T/proc/$2/cmdline"; }

printf '%s\n' 'ENABLED=1' 'FLOWOFFLOAD=software' 'Z2K_TG_UDP_RELAY=1' \
    'Z2K_RELAY_SECRET=keep-me' 'GAME_WARP_ENABLED=1' 'Z2K_TG_UDP_RELAY=0' > "$T/config"
: > "$T/core-running"
printf '%s\0' '/usr/lib/z2k/bin/tg-mtproxy-client' '--listen=:1443' '--listen=:1444' '--timeout=15m' '--telegram-udp' > "$T/proc/4242/cmdline"
printf '%s\n' 'z2k-openwrt: created for Telegram UDP legacy ABI' > "$T/opt/bin/.z2k-tg-udp-legacy-shell-dir-owned"
cat > "$Z2K_OW_LEGACY_SHELL" <<'LEGACY_SHELL'
#!/bin/sh
# z2k-openwrt: Telegram UDP legacy shell ABI (p-85.8).
#
# The signed p-85.8 mtproxy-client binary calls /opt/bin/sh with this exact
# Keenetic command and ignores the newer OpenWrt route-helper environment
# variable. Intercept only that fixed ABI and delegate to the adapter's single
# route implementation; every unrelated invocation remains a normal /bin/sh.
if [ "${1:-}" = "-c" ] && \
   [ "${2:-}" = '. /opt/zapret2/z2k-tg-redirect.sh; "z2k_tg_udp_$1"' ] && \
   [ "${3:-}" = "sh" ]; then
    _z2k_tg_route_helper="${Z2K_TG_UDP_ROUTE_HELPER:-/usr/lib/z2k/platform/openwrt/tg-udp-route.sh}"
    case "${4:-}" in
        ensure|up) exec "$_z2k_tg_route_helper" ensure ;;
        down) exec "$_z2k_tg_route_helper" down ;;
        *) echo "z2k-openwrt: unsupported Telegram UDP route action" >&2; exit 64 ;;
    esac
fi
exec /bin/sh "$@"
LEGACY_SHELL
assert_eq "legacy fixture matches checksum in retirement helper" \
    '5a25e5e8333a640768fd6aaa466e523d4256d04365bcafc233efcd5885564a95' \
    "$(sha256sum "$Z2K_OW_LEGACY_SHELL" | awk '{print $1}')"
: > "$Z2K_OW_TG_READY"
IP4_RULES='0: from all lookup local
89: from all fwmark 0x8000000 lookup 988
32766: from all lookup main'
IP6_RULES="$IP4_RULES"
IP4_ROUTES='throw default
149.154.160.0/20 dev z2ktg0 scope link'
IP6_ROUTES='throw default dev lo metric 1024
2001:67c:4e8::/48 dev z2ktg0 metric 1024'
export IP4_RULES IP6_RULES IP4_ROUTES IP6_ROUTES

. "$REPO/platform/openwrt/tg-retire-udp.sh"
z2k_ow_tg_retire_udp || _t_bad "active legacy migration failed"
assert_not_contains "all duplicate UDP config keys are removed" "$T/config" 'Z2K_TG_UDP_RELAY='
assert_contains "FLOWOFFLOAD setting survives migration" "$T/config" 'FLOWOFFLOAD=software'
assert_contains "WARP setting survives migration" "$T/config" 'GAME_WARP_ENABLED=1'
assert_contains "relay secret survives migration" "$T/config" 'Z2K_RELAY_SECRET=keep-me'
assert_eq "active core is stopped and restarted once" 'stop
start' "$(cat "$T/service.log")"
assert_not_contains "restarted Telegram argv is TCP-only" "$T/proc/4343/cmdline" 'telegram-udp'
assert_contains "only exact NFQUEUE UDP return handles are deleted" "$T/nft.log" 'delete rule inet zapret2 prenat handle 11'
assert_contains "IPv6 legacy NFQUEUE handle is deleted" "$T/nft.log" 'delete rule inet zapret2 postnat handle 13'
assert_not_contains "unrelated NFQUEUE handle remains untouched" "$T/nft.log" 'delete rule inet zapret2 prenat handle 12'
assert_contains "owned fw4 include is regenerated" "$T/firewall.log" 'reload'
assert_contains "exact old PBR rules are removed" "$T/ip.log" '-4 rule del pref 89 fwmark'
assert_contains "legacy readiness marker is removed" "$T/nft.log" 'flush chain inet zapret2 z2k_tg_udp_mark'
assert_contains "owned forward chain is removed" "$T/nft.log" 'flush chain inet zapret2 z2k_tg_udp_fwd'
[ ! -e "$Z2K_OW_TG_READY" ] && _t_ok || _t_bad "legacy ready marker remains"
[ ! -e "$Z2K_OW_LEGACY_SHELL" ] && _t_ok || _t_bad "owned legacy /opt/bin/sh remains"

# An enabled config is not permission to resurrect a service the user stopped.
rm -f "$T/core-running" "$T/proc/4343/cmdline"
: > "$T/service.log"
printf '%s\n' 'ENABLED=1' 'FLOWOFFLOAD=software' 'Z2K_TG_UDP_RELAY=1' 'GAME_WARP_ENABLED=1' > "$T/config"
IP4_RULES='89: from all fwmark 0x1234 lookup 988'
IP6_RULES="$IP4_RULES"
IP4_ROUTES='203.0.113.0/24 dev wg0 scope link'
IP6_ROUTES="$IP4_ROUTES"
export IP4_RULES IP6_RULES IP4_ROUTES IP6_ROUTES
z2k_ow_tg_retire_udp || _t_bad "stopped-instance cleanup failed"
[ ! -s "$T/service.log" ] && _t_ok || _t_bad "intentionally stopped service was started"
case "$IP4_RULES" in *0x1234*) _t_ok ;; *) _t_bad "foreign pref-89 rule is preserved" ;; esac
assert_contains "user settings still survive second run" "$T/config" 'GAME_WARP_ENABLED=1'

_t_done
