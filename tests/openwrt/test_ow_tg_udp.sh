#!/bin/sh
# Telegram UDP-v1 OpenWrt boundary: exact argv, TUN/PBR lifecycle, scoped
# NFQUEUE exemptions, owner conflict and idempotent cleanup.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-udp"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgudp.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin" "$T/root/etc" "$T/etc" "$T/tmp/runtime" "$T/proc"
export PATH="$T/bin:$PATH"

# Exercise the production PID/cmdline ownership check without depending on
# host processes. TCP/CDN shares the listener, but UDP has its own flag.
cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
[ "$1" = tg-mtproxy-client ] && [ -f "$Z2K_TEST_PIDFILE" ] && cat "$Z2K_TEST_PIDFILE"
exit 1
EOF
chmod +x "$T/bin/pidof"
mkdir -p "$T/proc/4242"
printf '/usr/lib/z2k/bin/tg-mtproxy-client\0--listen=:1443\0--telegram-udp\0' > "$T/proc/4242/cmdline"
printf '4242\n' > "$T/pidof.state"
export Z2K_TEST_PIDFILE="$T/pidof.state"
export Z2K_PROC_ROOT="$T/proc"

# BusyBox on the live WBR3000UAX has no `install` applet. Keep this test
# environment honest: the legacy ABI materializer must use available cp/chmod
# primitives instead of depending on GNU coreutils.
cat > "$T/bin/install" <<'EOF'
#!/bin/sh
echo "simulated BusyBox: install applet unavailable" >&2
exit 127
EOF
chmod +x "$T/bin/install"

cat > "$T/root/bin/tg-mtproxy-client" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/tg-mtproxy-client"
printf 'ENABLED=1\nZ2K_TG_UDP_RELAY=1\n' > "$T/etc/config"
touch "$T/link-z2ktg0"

# nft mock keeps enough state to prove re-apply does not duplicate the four
# exemptions and that down removes only the owned rules.
: > "$T/nft.state"
: > "$T/nft.sets"
: > "$T/nft.log"
cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
_args="\$*"
if [ "\$1" = "-a" ]; then shift; fi
case "\$1 \$2" in
  "list table") exit 0 ;;
  "list set")
    _set="\$5"
    _record=\$(awk -F'|' -v name="\$_set" '\$1 == name { print \$2 "|" \$3; found=1; exit } END { if (!found) exit 1 }' "$T/nft.sets") || exit 1
    _type=\$(printf '%s\n' "\$_record" | cut -d'|' -f1)
    _elements=\$(printf '%s\n' "\$_record" | cut -d'|' -f2-)
    printf 'set %s { type %s; flags interval; auto-merge; comment "z2k-openwrt: Telegram UDP"; elements = { %s } }\n' "\$_set" "\$_type" "\$_elements"
    ;;
  "list chain")
    _c="\$5"
    case "\$_c" in
      postnat|prenat)
        echo "chain \$_c {"
        [ "\$_c" = postnat ] && echo 'meta nfproto ipv4 udp dport 443 queue flags bypass to 200'
        [ "\$_c" = prenat ] && echo 'meta nfproto ipv4 udp sport 443 queue flags bypass to 200'
        grep "^\$_c|" "$T/nft.state" | cut -d'|' -f2-
        ;;
      z2k_tg_udp_mark|z2k_tg_udp_fwd)
        grep -q "^\$_c|" "$T/nft.state" || exit 1
        echo "chain \$_c {"
        grep "^\$_c|" "$T/nft.state" | cut -d'|' -f2-
        ;;
      *) echo "chain \$_c {"; grep "^\$_c|" "$T/nft.state" | cut -d'|' -f2- ;;
    esac
    ;;
  "add set")
    _set="\$5"
    _type=\$(printf '%s\n' "\$6" | sed -n 's/.*type //; s/;.*//p')
    printf '%s|%s|\n' "\$_set" "\$_type" >> "$T/nft.sets"
    ;;
  "add element")
    _set="\$5"
    _item=\$(printf '%s' "\$6" | sed 's/[{}]//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    awk -F'|' -v name="\$_set" -v item="\$_item" 'BEGIN { OFS="|" } \$1 == name { \$3 = (\$3 == "" ? item : \$3 " " item) } { print }' "$T/nft.sets" > "$T/nft.sets.tmp"
    mv "$T/nft.sets.tmp" "$T/nft.sets"
    ;;
  "flush set")
    _set="\$5"
    awk -F'|' -v name="\$_set" 'BEGIN { OFS="|" } \$1 == name { \$3 = "" } { print }' "$T/nft.sets" > "$T/nft.sets.tmp"
    mv "$T/nft.sets.tmp" "$T/nft.sets"
    ;;
  "delete set")
    _set="\$5"
    awk -F'|' -v name="\$_set" '\$1 != name' "$T/nft.sets" > "$T/nft.sets.tmp"
    mv "$T/nft.sets.tmp" "$T/nft.sets"
    ;;
  "add chain"|"insert rule"|"add rule")
    _c="\$5"
    if [ "\$1 \$2" = "add chain" ]; then
      echo "\$_c|base" >> "$T/nft.state"
    else
      shift 5
      _rule="\$*"
      _h=\$(wc -l < "$T/nft.state" | tr -d ' ')
      _h=\$((_h + 100))
      printf '%s|%s # handle %s\n' "\$_c" "\$_rule" "\$_h" >> "$T/nft.state"
    fi
    ;;
  "flush chain") sed -i "s/^\$5|.*//" "$T/nft.state" ;;
  "delete chain") sed -i "s/^\$5|.*//" "$T/nft.state" ;;
  "delete rule")
    _h="\$7"
    sed -i "/# handle \$_h$/d" "$T/nft.state"
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/nft"

cat > "$T/bin/ip" <<EOF
#!/bin/sh
echo "ip \$*" >> "$T/ip.log"
if [ "\$1" = "link" ] && [ "\$2" = "show" ]; then
    [ -f "$T/link-\$3" ] && exit 0
    exit 1
fi
if [ "\$2" = "rule" ] && [ "\$3" = "show" ]; then
    cat "$T/rules-\$1" 2>/dev/null
    exit 0
fi
if [ "\$2" = "rule" ] && [ "\$3" = "add" ]; then
    printf '89: from all fwmark 0x08000000/0xffffffff lookup 988\\n' > "$T/rules-\$1"
    exit 0
fi
if [ "\$2" = "rule" ] && [ "\$3" = "del" ]; then
    rm -f "$T/rules-\$1"
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"
: > "$T/ip.log"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_CONFIG="$T/etc/config"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_TG_LAN_IFACES=br-lan
export Z2K_TG_UDP_READY="$T/tmp/runtime/tg-udp.ready"
. "$REPO/platform/openwrt/tg.sh" || { _t_bad "source tg.sh"; _t_done; exit 1; }

_argv() { printf 'argv:%s\n' "$*" >> "$T/argv.log"; }
: > "$T/argv.log"
z2k_ow_tg_with_argv _argv
assert_contains "enabled argv has UDP flag" "$T/argv.log" "--telegram-udp"
assert_not_contains "upstream binary receives no unsupported ready flag" "$T/argv.log" "--telegram-udp-ready="
assert_not_contains "upstream binary receives no unsupported route-helper flag" "$T/argv.log" "--telegram-udp-route-helper="
_default_marker=$( (
    unset Z2K_TG_UDP_READY Z2K_RUN Z2K_TMP
    . "$REPO/platform/openwrt/tg.sh" || exit 1
    printf '%s' "$Z2K_TG_UDP_READY"
))
assert_eq "watchdog default follows upstream readiness marker" "/tmp/z2k-log/tg-udp.ready" "$_default_marker"
assert_contains "Go client accepts OpenWrt route-helper override" "$REPO/mtproxy-client/udp.go" 'os.Getenv("Z2K_TG_UDP_ROUTE_HELPER")'
assert_contains "procd supplies OpenWrt route helper" "$REPO/platform/openwrt/tg.sh" 'Z2K_TG_UDP_ROUTE_HELPER=$Z2K_ROOT/platform/openwrt/tg-udp-route.sh'

# The router's installed p-85.8 client predates the source-level env override
# and falls back to the exact Keenetic /opt/bin/sh ABI. Exercise installation,
# exact dispatch, foreign-path preservation and removal in a temporary root.
_legacy_source="$REPO/platform/openwrt/tg-udp-legacy-shell"
_legacy_shell="$T/opt/bin/sh"
export Z2K_TG_UDP_LEGACY_SOURCE="$_legacy_source"
export Z2K_TG_UDP_LEGACY_SHELL="$_legacy_shell"
[ -x "$_legacy_source" ] && _t_ok || _t_bad "legacy Telegram UDP shell ABI source is executable"
z2k_ow_tg_legacy_abi_prepare || _t_bad "legacy ABI prepare"
[ -x "$_legacy_shell" ] && _t_ok || _t_bad "legacy ABI installed executable"
assert_eq "legacy ABI directory marker" \
    "z2k-openwrt: created for Telegram UDP legacy ABI" \
    "$(cat "$T/opt/bin/.z2k-tg-udp-legacy-shell-dir-owned" 2>/dev/null)"
z2k_ow_tg_legacy_abi_prepare || _t_bad "legacy ABI idempotent prepare"
assert_eq "legacy ABI stays byte-identical" \
    "$(sha256sum "$_legacy_source" | awk '{print $1}')" \
    "$(sha256sum "$_legacy_shell" | awk '{print $1}')"
cat > "$T/bin/legacy-route-helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TG_LEGACY_ROUTE_LOG"
EOF
chmod +x "$T/bin/legacy-route-helper"
export Z2K_TG_UDP_ROUTE_HELPER="$T/bin/legacy-route-helper"
export Z2K_TG_LEGACY_ROUTE_LOG="$T/legacy-route.log"
_legacy_cmd='. /opt/zapret2/z2k-tg-redirect.sh; "z2k_tg_udp_$1"'
# Current client invokes udpRoute("ensure"/"down"). On the live p-85.8
# binary ensure currently reached the legacy shell, whose wrapper rejected it
# with exit 64; exercise that exact observed ABI, not just an invented `up`.
"$_legacy_shell" -c "$_legacy_cmd" sh ensure || _t_bad "legacy ABI ensure dispatch"
"$_legacy_shell" -c "$_legacy_cmd" sh down || _t_bad "legacy ABI down dispatch"
assert_eq "legacy ensure maps to adapter ensure" "ensure" "$(sed -n '1p' "$T/legacy-route.log")"
assert_eq "legacy down maps to adapter down" "down" "$(sed -n '2p' "$T/legacy-route.log")"
"$_legacy_shell" -c "$_legacy_cmd" sh up || _t_bad "legacy ABI historical up dispatch"
assert_eq "legacy historical up maps to adapter ensure" "ensure" "$(sed -n '3p' "$T/legacy-route.log")"
_legacy_fallback=$("$_legacy_shell" -c 'printf "%s" "$1"' sh ordinary)
assert_eq "legacy shell keeps ordinary -c semantics" "ordinary" "$_legacy_fallback"
z2k_ow_tg_legacy_abi_remove || _t_bad "legacy ABI remove"
assert_eq "legacy ABI owned shell removed" "0" "$([ -e "$_legacy_shell" ] && echo 1 || echo 0)"
assert_eq "legacy ABI owned empty directory removed" "0" "$([ -d "$T/opt/bin" ] && echo 1 || echo 0)"

# Never overwrite or delete a foreign shell at the historical path.
mkdir -p "$T/foreign/opt/bin"
printf '#!/bin/sh\nprintf foreign\n' > "$T/foreign/opt/bin/sh"
chmod +x "$T/foreign/opt/bin/sh"
Z2K_TG_UDP_LEGACY_SHELL="$T/foreign/opt/bin/sh" z2k_ow_tg_legacy_abi_install \
    && _t_bad "legacy ABI overwrote a foreign shell" || _t_ok
assert_eq "foreign shell content preserved" "foreign" \
    "$("$T/foreign/opt/bin/sh")"
Z2K_TG_UDP_LEGACY_SHELL="$T/foreign/opt/bin/sh" z2k_ow_tg_legacy_abi_remove || _t_bad "foreign shell cleanup"
assert_eq "foreign shell survives cleanup" "1" "$([ -f "$T/foreign/opt/bin/sh" ] && echo 1 || echo 0)"

printf 'ENABLED=1\nZ2K_TG_UDP_RELAY=0\n' > "$T/etc/config"
: > "$T/argv.log"
z2k_ow_tg_with_argv _argv
assert_not_contains "disabled argv has no UDP flag" "$T/argv.log" --telegram-udp
printf 'ENABLED=1\nZ2K_TG_UDP_RELAY=1\n' > "$T/etc/config"

# TCP keeps the pre-existing narrower IPv6 set; UDP gets its own upstream
# /32 coverage so media traffic is not silently omitted or widened into TCP.
z2k_ow_tg_nft_apply || _t_bad "TCP nft apply before UDP test"
cp "$T/nft.log" "$T/tcp-nft.log"
assert_contains "TCP IPv6 range remains unchanged" "$T/tcp-nft.log" "2a0a:f280:203::/48"
assert_not_contains "TCP set does not inherit UDP /32" "$T/tcp-nft.log" "2a0a:f280::/32"
: > "$T/nft.log"

# No readiness marker means the route helper is a no-op: no speculative PBR.
rm -f "$Z2K_TG_UDP_READY"
z2k_ow_tg_udp_up
assert_eq "no marker leaves PBR absent" "0" "$(grep -c 'rule add' "$T/ip.log" 2>/dev/null || true)"

touch "$Z2K_TG_UDP_READY"
z2k_ow_tg_udp_up || _t_bad "UDP up"
assert_contains "v4 exact policy" "$T/ip.log" 'ip -4 rule add pref 89 fwmark 0x08000000/0xffffffff table 988'
assert_contains "v6 exact policy" "$T/ip.log" 'ip -6 rule add pref 89 fwmark 0x08000000/0xffffffff table 988'
assert_contains "throw default prevents catch-all" "$T/ip.log" 'route replace throw default table 988'
assert_contains "UDP route covers full upstream IPv6 prefix" "$T/ip.log" 'ip -6 route replace 2a0a:f280::/32 dev z2ktg0 table 988'
assert_not_contains "UDP routes do not use the old partial IPv6 prefix" "$T/ip.log" 'route replace 2a0a:f280:203::/48'
assert_not_contains "does not touch WARP table" "$T/ip.log" 'table 989'
assert_contains "TG UDP mark chain" "$T/nft.state" 'z2k_tg_udp_mark|'
assert_contains "TG UDP forward chain" "$T/nft.state" 'z2k_tg_udp_fwd|'
assert_contains "UDP IPv4 nft set populated" "$T/nft.log" 'add element inet zapret2 z2k_tg_udp_dc4'
assert_contains "UDP IPv6 nft set includes full /32" "$T/nft.log" '2a0a:f280::/32'
assert_contains "outgoing NFQUEUE exemption uses UDP set" "$T/nft.state" 'postnat|ip daddr @z2k_tg_udp_dc4 meta l4proto udp return'
assert_contains "incoming NFQUEUE exemption uses UDP set" "$T/nft.state" 'prenat|ip saddr @z2k_tg_udp_dc4 meta l4proto udp return'
assert_contains "IPv6 NFQUEUE exemption uses UDP set" "$T/nft.state" 'postnat|ip6 daddr @z2k_tg_udp_dc6 meta l4proto udp return'
assert_not_contains "UDP marking does not reuse TCP IPv6 set" "$T/nft.log" 'z2k_tg_udp_mark.*@z2k_tg_dc6'
assert_not_contains "exemption is not blanket UDP" "$T/nft.state" '^(postnat|prenat)\\|meta l4proto udp return$'
assert_eq "ready requires route+nft" "ready" "$(z2k_ow_tg_udp_state)"

# A stale ready marker and route/nft state after a worker crash are not ready
# when either the TUN interface or the UDP worker is gone.
: > "$T/pidof.state"
assert_eq "stale marker without client PID is degraded" "degraded" "$(z2k_ow_tg_udp_state)"
printf '4242\n' > "$T/pidof.state"
rm -f "$T/link-z2ktg0"
assert_eq "stale marker without TUN is degraded" "degraded" "$(z2k_ow_tg_udp_state)"
touch "$T/link-z2ktg0"
printf '/usr/lib/z2k/bin/tg-mtproxy-client\0--listen=:1443\0' > "$T/proc/4242/cmdline"
assert_eq "stale marker without UDP worker is degraded" "degraded" "$(z2k_ow_tg_udp_state)"
printf '/usr/lib/z2k/bin/tg-mtproxy-client\0--listen=:1443\0--telegram-udp\0' > "$T/proc/4242/cmdline"
assert_eq "live UDP worker and TUN restore ready" "ready" "$(z2k_ow_tg_udp_state)"

# Re-applying must not duplicate the four existing exemptions.
: > "$T/nft.log"
z2k_ow_tg_udp_up || _t_bad "UDP re-apply"
assert_eq "exemptions are not duplicated" "1" "$(grep -c '^postnat|ip daddr @z2k_tg_udp_dc4 meta l4proto udp return' "$T/nft.state")"
assert_not_contains "idempotent re-apply does not flush owned address sets" "$T/nft.log" 'nft:flush set'
assert_not_contains "idempotent re-apply does not repopulate unchanged sets" "$T/nft.log" 'nft:add element'

# A foreign owner at the reserved priority is rejected before routes are added.
printf '89: from all fwmark 0x01000000/0xffffffff lookup 999\n' > "$T/rules--4"
rm -f "$T/rules--6"
rm -f "$T/ip.log"
z2k_ow_tg_udp_up && _t_bad "foreign PBR owner accepted" || _t_ok
assert_not_contains "foreign owner leaves no new v4 route" "$T/ip.log" 'ip -4 route replace'
rm -f "$T/rules--4" "$T/rules--6"

z2k_ow_tg_udp_down
assert_eq "down removes readiness" "starting" "$(z2k_ow_tg_udp_state)"
assert_not_contains "down removes owned exemptions" "$T/nft.state" 'postnat\\|ip daddr @z2k_tg_udp_dc4 meta l4proto udp return'
assert_contains "down removes owned IPv4 set" "$T/nft.log" 'delete set inet zapret2 z2k_tg_udp_dc4'
assert_contains "down removes owned IPv6 set" "$T/nft.log" 'delete set inet zapret2 z2k_tg_udp_dc6'
assert_not_contains "down removes owned route" "$T/ip.log" 'rule del pref 89 fwmark 0x08000000/0xffffffff table 988'

printf 'ENABLED=1\nZ2K_TG_UDP_RELAY=0\n' > "$T/etc/config"
assert_eq "disabled state is explicit" "disabled" "$(z2k_ow_tg_udp_state)"
sh -n "$REPO/platform/openwrt/tg-udp-route.sh" || _t_bad "route helper syntax"
assert_not_contains "adapter has no iptables" "$REPO/platform/openwrt/tg.sh" 'iptables|ip6tables'

_t_done
