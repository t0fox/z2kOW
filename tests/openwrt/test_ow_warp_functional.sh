#!/bin/sh
# tests/openwrt/test_ow_warp_functional.sh - Stage 5 Layer B/C-functional.
# Mock'и: nft, ip (stateful), pidof, /proc, procd. Реальный warp.sh in-process.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-functional"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpf.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
export T

mkdir -p "$T/bin" "$T/root/bin" "$T/root/platform/openwrt/bin/linux-arm64" "$T/etc" "$T/etc/state/warp" "$T/etc/user-lists/warp/games" "$T/root/lists/warp/games" "$T/tmp/warp" "$T/proc"
export PATH="$T/bin:$PATH"
ln -s "$REPO/platform/openwrt/warp-domain.sh" "$T/root/platform/openwrt/warp-domain.sh"
cp "$REPO/platform/openwrt/arch.sh" "$T/root/platform/openwrt/arch.sh"
cp "$REPO/files/z2k-warp-list-filter.awk" "$T/root/z2k-warp-list-filter.awk"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
# Atomic batch (defect 2): логируем stdin построчно (content-ассерты),
# fault injection как в lifecycle; state не нужен этому сьюту.
if [ "\$1" = "-f" ]; then
    _bin="$T/nft-batch-in"
    cat > "\$_bin" 2>/dev/null
    sed 's/^/nft-batch:/' "\$_bin" >> "$T/nft.log" 2>/dev/null
    if [ -n "\${NFT_BATCH_FAIL:-}" ] && grep -qF "\$NFT_BATCH_FAIL" "\$_bin" 2>/dev/null; then
        exit 1
    fi
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "table" ]; then
    if [ "\$4" = "z2k_warp_dns" ]; then
        [ -f "$T/nft-domain-table" ] || exit 1
        cat "$T/nft-domain-table"
        exit 0
    fi
    [ -f "$T/no-table" ] && exit 1
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "set" ] && [ "\$5" = "z2k_warp_domain4" ]; then
    [ -f "$T/nft-domain-set" ] || exit 1
    cat "$T/nft-domain-set"
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "set" ] && [ "\$4" = "zapret2" ] && [ "\$5" = "z2k_warp_dst4" ]; then
    if [ -f "$T/nft-empty-dst-set" ]; then
        printf 'set z2k_warp_dst4 { type ipv4_addr; flags interval; }\n'
    else
        printf 'set z2k_warp_dst4 { type ipv4_addr; flags interval; elements = { 1.2.3.4 } }\n'
    fi
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "chain" ] && [ "\$4" = "z2k_warp_dns" ]; then
    case "\$5" in
        z2k_dns_output|z2k_dns_forward)
            [ -f "$T/nft-domain-chain-\$5" ] || exit 1
            cat "$T/nft-domain-chain-\$5"
            exit 0 ;;
    esac
fi
if [ "\$1" = "add" ] && [ "\$2" = "table" ] && [ "\$4" = "z2k_warp_dns" ]; then
    printf 'table inet z2k_warp_dns { comment "z2k WARP passive DNS observer"; }\n' > "$T/nft-domain-table"
    exit 0
fi
if [ "\$1" = "add" ] && [ "\$2" = "chain" ] && [ "\$4" = "z2k_warp_dns" ]; then
    printf 'chain %s { comment "z2k WARP passive DNS observer chain %s"; }\n' "\$5" "\$5" > "$T/nft-domain-chain-\$5"
    exit 0
fi
if [ "\$1" = "add" ] && [ "\$2" = "set" ] && [ "\$5" = "z2k_warp_domain4" ]; then
    printf 'set z2k_warp_domain4 { type ipv4_addr . ipv4_addr; comment "z2k WARP DNS pairs"; }\n' > "$T/nft-domain-set"
    exit 0
fi
if [ "\$1" = "delete" ] && [ "\$2" = "table" ] && [ "\$4" = "z2k_warp_dns" ]; then
    rm -f "$T/nft-domain-table" "$T/nft-domain-chain-z2k_dns_output" "$T/nft-domain-chain-z2k_dns_forward"
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "chain" ] && \
   [ "\$4" = fw4 ] && [ "\$5" = forward ]; then
    [ -f "$T/fw4-forward" ] && cat "$T/fw4-forward"
    exit 0
fi
if [ "\$1" = "-a" ] && [ "\$2" = "list" ] && [ "\$3" = "chain" ] && \
   [ "\$5" = fw4 ] && [ "\$6" = forward ]; then
    [ -f "$T/fw4-forward" ] && cat "$T/fw4-forward"
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "chain" ] && [ "\$3" = inet ] && [ "\$4" = zapret2 ]; then
    [ -f "$T/nft-chain-\$5" ] || exit 1
    cat "$T/nft-chain-\$5"
    exit 0
fi
if [ "\$1" = "insert" ] && [ "\$2" = "rule" ] && \
   [ "\$4" = fw4 ] && [ "\$5" = forward ]; then
    _prev=""; _iface=""
    for _arg in "\$@"; do
        [ "\$_prev" = oifname ] && _iface="\$_arg"
        _prev="\$_arg"
    done
    printf 'meta mark & 0x80000000 == 0x80000000 oifname "%s" accept comment "!z2k: WARP forwarded traffic" # handle 91\n' "\$_iface" > "$T/fw4-forward"
    exit 0
fi
if [ "\$1" = "delete" ] && [ "\$2" = "rule" ] && \
   [ "\$4" = fw4 ] && [ "\$5" = forward ]; then
    rm -f "$T/fw4-forward"
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
# stateful ip mock: rules/routes/link/neigh из файлов состояния
cat > "$T/bin/ip" <<EOF
#!/bin/sh
echo "ip:\$*" >> "$T/ip.log"
if [ "\$1" = "rule" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-rules" 2>/dev/null; exit 0
fi
if [ "\$1" = "rule" ] && [ "\$2" = "add" ]; then
    _pref=""; _fm=""; _tb=""; _from=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in
            pref) _pref="\$_a" ;;
            fwmark) _fm="\$_a" ;;
            from) _from="\$_a" ;;
            table|lookup) _tb="\$_a" ;;
        esac
        _prev="\$_a"
    done
    if [ -n "\$_from" ]; then
        printf '%s: from %s lookup %s\n' "\$_pref" "\$_from" "\$_tb" >> "$T/ip-rules"
    else
        printf '%s: from all fwmark %s lookup %s\n' "\$_pref" "\$_fm" "\$_tb" >> "$T/ip-rules"
    fi
    exit 0
fi
if [ "\$1" = "rule" ] && [ "\$2" = "del" ]; then
    # Exact-match delete (defect 4): снимается только строка, совпадающая
    # со ВСЕМИ переданными селекторами (pref + fwmark + table).
    _pref=""; _fm=""; _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in
            pref) _pref="\$_a" ;;
            fwmark) _fm="\$_a" ;;
            table|lookup) _tb="\$_a" ;;
        esac
        _prev="\$_a"
    done
    if [ -f "$T/ip-rules" ]; then
        awk -v p="\$_pref" -v m="\$_fm" -v t="\$_tb" '
            { del=1
              if (p != "" && (\$0 !~ "^" p ":")) del=0
              if (m != "" && index(\$0, "fwmark " m) == 0) del=0
              if (t != "" && index(\$0, "lookup " t) == 0) del=0
              if (!del) print }' "$T/ip-rules" > "$T/ip-rules.new" 2>/dev/null || : > "$T/ip-rules.new"
        mv -f "$T/ip-rules.new" "$T/ip-rules"
    fi
    exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-route-\$4" 2>/dev/null; exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "replace" ]; then
    _tb=""; _prev=""; _dev=""
    for _a in "\$@"; do
        case "\$_prev" in
            table) _tb="\$_a" ;;
            dev) _dev="\$_a" ;;
        esac
        _prev="\$_a"
    done
    printf 'default dev %s\n' "\$_dev" > "$T/ip-route-\$_tb"
    exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "del" ]; then
    _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in table) _tb="\$_a" ;; esac
        _prev="\$_a"
    done
    rm -f "$T/ip-route-\$_tb"
    exit 0
fi
if [ "\$1" = "link" ] && [ "\$2" = "show" ]; then
    [ -f "$T/link-\$4" ] && { echo "\$4: <UP> mtu 1280"; exit 0; }
    exit 1
fi
if [ "\$1" = "-4" ] && [ "\$2" = "neigh" ]; then
    cat "$T/neigh" 2>/dev/null; exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"

# OpenWrt's active Wi-Fi association and dnsmasq lease state stand in for the
# conservative MAC fallback used when the IPv4 neighbour cache has a gap.
cat > "$T/bin/ubus" <<EOF
#!/bin/sh
case "\$1" in
    list) printf 'hostapd.wlan0\nhostapd.wlan1\n'; exit 0 ;;
    call)
        [ "\$3" = get_clients ] || exit 1
        cat "$T/hostapd-clients.json"
        exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/ubus"
cat > "$T/bin/uci" <<EOF
#!/bin/sh
if [ ! -f "$T/uci-wireguard-enabled" ]; then exit 1; fi
if [ "\$1" = show ] && [ "\$2" = network ]; then
    cat <<'EOF_UCI'
network.wgserver=interface
network.wgserver.proto='wireguard'
network.wgserver.listen_port='51820'
network.wgclient=interface
network.wgclient.proto='wireguard'
EOF_UCI
    exit 0
fi
if [ "\$1" = -q ] && [ "\$2" = get ]; then
    case "\$3" in
        network.wgserver.listen_port) echo 51820; exit 0 ;;
        network.wgserver.device) echo wgserver; exit 0 ;;
        network.wgclient.listen_port) exit 1 ;;
        network.wgclient.device) echo wgclient; exit 0 ;;
    esac
fi
exit 1
EOF
chmod +x "$T/bin/uci"
cat > "$T/bin/jsonfilter" <<EOF
#!/bin/sh
expr=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -s|-i) shift 2 ;;
        -e) expr="\$2"; shift 2 ;;
        -q|-a|-t) shift ;;
        *) shift ;;
    esac
done
mac=\$(printf '%s' "\$expr" | sed -n "s/.*clients.*\\['\\([0-9a-f:]*\\)'\\].*/\\1/p")
field=\${expr##*.}
[ -n "\$mac" ] || exit 1
awk -v want="\$mac" -v field="\$field" '
    \$1 == want { if (field == "assoc") print \$2; else if (field == "authorized") print \$3; found=1; exit }
    END { if (!found) print "false" }
' "$T/hostapd-active.tsv"
EOF
chmod +x "$T/bin/jsonfilter"
: > "$T/hostapd-active.tsv"
: > "$T/hostapd-clients.json"
: > "$T/dhcp.leases"

cat > "$T/root/platform/openwrt/bin/linux-arm64/z2k-warpd" <<EOF
#!/bin/sh
# mock binary: пишет argv, register/status/version отвечают canned
echo "warpd:\$*" >> "$T/warpd.log"
case "\$1" in
    register) echo "device ok mock-id"; exit \${WARP_MOCK_REGISTER_RC:-0} ;;
    version) echo "z2k-warpd mock"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/root/platform/openwrt/bin/linux-arm64/z2k-warpd"

printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '{"id":"mock-id","addr":"172.16.9.9","addr_v4":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg"}\n' > "$T/tmp/warp/status.json"
touch "$T/link-z2ktun0"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_ADAPTER_DIR="$T/root/platform/openwrt" Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
export WARP_DOMAIN_RULES="$T/tmp/warp/domains.v1"
export WARP_DOMAIN_SNAPSHOT="$T/tmp/warp/domain-pairs.v1"
export WARP_DOMAIN_STATUS="$T/tmp/warp/domain-status.json"
export WARP_DOMAIN_ERROR="$T/tmp/warp/domain-setup-error"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_STATE="$T/etc/state"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export WARP_DHCP_LEASES="$T/dhcp.leases"
export Z2K_PROC_ROOT="$T/proc"
export Z2K_WARP_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/warp.sh" || { echo "FAIL[ow-warp-functional]: source" >&2; exit 1; }
assert_eq "WARP default binary matches staged architecture-specific payload" \
    "$T/root/platform/openwrt/bin/linux-arm64/z2k-warpd" "$WARP_BIN"
_z2k_ow_warp_kill() { echo "kill:$*" >> "$T/kill.log"; return 0; }
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }

# --- argv exact (без -v, с backend/lists-путями) ---
_rec() { printf 'ARGV:%s\n' "$*" >> "$T/argv.log"; }
: > "$T/argv.log"
_out="$(warp_with_argv _rec 2>"$T/argv.err")"
assert_contains "binary run" "$T/argv.log" "$T/root/platform/openwrt/bin/linux-arm64/z2k-warpd run"
assert_contains "device persistent" "$T/argv.log" "--device $T/etc/state/warp/device.json"
assert_contains "status transient" "$T/argv.log" "--status $T/tmp/warp/status.json"
assert_contains "scan pools use the shipped OpenWrt list" "$T/argv.log" "--scan-pools $T/root/lists/warp-scan-pools.txt"
assert_contains "backend external" "$T/argv.log" "--net-backend=external"
if grep -q -- '-v' "$T/argv.log"; then _t_bad "argv: лишний -v"; else _t_ok; fi
assert_eq "builder молчит" "" "$_out$(cat "$T/argv.err")"

# --- local health probe route: it must exist before daemon ready ---
: > "$T/ip-rules"
rm -f "$T/ip-route-989" "$T/tmp/warp/probe-route.owner"
printf '{"ready":false,"iface":"z2ktun0","addr":"172.16.9.9"}\n' > "$T/tmp/warp/status.json"
warp_probe_route_up || _t_bad "probe route up"
assert_contains "probe source rule" "$T/ip-rules" "499: from 172.16.9.9/32 lookup 989"
assert_contains "probe route" "$T/ip-route-989" "default dev z2ktun0"
warp_pbr_down || _t_bad "probe route down"
if grep -q '^499:' "$T/ip-rules" 2>/dev/null; then _t_bad "probe source rule cleanup"; else _t_ok; fi
if [ -e "$T/ip-route-989" ]; then _t_bad "probe route cleanup"; else _t_ok; fi
printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg"}\n' > "$T/tmp/warp/status.json"

# --- wanted-матрица ---
warp_wanted_boot && _t_ok || _t_bad "wanted при всём хорошем"
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
warp_wanted_boot && _t_bad "wanted при flag=0" || _t_ok
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
chmod -x "$WARP_BIN"
warp_wanted_boot && _t_bad "wanted без бинарника" || _t_ok
chmod +x "$WARP_BIN"
mv "$T/etc/state/warp/device.json" "$T/etc/state/warp/device.json.keep"
warp_wanted_boot && _t_bad "wanted без ключа" || _t_ok
mv "$T/etc/state/warp/device.json.keep" "$T/etc/state/warp/device.json"

# --- списки: user + enabled-games, валидация, migrate ---
export WARP_LISTS_DIR="$T/etc/user-lists/warp" WARP_GAMES_DIR="$T/root/lists/warp/games"
export WARP_ENABLED_FILE="$WARP_LISTS_DIR/.enabled" WARP_DEVICES_FILE="$WARP_LISTS_DIR/devices.txt"
# p-86.13: explicit device selection with no list uses full-device mode, but a
# selected yet missing game list must not silently expand to all destinations.
printf '1.1.1.1\n' > "$WARP_DEVICES_FILE"
if warp_full_device_mode; then _t_ok; else _t_bad "full-device mode requires selected devices and no active list"; fi
: > "$T/nft.log"
warp_nft_rules_apply || _t_bad "full-device rules rc"
assert_contains "full-device mode marks selected sources" "$T/nft.log" 'ip saddr @z2k_warp_src4 ip daddr != 0.0.0.0/8'
assert_contains "full-device mode keeps private LAN direct" "$T/nft.log" 'ip daddr != 192.168.0.0/16'
if grep -q 'ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4' "$T/nft.log"; then
    _t_bad "full-device mode was incorrectly restricted to an empty destination set"
else
    _t_ok
fi
printf 'selected-list-that-is-missing\n' > "$WARP_ENABLED_FILE"
if warp_full_device_mode; then _t_bad "missing enabled list silently expanded to full-device mode"; else _t_ok; fi

printf '1.2.3.4\n10.9.9.9\n0.0.0.0/0\n018.1.1.1\n3.0.0.0/8\n# comment\n\n' > "$T/etc/user-lists/warp/mine.txt"
printf '1.1.1.1\n' > "$T/etc/user-lists/warp/devices.txt"
printf 'steam\n' > "$T/etc/user-lists/warp/.enabled"
printf '5.5.5.5\n999.1.1.1\n' > "$T/root/lists/warp/games/steam.txt"
printf '6.6.6.6\n' > "$T/root/lists/warp/games/dropped.txt"
warp_active_lists > "$T/active.log"
assert_contains "active: user list" "$T/active.log" "mine.txt"
assert_contains "active: enabled game" "$T/active.log" "steam.txt"
if grep -q 'dropped.txt' "$T/active.log"; then _t_bad "невыбранная игра загружена"; else _t_ok; fi
if grep -q 'devices.txt' "$T/active.log"; then _t_bad "devices.txt в dst"; else _t_ok; fi
_valid="$(warp_validated_dst)"
printf '%s' "$_valid" > "$T/valid.log"
assert_contains "valid: хост" "$T/valid.log" "1.2.3.4"
assert_contains "valid: /8 разрешён" "$T/valid.log" "3.0.0.0/8"
for _bad in '10.9.9.9' '0.0.0.0/0' '018.1.1.1'; do
    if grep -qxF "$_bad" "$T/valid.log"; then _t_bad "valid пропустил $_bad"; else _t_ok; fi
done
# Domain support is optional for older/incomplete payloads: a missing parser
# must not make the established static IP/CIDR WARP path disappear.
_saved_filter="$WARP_DOMAIN_FILTER"
WARP_DOMAIN_FILTER="$T/missing-domain-filter.awk"
warp_validated_dst > "$T/valid-without-domain-filter.log"
assert_contains "missing domain parser keeps static destination" "$T/valid-without-domain-filter.log" "1.2.3.4"
WARP_DOMAIN_FILTER="$_saved_filter"
# CIDR feeds may contain a broad block together with a narrower child.  nft's
# interval sets reject that pair; the adapter must merge it before the atomic
# batch rather than return a false-success with an empty live set.
printf '155.133.224.0/22\n155.133.224.0/19\n' > "$T/root/lists/warp/games/overlap.txt"
printf 'steam\noverlap\n' > "$T/etc/user-lists/warp/.enabled"
warp_validated_dst > "$T/overlap.log"
assert_contains "overlap: broad block kept" "$T/overlap.log" "155.133.224.0/19"
if grep -qxF '155.133.224.0/22' "$T/overlap.log"; then
    _t_bad "overlap: narrower child leaked into nft set"
else
    _t_ok
fi
# p-85.13 devices: direct IPv4, neighbour priority, and active OpenWrt client DB.
printf '%s\n' \
    'AA-BB-CC-DD-EE-FF' \
    '192.168.1.50' \
    '8.8.8.8' \
    '22-33-44-55-66-77' \
    '33:44:55:66:77:88' \
    '44:55:66:77:88:99' \
    '55:66:77:88:99:AA' \
    '66:77:88:99:AA:BB' \
    '77:88:99:AA:BB:CC' \
    > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.1.77 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' > "$T/neigh"
_lease_expiry=$(($(date +%s) + 3600))
cat > "$T/dhcp.leases" <<EOF
$_lease_expiry aa:bb:cc:dd:ee:ff 192.168.1.200 neighbour-conflict *
$_lease_expiry 22:33:44:55:66:77 192.168.1.107 laptop *
$_lease_expiry 33:44:55:66:77:88 192.168.1.108 offline *
1 44:55:66:77:88:99 192.168.1.109 expired *
0 55:66:77:88:99:aa 8.8.8.9 public *
0 66:77:88:99:aa:bb 2001:db8::1 ipv6 *
$_lease_expiry 77:88:99:aa:bb:cc 192.168.1.110 unknown *
EOF
cat > "$T/hostapd-active.tsv" <<'EOF'
aa:bb:cc:dd:ee:ff true true
22:33:44:55:66:77 true true
33:44:55:66:77:88 false false
44:55:66:77:88:99 true true
55:66:77:88:99:aa true true
66:77:88:99:aa:bb true true
EOF
cat > "$T/hostapd-clients.json" <<'EOF'
{"clients":{"aa:bb:cc:dd:ee:ff":{"assoc":true,"authorized":true},"22:33:44:55:66:77":{"assoc":true,"authorized":true}}}
EOF
_devs="$(warp_devices_ips)"
printf '%s' "$_devs" > "$T/devs.log"
assert_contains "devices: direct IPv4" "$T/devs.log" "192.168.1.50"
assert_contains "devices: neighbour MAC wins over client DB" "$T/devs.log" "192.168.1.77"
if grep -q '192.168.1.200' "$T/devs.log"; then _t_bad "stale client DB replaced neighbour"; else _t_ok; fi
assert_contains "devices: active OpenWrt client fallback" "$T/devs.log" "192.168.1.107"
if grep -q '192.168.1.108\|192.168.1.109\|192.168.1.110' "$T/devs.log"; then
    _t_bad "offline, expired, or unknown client lease was routed"
else
    _t_ok
fi
if grep -q '8\.8\.8\.8\|8\.8\.8\.9\|2001:db8' "$T/devs.log"; then
    _t_bad "public or IPv6 source reached the IPv4 set"
else
    _t_ok
fi
printf '11:22:33:44:55:66\n' > "$T/etc/user-lists/warp/devices.txt"
warp_devices_ips > "$T/offline.log"; _offline_rc=$?
assert_eq "devices: offline MAC is nonfatal" "0" "$_offline_rc"
assert_eq "devices: offline MAC is skipped" "" "$(cat "$T/offline.log")"
printf '1.1.1.1\n' > "$T/etc/user-lists/warp/devices.txt"

# --- nft shapes: mark/mss/fwd/nat, приоритеты, exact mark-op ---
: > "$T/nft.log"
warp_nft_rules_apply || _t_bad "mark rules rc"
warp_nft_tun_apply "z2ktun0" || _t_bad "tun rules rc"
assert_contains "mark dst" "$T/nft.log" 'ip daddr @z2k_warp_dst4 meta mark set mark'
assert_contains "mark src and destination" "$T/nft.log" 'ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4 meta mark set mark'
assert_contains "masked op" "$T/nft.log" "mark & 0x7fffffff ^ 0x80000000"
assert_contains "mss out" "$T/nft.log" 'oifname z2ktun0 tcp flags syn tcp option maxseg size set rt mtu'
assert_contains "mss in explicit" "$T/nft.log" 'iifname z2ktun0 tcp flags syn tcp option maxseg size set 1240'
assert_contains "fwd narrow" "$T/nft.log" 'oifname z2ktun0 accept'
assert_contains "masq narrow" "$T/nft.log" 'oifname z2ktun0 masquerade'
assert_contains "pre chain prio" "$T/nft.log" 'z2k_warp_mark { type filter hook prerouting priority -150; }'
# нет OUTPUT-mark и нет flowtable:
if grep -E 'hook output' "$T/nft.log" | grep -q 'mark set'; then
    _t_bad "OUTPUT mark!"
else
    _t_ok
fi
if grep -Ei 'flowtable|flow add|offload|PPE' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "offload-конструкции"
else
    _t_ok
fi
# No selected domains means no observer table, pair set, or NFLOG hook. A
# passive observer is opt-in to the domain list, not a permanent firewall hook.
if grep -qE 'nft:add table inet z2k_warp_dns|nft:add set inet zapret2 z2k_warp_domain4|nft-batch:.*log group 189' "$T/nft.log"; then
    _t_bad "observer created without selected domains"
else
    _t_ok
fi
# sets load: валидные едут, битые — нет, live цел:
printf '1.2.3.4\n10.0.0.5\n' > "$T/etc/user-lists/warp/mine.txt"
: > "$T/nft.log"
warp_nft_sets_load || _t_bad "sets load rc"
assert_contains "dst element 1.2.3.4" "$T/nft.log" 'add element inet zapret2 z2k_warp_dst4 { 1.2.3.4'
assert_contains "dst element из game" "$T/nft.log" '5.5.5.5'
if grep -q '10.0.0.5' "$T/nft.log"; then _t_bad "приват уехал в set"; else _t_ok; fi
if grep -q '999.1.1.1' "$T/nft.log"; then _t_bad "битый IP уехал в set"; else _t_ok; fi

# A WebUI domain-list save calls the `ipset` live-reload verb.  That verb must
# also converge the existing WARP mark/observer rules, otherwise DNS answers
# never reach z2k-warpd and the newly selected domain silently stays direct.
# IP-only lists retain the previous path and do not flush/rebuild WARP chains.
: > "$T/nft.log"
warp_ipset || _t_bad "IP-only live list reload rc"
if grep -q 'nft:add chain inet zapret2 z2k_warp_mark' "$T/nft.log"; then
    _t_bad "IP-only live list reload rebuilt WARP rules"
else
    _t_ok
fi

# A selected-device change must rebuild the canonical MARK shape even when
# there are no domain observers. Exercise the real adapter implementation.
# These shape-only cases use the log-only nft fake below the readiness proof;
# keep the daemon not-ready so --reconcile-rules correctly skips live proofs.
printf '{"ready":false,"iface":"z2ktun0","addr":"172.16.9.9"}\n' > "$T/tmp/warp/status.json"
: > "$WARP_LISTS_DIR/.disabled"
printf 'steam\n' > "$WARP_ENABLED_FILE"
printf '192.168.1.50\n' > "$WARP_DEVICES_FILE"
: > "$T/nft.log"
warp_ipset --reconcile-rules || _t_bad "device live reconcile rc"
assert_contains "device live reconcile: selected source + destination list" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4 meta mark set mark'

# list mode -> full-device mode -> list mode -> no selected devices must each
# leave rules matching the current selection, not the previous rule shape.
: > "$WARP_LISTS_DIR/.disabled"
for _list_file in "$WARP_LISTS_DIR"/*.txt; do
    [ "$_list_file" = "$WARP_DEVICES_FILE" ] && continue
    [ -f "$_list_file" ] || continue
    basename "$_list_file" .txt >> "$WARP_LISTS_DIR/.disabled"
done
: > "$WARP_ENABLED_FILE"
: > "$T/nft.log"
warp_ipset --reconcile-rules || _t_bad "full-device live reconcile rc"
assert_contains "device live reconcile: full-device mode" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark ip saddr @z2k_warp_src4 ip daddr != 0.0.0.0/8'

: > "$WARP_LISTS_DIR/.disabled"
printf 'steam\n' > "$WARP_ENABLED_FILE"
: > "$WARP_DEVICES_FILE"
: > "$T/nft.log"
warp_ipset --reconcile-rules || _t_bad "list mode live reconcile rc"
assert_contains "device live reconcile: removing selected device restores destination-only mode" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark ip daddr @z2k_warp_dst4 meta mark set mark'
if grep 'nft:add rule .*z2k_warp_mark' "$T/nft.log" | grep -q 'ip saddr @z2k_warp_src4'; then
    _t_bad "device live reconcile retained source selector after device removal"
else
    _t_ok
fi

# Restore the fixture used by the following domain-list live-reload checks.
: > "$WARP_LISTS_DIR/.disabled"
printf 'steam\n' > "$WARP_ENABLED_FILE"
printf '1.1.1.1\n' > "$WARP_DEVICES_FILE"

printf 'www.cloudflare.com\n' > "$T/etc/user-lists/warp/mine.txt"
export Z2K_WARP_DOMAIN_LAN_DEVICES=br-lan
: > "$T/uci-wireguard-enabled"
: > "$T/nft.log"
warp_ipset || _t_bad "live list reload rc"
assert_eq "WireGuard discovery distinguishes client and server interfaces" "wgclient" "$(warp_wireguard_client_devices)"
assert_contains "live domain reload: client-pair mark rule" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark ip saddr @z2k_warp_src4 ip saddr . ip daddr @z2k_warp_domain4'
if grep 'nft:add rule .*z2k_warp_mark iifname wgserver.*meta mark set' "$T/nft.log" >/dev/null; then
    _t_bad "WDTT-disabled WireGuard server clients were marked"
else
    _t_ok
fi
assert_contains "client WireGuard ingress: private source to listed IP is eligible" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark iifname wgclient ip saddr 10.0.0.0/8 ip daddr @z2k_warp_dst4 meta mark set mark'
assert_contains "client WireGuard ingress: private source to observed domain is eligible" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark iifname wgclient ip saddr 10.0.0.0/8 ip saddr . ip daddr @z2k_warp_domain4 meta mark set mark'
assert_contains "live domain reload: observer table" "$T/nft.log" \
    'nft:add table inet z2k_warp_dns'
assert_contains "live domain reload: passive DNS NFLOG hook" "$T/nft.log" \
    'nft-batch:add rule inet z2k_warp_dns z2k_dns_output oifname "br-lan" ip protocol { tcp, udp } th sport 53 counter log group 189'
assert_contains "live domain reload: WireGuard DNS replies are observed" "$T/nft.log" \
    'nft-batch:add rule inet z2k_warp_dns z2k_dns_forward oifname "wgserver" ip protocol { tcp, udp } th sport 53 counter log group 189'
assert_contains "live domain reload: WireGuard client DNS replies are observed" "$T/nft.log" \
    'nft-batch:add rule inet z2k_warp_dns z2k_dns_forward oifname "wgclient" ip protocol { tcp, udp } th sport 53 counter log group 189'
assert_contains "live domain reload: domain rules published" "$T/tmp/warp/domains.v1" \
    'www.cloudflare.com'

# Upstream WDTT behavior: server-side WireGuard clients are direct by default.
# With WDTT enabled and active WARP lists, their entire ingress is marked for
# WARP; with no active lists (full-device mode) it returns to direct routing.
if grep 'nft:add rule .*z2k_warp_mark iifname wgserver meta mark set' "$T/nft.log" >/dev/null; then
    _t_bad "WDTT defaults off and leaves WireGuard server clients direct"
else
    _t_ok
fi
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=1\n' > "$T/etc/config"
: > "$T/nft.log"
warp_ipset --reconcile-rules || _t_bad "WDTT enabled live reconcile rc"
assert_contains "WDTT enabled routes all WireGuard server client traffic" "$T/nft.log" \
    'nft:add rule inet zapret2 z2k_warp_mark iifname wgserver meta mark set mark'
if grep 'nft:add rule .*z2k_warp_mark iifname wgserver' "$T/nft.log" | grep -q 'ip daddr @z2k_warp_dst4'; then
    _t_bad "WDTT route was incorrectly limited to destination-list IPs"
else
    _t_ok
fi
: > "$WARP_LISTS_DIR/.disabled"
for _list_file in "$WARP_LISTS_DIR"/*.txt; do
    [ "$_list_file" = "$WARP_DEVICES_FILE" ] && continue
    [ -f "$_list_file" ] || continue
    basename "$_list_file" .txt >> "$WARP_LISTS_DIR/.disabled"
done
: > "$WARP_ENABLED_FILE"
: > "$T/nft-empty-dst-set"
: > "$T/nft.log"
warp_ipset --reconcile-rules || _t_bad "WDTT no-list reconcile rc"
if grep 'nft:add rule .*z2k_warp_mark iifname wgserver meta mark set' "$T/nft.log" >/dev/null; then
    _t_bad "WDTT clients stay direct when active lists are empty"
else
    _t_ok
fi
if grep 'nft:add rule .*z2k_warp_mark iifname wgclient.*meta mark set' "$T/nft.log" >/dev/null; then
    _t_bad "native WireGuard client ingress stays direct when active lists are empty"
else
    _t_ok
fi
if warp_full_device_mode; then _t_ok; else _t_bad "empty active lists enter full-device LAN mode"; fi
rm -f "$WARP_LISTS_DIR/.disabled"
rm -f "$T/nft-empty-dst-set"
printf 'steam\n' > "$WARP_ENABLED_FILE"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=0\n' > "$T/etc/config"
rm -f "$T/uci-wireguard-enabled"

# --- PBR: install idempotent + конфликты ---
# proven-ready фикстура: status ready + живой процесс + link
mkdir -p "$T/tmp/warp" "$T/proc/4242"
printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg"}\n' > "$T/tmp/warp/status.json"
printf 'z2k-warpd run --device x\n' | tr ' ' '\0' > "$T/proc/4242/cmdline"
printf '4242\n' > "$T/pidof.out"
export WARP_STATUS="$T/tmp/warp/status.json" Z2K_PROC_ROOT="$T/proc"
: > "$T/ip-rules"; rm -f "$T"/ip-route-*
: > "$T/link-z2ktun0"
warp_pbr_up || _t_bad "pbr_up rc"
assert_contains "route replace" "$T/ip.log" "route replace default dev z2ktun0 table 989"
assert_contains "rule add exact" "$T/ip-rules" "fwmark 0x80000000/0x80000000 lookup 989"
_adds1="$(grep -c '^ip:rule add' "$T/ip.log")"
warp_pbr_up || _t_bad "pbr_up повтор rc"
assert_eq "rule add идемпотентен" "$_adds1" "$(grep -c '^ip:rule add' "$T/ip.log")"
# BusyBox ip on the live router pads route output before the newline.  The
# ownership check must accept that presentation without treating our route as
# foreign (and teardown must still be able to release it).
sed 's/$/ /' "$T/ip-route-989" > "$T/ip-route-989.padded"
mv -f "$T/ip-route-989.padded" "$T/ip-route-989"
warp_pbr_up || _t_bad "pbr_up: padded route output"
assert_contains "padded route accepted" "$T/ip-rules" "fwmark 0x80000000/0x80000000 lookup 989"
# iproute2 omits the default full-width mask when rendering `fwmark`.
# Telegram UDP owns bit 27; that rule is disjoint from WARP's bit 31 and
# must coexist rather than being misparsed as a mask equal to its mark value.
warp_pbr_down >/dev/null 2>&1
printf '89: from all fwmark 0x08000000 lookup 988\n' > "$T/ip-rules"
: > "$T/ip-route-989"
warp_pbr_up >/dev/null 2>&1 && _t_ok || _t_bad "unmasked disjoint Telegram fwmark rejected"
assert_contains "unmasked Telegram rule preserved" "$T/ip-rules" "89: from all fwmark 0x08000000 lookup 988"
assert_contains "WARP rule coexists with Telegram" "$T/ip-rules" "fwmark 0x80000000/0x80000000 lookup 989"
warp_pbr_down >/dev/null 2>&1
assert_contains "WARP teardown preserves Telegram" "$T/ip-rules" "89: from all fwmark 0x08000000 lookup 988"
: > "$T/ip-rules"
# конфликт mark:
printf '400: from all fwmark 0x80000000/0xffffffff lookup 100\n' > "$T/ip-rules"
warp_pbr_up >/dev/null 2>&1 && _t_bad "mark-конфликт принят" || _t_ok
: > "$T/ip-rules"
# An unmasked rule has the same implicit full-width mask and must still be
# rejected when it positively matches WARP's bit 31.
printf '400: from all fwmark 0x80000000 lookup 100\n' > "$T/ip-rules"
warp_pbr_up >/dev/null 2>&1 && _t_bad "unmasked overlapping mark-конфликт принят" || _t_ok
: > "$T/ip-rules"
# конфликт table:
printf 'default dev eth0 table 989\n' > "$T/ip-route-989"
warp_pbr_up >/dev/null 2>&1 && _t_bad "table-конфликт принят" || _t_ok
: > "$T/ip-route-989"
# конфликт pref:
printf '500: from all lookup main\n' > "$T/ip-rules"
warp_pbr_up >/dev/null 2>&1 && _t_bad "pref-конфликт принят" || _t_ok
: > "$T/ip-rules"
# down: exact owned teardown (defects 4/5): сначала поднимаем owned PBR,
# затем down — снимаются ровно наше rule (с pref) и наш route (по owner).
warp_pbr_up >/dev/null 2>&1 || _t_bad "down-fixture: pbr_up rc"
: > "$T/ip.log"; : > "$T/nft.log"
warp_pbr_down
assert_contains "down: exact rule del с pref" "$T/ip.log" "rule del pref 500 fwmark 0x80000000/0x80000000 table 989"
assert_contains "down: route del" "$T/ip.log" "route del default table 989"
assert_eq "down: правило снято" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
assert_eq "down: route снят" "0" "$([ -f "$T/ip-route-989" ] && echo 1 || echo 0)"
assert_eq "down: owner убран" "0" "$([ -f "$T/tmp/warp/pbr.owner" ] && echo 1 || echo 0)"
# чужое правило (тот же mark, другой pref) — НЕ трогаем:
printf '499: from all fwmark 0x80000000/0x80000000 lookup 989\n' > "$T/ip-rules"
warp_pbr_down >/dev/null 2>&1
assert_contains "down: чужое правило цело" "$T/ip-rules" "499: from all fwmark"

# --- status line ---
_out="$(warp_status)"
printf '%s' "$_out" > "$T/status.log"
assert_contains "status installed=1" "$T/status.log" "installed=1 enabled=1"

# --- register due + proxy secrecy ---
rm -f "$T/tmp/warp-register.stamp"
export WARP_REG_STAMP="$T/tmp/warp-register.stamp" WARP_REG_RETRY=600
warp_register_due && _t_ok || _t_bad "due при отсутствии stamp"
date +%s > "$T/tmp/warp-register.stamp"
warp_register_due && _t_bad "due сразу после stamp" || _t_ok
: > "$T/warpd.log"
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
warp_register >/dev/null 2>"$T/reg.err" || _t_bad "register rc"
assert_contains "register вызван" "$T/warpd.log" "register --device $T/etc/state/warp/device.json"
if grep -q 'z2kW4rpR3g2026' "$T/reg.err"; then _t_bad "секрет релея в логе"; else _t_ok; fi
assert_eq "device 600" "600" "$(stat -c %a "$T/etc/state/warp/device.json" 2>/dev/null || echo 600)"

# A full WARP cleanup may delete only the adapter-owned domain pair set. A
# foreign set with the same name must survive even though generic WARP chains
# are torn down.
printf 'set z2k_warp_domain4 { type ipv4_addr . ipv4_addr; comment "someone else"; }\n' > "$T/nft-domain-set"
: > "$T/nft.log"
warp_nft_remove full
if grep -q 'nft:delete set inet zapret2 z2k_warp_domain4' "$T/nft.log"; then
    _t_bad "full cleanup deletes foreign WARP domain set"
else
    _t_ok
fi

# A previous domain selection can leave the owned, now-empty pair set behind.
# The verifier must not require a domain mark rule when there are no selected
# domains, or its repair loop tears down otherwise-healthy WARP PBR. Conversely,
# active domains require both the owned set and the mark rule.
printf 'chain z2k_warp_mark {\n ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4 meta mark set\n}\n' \
    > "$T/nft-chain-z2k_warp_mark"
for _c in z2k_warp_mss z2k_warp_fwd z2k_warp_nat; do
    printf 'chain %s { }\n' "$_c" > "$T/nft-chain-$_c"
done
printf 'set z2k_warp_domain4 { type ipv4_addr . ipv4_addr; comment "z2k WARP DNS pairs"; }\n' \
    > "$T/nft-domain-set"
: > "$T/etc/user-lists/warp/mine.txt"
warp_nft_rules_verify && _t_ok || _t_bad "empty retained pair set rejects valid base WARP rules"

printf 'www.cloudflare.com\n' > "$T/etc/user-lists/warp/mine.txt"
rm -f "$T/nft-domain-set"
warp_nft_rules_verify && _t_bad "active domains accepted without owned pair set" || _t_ok
printf 'set z2k_warp_domain4 { type ipv4_addr . ipv4_addr; comment "z2k WARP DNS pairs"; }\n' \
    > "$T/nft-domain-set"
warp_nft_rules_verify && _t_bad "active domains accepted without domain mark rule" || _t_ok
printf ' ip saddr @z2k_warp_src4 ip saddr . ip daddr @z2k_warp_domain4 meta mark set\n' \
    >> "$T/nft-chain-z2k_warp_mark"
warp_nft_rules_verify && _t_ok || _t_bad "valid active-domain mark rule rejected"

# The route verifier must prove WDTT policy too. It requires the blanket
# ingress mark when enabled and rejects stale WireGuard-server marks after
# disable, including old destination-scoped rules.
touch "$T/uci-wireguard-enabled"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=1\n' > "$T/etc/config"
printf ' iifname "wgserver" return\n' >> "$T/nft-chain-z2k_warp_mark"
printf ' iifname "wgserver" meta mark set mark\n' >> "$T/nft-chain-z2k_warp_mark"
for _subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    printf ' iifname "wgclient" ip saddr %s ip daddr @z2k_warp_dst4 meta mark set\n' "$_subnet" \
        >> "$T/nft-chain-z2k_warp_mark"
    printf ' iifname "wgclient" ip saddr %s ip saddr . ip daddr @z2k_warp_domain4 meta mark set\n' "$_subnet" \
        >> "$T/nft-chain-z2k_warp_mark"
done
warp_nft_rules_verify && _t_ok || _t_bad "WDTT route verifier accepts enabled full-ingress rule"
sed '/iifname "wgserver" meta mark set mark/d' "$T/nft-chain-z2k_warp_mark" > "$T/nft-chain-z2k_warp_mark.new"
mv "$T/nft-chain-z2k_warp_mark.new" "$T/nft-chain-z2k_warp_mark"
warp_nft_rules_verify && _t_bad "WDTT route verifier accepts missing enabled rule" || _t_ok
printf ' iifname "wgserver" ip saddr 10.0.0.0/8 ip daddr @z2k_warp_dst4 meta mark set\n' \
    >> "$T/nft-chain-z2k_warp_mark"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=0\n' > "$T/etc/config"
warp_nft_rules_verify && _t_bad "disabled WDTT verifier accepts stale scoped server rule" || _t_ok
sed '/iifname "wgserver"/d' "$T/nft-chain-z2k_warp_mark" > "$T/nft-chain-z2k_warp_mark.new"
mv "$T/nft-chain-z2k_warp_mark.new" "$T/nft-chain-z2k_warp_mark"
printf ' iifname "wgserver" return\n' >> "$T/nft-chain-z2k_warp_mark"
warp_nft_rules_verify && _t_ok || _t_bad "disabled WDTT accepts direct WireGuard server clients"
rm -f "$T/uci-wireguard-enabled"

# Production-path regression: the real WebPanel device commit launches the
# actual platform adapter. Only nft/ip/uci are modeled; no apply helper is
# replaced. A MARK-only reconcile must preserve all TUN-owned chains and every
# route proof after the first selected LAN device is applied.
cp "$REPO/tests/openwrt/fixtures/nft-stateful.sh" "$T/bin/nft"
chmod +x "$T/bin/nft"
rm -rf "$T/nft-state"
rm -f "$T/nft-domain-table" "$T/nft-domain-set" "$T/nft-domain-chain-z2k_dns_output" \
    "$T/nft-domain-chain-z2k_dns_forward" "$T/no-table" "$T/fw4-forward" "$T/uci-wireguard-enabled"
: > "$T/nft.log"
: > "$T/neigh"
: > "$T/ip-rules"
rm -f "$T"/ip-route-* "$T/tmp/warp/pbr.owner" "$T/tmp/warp/probe-route.owner" \
    "$WARP_LISTS_DIR/mine.txt"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=0\n' > "$T/etc/config"
: > "$WARP_DEVICES_FILE"
printf 'steam\n' > "$WARP_ENABLED_FILE"
: > "$WARP_LISTS_DIR/.disabled"
printf '8.8.8.8\n' > "$WARP_GAMES_DIR/steam.txt"
: > "$WARP_DOMAIN_RULES"
rm -f "$WARP_DOMAIN_ERROR"
touch "$WARP_LISTS_DIR/.legacy-aggregate-purged"
printf '192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' > "$T/neigh"
printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg"}\n' > "$T/tmp/warp/status.json"
warp_nft_sets_load || _t_bad "acceptance initial sets apply"
warp_nft_rules_apply || _t_bad "acceptance initial MARK apply"
warp_nft_tun_apply z2ktun0 || _t_bad "acceptance initial TUN apply"
warp_pbr_up || _t_bad "acceptance initial PBR apply"
_initial_route="$(warp_status)"
printf '%s\n' "$_initial_route" > "$T/acceptance-initial-route.log"
assert_contains "acceptance starts route-ready" "$T/acceptance-initial-route.log" "route_ready=1"
_tun_before="$(for _c in z2k_warp_mss z2k_warp_fwd z2k_warp_nat; do nft list chain inet zapret2 "$_c"; done)"
_pbr_before="$(cat "$T/ip-rules"; cat "$T/ip-route-989"; cat "$T/tmp/warp/pbr.owner")"
unset Z2K_WARP_SOURCE_ONLY
export WARP_SCRIPT="$REPO/platform/openwrt/warp.sh" CONFIG_FILE="$T/etc/config"
. "$REPO/webpanel/cgi/actions.sh" 2>/dev/null
warp_device_toggle aa:bb:cc:dd:ee:ff 1 || _t_bad "production WebPanel device toggle ON"
_src_after="$(nft list set inet zapret2 z2k_warp_src4)"
printf '%s\n' "$_src_after" > "$T/acceptance-source-set.log"
assert_contains "production toggle changes source set" "$T/acceptance-source-set.log" "192.168.1.50"
_tun_after="$(for _c in z2k_warp_mss z2k_warp_fwd z2k_warp_nat; do nft list chain inet zapret2 "$_c"; done)"
_pbr_after="$(cat "$T/ip-rules"; cat "$T/ip-route-989"; cat "$T/tmp/warp/pbr.owner")"
assert_eq "production device reconcile preserves TUN chains" "$_tun_before" "$_tun_after"
assert_eq "production device reconcile preserves PBR and owner" "$_pbr_before" "$_pbr_after"
_device_route="$(warp_status)"
printf '%s\n' "$_device_route" > "$T/production-device-route.log"
printf 'ROUTE[device-on]: %s\n' "$_device_route"
assert_contains "production device toggle retains full route proof" "$T/production-device-route.log" "route_ready=1"
assert_contains "production device toggle proves MARK" "$T/production-device-route.log" "nft_mark=present"
assert_contains "production device toggle proves TUN" "$T/production-device-route.log" "tun=present"
assert_contains "production device toggle proves PBR and owner" "$T/production-device-route.log" "pbr=present owner=present"
nft list chain inet zapret2 z2k_warp_mark > "$T/production-device-mark.log"
assert_contains "selected device with active lists uses scoped MARK" \
    "$T/production-device-mark.log" \
    'ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4 meta mark set mark'

acceptance_route_ready() {
    warp_status > "$T/acceptance-route-current.log"
    assert_contains "$1 keeps route_ready" "$T/acceptance-route-current.log" "route_ready=1"
}
acceptance_mark_contains() {
    nft list chain inet zapret2 z2k_warp_mark > "$T/acceptance-mark-current.log"
    assert_contains "$1" "$T/acceptance-mark-current.log" "$2"
}
acceptance_policy_unchanged() {
    _tun_now="$(for _c in z2k_warp_mss z2k_warp_fwd z2k_warp_nat; do nft list chain inet zapret2 "$_c"; done)"
    _pbr_now="$(cat "$T/ip-rules"; cat "$T/ip-route-989"; cat "$T/tmp/warp/pbr.owner")"
    assert_eq "$1 preserves TUN chains" "$_tun_before" "$_tun_now"
    assert_eq "$1 preserves PBR and owner" "$_pbr_before" "$_pbr_now"
    acceptance_route_ready "$1"
}

# The last selected device can be removed without losing route readiness.
warp_device_toggle aa:bb:cc:dd:ee:ff 0 || _t_bad "production WebPanel device toggle OFF"
_src_after_off="$(nft list set inet zapret2 z2k_warp_src4)"
printf '%s\n' "$_src_after_off" > "$T/acceptance-source-set-off.log"
assert_not_contains "last device OFF empties source set" "$T/acceptance-source-set-off.log" '192.168.1.50'
acceptance_policy_unchanged "last device OFF"
printf 'ROUTE[device-off]: %s\n' "$(cat "$T/acceptance-route-current.log")"
acceptance_mark_contains "last device OFF returns to destination-only policy" \
    'ip daddr @z2k_warp_dst4 meta mark set mark'

# Selected device + no active destination lists means full-device mode. First
# enabling a destination list must switch back to list-scoped MARK immediately.
warp_device_toggle aa:bb:cc:dd:ee:ff 1 || _t_bad "production device toggle ON before list transitions"
warp_game_toggle steam 0 || _t_bad "disable last destination list"
warp_ipset_reload_if_enabled --reconcile-rules || _t_bad "full-device policy transition apply"
acceptance_policy_unchanged "full-device policy transition"
acceptance_mark_contains "selected device without lists uses full-device MARK" \
    'ip saddr @z2k_warp_src4 ip daddr != 0.0.0.0/8'
warp_game_toggle steam 1 || _t_bad "enable first destination list"
warp_ipset_reload_if_enabled --reconcile-rules || _t_bad "list policy transition apply"
acceptance_policy_unchanged "list policy transition"
acceptance_mark_contains "active destination list scopes MARK to selected source" \
    'ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4 meta mark set mark'

# Native WireGuard client discovery and WDTT are MARK-only changes. Capability
# is derived from the canonical server-interface helper; client presence alone
# must not make the server-only control available.
warp_status > "$T/wg-server-absent.log"
assert_contains "WDTT capability false without WG server" "$T/wg-server-absent.log" "wg_server_available=0"
touch "$T/uci-wireguard-enabled"
warp_ipset_reload_if_enabled --reconcile-rules || _t_bad "native WG client policy reconcile"
acceptance_policy_unchanged "native WG client policy reconcile"
acceptance_mark_contains "native WG client policy has dedicated list mark" \
    'iifname "wgclient" ip saddr 10.0.0.0/8 ip daddr @z2k_warp_dst4 meta mark set mark'
warp_status > "$T/wg-server-present.log"
assert_contains "WDTT capability true with WG server" "$T/wg-server-present.log" "wg_server_available=1"
warp_wdtt_set 1 || _t_bad "WDTT enabled production reconcile"
acceptance_policy_unchanged "WDTT enable"
acceptance_mark_contains "WDTT enables full ingress mark for WG server" \
    'iifname "wgserver" meta mark set mark'
warp_wdtt_set 0 || _t_bad "WDTT disabled production reconcile"
acceptance_policy_unchanged "WDTT disable"

_t_done
