#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-doh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
_doh_test_package_installed_rc() {
    if [ -f "$Z2K_DOH_PACKAGE_FILE" ]; then printf '0'; else printf '1'; fi
}
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-doh.XXXXXX")" || exit 1
_DOH_TEST_DNSMASQ_PID=""
_DOH_TEST_DNS_UPSTREAM_PID=""
_doh_test_cleanup() {
    if [ -n "$_DOH_TEST_DNSMASQ_PID" ]; then
        kill "$_DOH_TEST_DNSMASQ_PID" 2>/dev/null || true
        wait "$_DOH_TEST_DNSMASQ_PID" 2>/dev/null || true
    fi
    if [ -n "$_DOH_TEST_DNS_UPSTREAM_PID" ]; then
        kill "$_DOH_TEST_DNS_UPSTREAM_PID" 2>/dev/null || true
        wait "$_DOH_TEST_DNS_UPSTREAM_PID" 2>/dev/null || true
    fi
    rm -rf "$T"
}
trap _doh_test_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH"
export Z2K_STATE="$T/state" Z2K_ROOT="$REPO"
export Z2K_DOH_UCI_BIN=uci Z2K_DOH_APK_BIN=apk
export Z2K_DOH_PROXY_INIT="$T/https-dns-proxy.init"
export Z2K_DOH_DNSMASQ_INIT="$T/dnsmasq.init"
export Z2K_DOH_PROC_NET_UDP_FILE="$T/net-udp"
export Z2K_DOH_TEST_DB="$T/uci.db" Z2K_DOH_TEST_LOG="$T/calls.log"
export Z2K_DOH_PACKAGE_FILE="$T/package-installed"
export Z2K_DOH_RUNNING_FILE="$T/proxy-running"
export Z2K_DOH_ENABLED_FILE="$T/service-enabled"
export Z2K_DOH_DNSMASQ_RUNNING_FILE="$T/dnsmasq-running"
export Z2K_DOH_LOOKUP_FILE="$T/lookup-result"
export Z2K_DOH_LISTENER_FILE="$T/listener-ready"
export Z2K_DOH_TEST_INIT_ENABLED="$T/init-enabled-before"
export Z2K_DOH_TEST_INIT_RUNNING="$T/init-running-before"
export Z2K_DOH_APK_DEL_FAIL_FILE="$T/apk-del-fail"
: > "$Z2K_DOH_TEST_DB"
: > "$Z2K_DOH_TEST_LOG"
printf "dhcp.@dnsmasq[0]='dnsmasq'\n" > "$Z2K_DOH_TEST_DB"
printf 'dnsmasq\n' > "$Z2K_DOH_DNSMASQ_RUNNING_FILE"
printf '203.0.113.8\n' > "$Z2K_DOH_LOOKUP_FILE"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ "${1:-}" = -q ] && shift
cmd=${1:-}; shift || true
case "$cmd" in
    get)
        key=$1
        awk -F= -v k="$key" '$1 == k { v=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", v); print v; found=1; exit } END { if (!found) exit 1 }' "$Z2K_DOH_TEST_DB"
        ;;
    show)
        target=${1:-}
        if [ -z "$target" ]; then cat "$Z2K_DOH_TEST_DB"; exit 0; fi
        case "$target" in
            *.*) awk -v t="$target" 'index($0,t)==1 && (substr($0,length(t)+1,1)=="=" || substr($0,length(t)+1,1)==".")' "$Z2K_DOH_TEST_DB" ;;
            *) grep -E "^${target}\." "$Z2K_DOH_TEST_DB" ;;
        esac
        ;;
    set)
        entry=$1; key=${entry%%=*}; value=${entry#*=}
        awk -F= -v k="$key" '$1 != k' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
        printf "%s='%s'\n" "$key" "$value" >> "$Z2K_DOH_TEST_DB.new"
        mv "$Z2K_DOH_TEST_DB.new" "$Z2K_DOH_TEST_DB"
        ;;
    add_list)
        entry=$1; key=${entry%%=*}; value=${entry#*=}
        printf "%s='%s'\n" "$key" "$value" >> "$Z2K_DOH_TEST_DB"
        ;;
    del_list)
        entry=$1; key=${entry%%=*}; value=${entry#*=}
        awk -F= -v k="$key" -v v="'${value}'" '!($1 == k && substr($0,index($0,"=")+1) == v)' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
        mv "$Z2K_DOH_TEST_DB.new" "$Z2K_DOH_TEST_DB"
        ;;
    delete)
        key=$1
        awk -F= -v k="$key" '$1 != k && index($1,k ".") != 1' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
        mv "$Z2K_DOH_TEST_DB.new" "$Z2K_DOH_TEST_DB"
        ;;
    commit) exit 0 ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/apk" <<'STUB'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "$1 $2" in
    'info -e') [ -f "$Z2K_DOH_PACKAGE_FILE" ] ;;
    'add https-dns-proxy')
        : > "$Z2K_DOH_PACKAGE_FILE"
        # Match the package's shipped UCI layout: "config main 'config'"
        # appears in uci show as section "config" with type "main".
        if ! grep -q "^https-dns-proxy.config='" "$Z2K_DOH_TEST_DB"; then
            printf "https-dns-proxy.config='main'\nhttps-dns-proxy.config.force_dns='1'\nhttps-dns-proxy.config.dnsmasq_config_update='*'\nhttps-dns-proxy.@https-dns-proxy[0]='https-dns-proxy'\nhttps-dns-proxy.@https-dns-proxy[0].resolver_url='https://cloudflare-dns.com/dns-query'\nhttps-dns-proxy.@https-dns-proxy[0].listen_port='5053'\nhttps-dns-proxy.@https-dns-proxy[1]='https-dns-proxy'\nhttps-dns-proxy.@https-dns-proxy[1].resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.@https-dns-proxy[1].listen_port='5054'\n" >> "$Z2K_DOH_TEST_DB"
        fi
        ;;
    'del https-dns-proxy')
        [ ! -f "$Z2K_DOH_APK_DEL_FAIL_FILE" ] || exit 1
        rm -f "$Z2K_DOH_PACKAGE_FILE"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$Z2K_DOH_PROXY_INIT" <<'STUB'
#!/bin/sh
printf 'proxy %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "$1" in
    enabled) [ -f "$Z2K_DOH_ENABLED_FILE" ] ;;
    enable) : > "$Z2K_DOH_ENABLED_FILE" ;;
    disable) rm -f "$Z2K_DOH_ENABLED_FILE" ;;
    restart|start|reload)
        : > "$Z2K_DOH_RUNNING_FILE"
        : > "$Z2K_DOH_LISTENER_FILE"
        listen_port=$(awk -F= '$1 == "https-dns-proxy.z2kow_doh.listen_port" { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", value); print value; exit }' "$Z2K_DOH_TEST_DB")
        port_hex=$(printf '%04X' "$listen_port")
        printf '0: 0100007F:%s 00000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 1\n' "$port_hex" > "$Z2K_DOH_PROC_NET_UDP_FILE"
        ;;
    stop)
        rm -f "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_LISTENER_FILE"
        : > "$Z2K_DOH_PROC_NET_UDP_FILE"
        ;;
    status) [ -f "$Z2K_DOH_RUNNING_FILE" ] ;;
    *) exit 2 ;;
esac
STUB
cat > "$Z2K_DOH_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ "${1:-}" = restart ] || exit 1
if [ "${Z2K_DOH_EMIT_UDHCPC_WARNING:-0}" = 1 ]; then
    printf 'udhcpc: broadcasting discover\nudhcpc: no lease, failing\n' >&2
fi
if [ -n "${Z2K_TIKTOK_EFFECTIVE_CONFIG:-}" ]; then
    awk -F= '$1 ~ /\.address$/ { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value); print "address=" value }' \
        "$Z2K_DOH_TEST_DB" > "$Z2K_TIKTOK_EFFECTIVE_CONFIG"
fi
STUB
cat > "$T/bin/pidof" <<'STUB'
#!/bin/sh
case "$1" in
    https-dns-proxy) [ -f "$Z2K_DOH_RUNNING_FILE" ] && echo 123 ;;
    dnsmasq) [ -f "$Z2K_DOH_DNSMASQ_RUNNING_FILE" ] && echo 456 ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf 'nslookup %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
port=53 host= server=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -port=*) port=${1#-port=} ;;
        -*) exit 2 ;;
        *)
            if [ -z "$host" ]; then host=$1
            elif [ -z "$server" ]; then server=$1
            fi
            ;;
    esac
    shift
done
[ -n "$host" ] || exit 2
[ "$server" = 127.0.0.1 ] || exit 2
if [ "$port" = 53 ]; then
    [ -f "$Z2K_DOH_DNSMASQ_RUNNING_FILE" ] || exit 1
else
    [ -f "$Z2K_DOH_RUNNING_FILE" ] || exit 1
    configured_port=$(awk -F= '$1 == "https-dns-proxy.z2kow_doh.listen_port" { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", value); print value; exit }' "$Z2K_DOH_TEST_DB")
    [ "$port" = "$configured_port" ] || exit 1
fi
answer=$(awk -F= -v host="$host" '$1 ~ /\.address$/ { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value); n=split(value,a,/[[:space:]]+/); for(i=1;i<=n;i++) if(a[i] ~ ("^/" host "/")) { sub("^/" host "/","",a[i]); print a[i]; exit } }' "$Z2K_DOH_TEST_DB")
if [ -z "$answer" ]; then
    if [ "$port" = 53 ]; then
        [ -f "$Z2K_DOH_RUNNING_FILE" ] || exit 1
        listen_port=$(awk -F= '$1 == "https-dns-proxy.z2kow_doh.listen_port" { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", value); print value; exit }' "$Z2K_DOH_TEST_DB")
        grep -q "server='/#/127.0.0.1#${listen_port}'" "$Z2K_DOH_TEST_DB" || exit 1
    fi
    answer=$(cat "$Z2K_DOH_LOOKUP_FILE")
fi
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1:53\n\nName: %s\nAddress: %s\n' "$host" "$answer"
STUB
cat > "$T/dns-upstream.py" <<'PY'
import socket
import struct
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", int(sys.argv[1])))
while True:
    packet, peer = sock.recvfrom(4096)
    if len(packet) < 17:
        continue
    pos = 12
    while pos < len(packet) and packet[pos] != 0:
        pos += packet[pos] + 1
    pos += 1
    if pos + 4 > len(packet):
        continue
    question = packet[12:pos + 4]
    qtype = struct.unpack("!H", packet[pos:pos + 2])[0]
    if qtype == 1:
        header = packet[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton("203.0.113.250")
        response = header + question + answer
    else:
        response = packet[:2] + struct.pack("!HHHHH", 0x8180, 1, 0, 0, 0) + question
    sock.sendto(response, peer)
PY
cat > "$T/dns-query.py" <<'PY'
import socket
import struct
import sys

host, port, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ident = 0x5A2B
qname = b"".join(bytes([len(label)]) + label.encode("ascii") for label in name.rstrip(".").split(".")) + b"\0"
packet = struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2)
sock.sendto(packet, (host, port))
response, _ = sock.recvfrom(4096)
flags, answers = struct.unpack("!HH", response[2:6])
if response[:2] != struct.pack("!H", ident) or flags & 0x000F or answers < 1:
    raise SystemExit(1)
pos = 12
while response[pos] != 0:
    pos += response[pos] + 1
pos += 5
for _ in range(answers):
    if response[pos] & 0xC0 == 0xC0:
        pos += 2
    else:
        while response[pos] != 0:
            pos += response[pos] + 1
        pos += 1
    qtype, _, _, size = struct.unpack("!HHIH", response[pos:pos + 10])
    pos += 10
    data = response[pos:pos + size]
    pos += size
    if qtype == 1 and size == 4:
        print(socket.inet_ntoa(data))
        break
else:
    raise SystemExit(1)
PY
_doh_test_real_dnsmasq_tiktok() {
    local _resolver_port="$1" _ports _dns_port _upstream_port _i=0 _actual
    if ! command -v dnsmasq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        _t_skip "real dnsmasq/Python resolver fixture is unavailable"
        return 0
    fi
    _ports=$(python3 -c 'import socket; ss=[]
for _ in range(2):
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); ss.append(s)
print(ss[0].getsockname()[1],ss[1].getsockname()[1])
for s in ss: s.close()') || return 1
    IFS=' ' read -r _dns_port _upstream_port <<EOF_DOH_PORTS
$_ports
EOF_DOH_PORTS
    awk -F= '
        $1 ~ /^dhcp\.[^.]+\.address$/ {
            value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value)
            n=split(value,a,/[[:space:]]+/)
            for(i=1;i<=n;i++) if(a[i] ~ /^\/v77\.tiktokcdn(-eu)?\.com\//) print "address=" a[i]
        }
        $1 ~ /^dhcp\.[^.]+\.server$/ {
            value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value)
            if(value ~ /^\/#\/127\.0\.0\.1#/) print "server=" value
        }
    ' "$Z2K_DOH_TEST_DB" | sed "s/#$_resolver_port/#$_upstream_port/" > "$T/dnsmasq-real.conf"
    assert_contains "real dnsmasq fixture uses the DoH catch-all route from UCI" "$T/dnsmasq-real.conf" "server=/#/127.0.0.1#$_upstream_port"
    assert_contains "real dnsmasq fixture includes TikTok primary override from UCI" "$T/dnsmasq-real.conf" "address=/v77.tiktokcdn.com/87.245.200.35"
    assert_contains "real dnsmasq fixture includes TikTok EU override from UCI" "$T/dnsmasq-real.conf" "address=/v77.tiktokcdn-eu.com/87.245.200.35"
    python3 "$T/dns-upstream.py" "$_upstream_port" > "$T/dns-upstream.log" 2>&1 &
    _DOH_TEST_DNS_UPSTREAM_PID=$!
    dnsmasq --no-daemon --port="$_dns_port" --listen-address=127.0.0.1 --bind-interfaces \
        --no-resolv --no-hosts --cache-size=0 --conf-file="$T/dnsmasq-real.conf" \
        --user="$(id -un)" --log-facility="$T/dnsmasq-real.log" \
        > "$T/dnsmasq-real.stdout" 2>&1 &
    _DOH_TEST_DNSMASQ_PID=$!
    while [ "$_i" -lt 20 ]; do
        _actual=$(python3 "$T/dns-query.py" 127.0.0.1 "$_dns_port" example.com 2>/dev/null) && break
        sleep 0.1
        _i=$((_i + 1))
    done
    assert_eq "real dnsmasq sends ordinary names to the fake DoH upstream" 203.0.113.250 "$_actual"
    _actual=$(python3 "$T/dns-query.py" 127.0.0.1 "$_dns_port" v77.tiktokcdn.com 2>/dev/null) || _actual=query-failed
    assert_eq "real dnsmasq answers TikTok primary from its local address override" 87.245.200.35 "$_actual"
    _actual=$(python3 "$T/dns-query.py" 127.0.0.1 "$_dns_port" v77.tiktokcdn-eu.com 2>/dev/null) || _actual=query-failed
    assert_eq "real dnsmasq answers TikTok EU from its local address override" 87.245.200.35 "$_actual"
    kill "$_DOH_TEST_DNSMASQ_PID" "$_DOH_TEST_DNS_UPSTREAM_PID" 2>/dev/null || true
    wait "$_DOH_TEST_DNSMASQ_PID" 2>/dev/null || true
    wait "$_DOH_TEST_DNS_UPSTREAM_PID" 2>/dev/null || true
    _DOH_TEST_DNSMASQ_PID=""
    _DOH_TEST_DNS_UPSTREAM_PID=""
}
chmod 0755 "$T/bin/uci" "$T/bin/apk" "$T/bin/pidof" "$T/bin/nslookup" \
    "$Z2K_DOH_PROXY_INIT" "$Z2K_DOH_DNSMASQ_INIT"

if [ -r "$REPO/platform/openwrt/doh.sh" ]; then
    # shellcheck disable=SC1091
    . "$REPO/platform/openwrt/doh.sh"
else
    _t_bad "OpenWrt DoH adapter is present"
    _t_done
    exit 1
fi

_status=$(z2k_ow_doh_status)
printf '%s\n' "$_status" > "$T/status"
assert_contains "absent component is explicit" "$T/status" 'state=not-installed'

:> "$Z2K_DOH_LOOKUP_FILE"
if z2k_ow_doh_install >"$T/failed-install.stdout" 2>"$T/failed-install.stderr"; then
    _t_bad "a failed direct listener query aborts installation"
else
    _t_ok
fi
assert_eq "failed install remains an explicit error after rollback" error "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_eq "failed install reports the direct listener query as the cause" listener-query-failed "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
assert_not_contains "failed install removes only its z2kOW resolver section" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.z2kow_doh='
assert_not_contains "failed install removes its package ownership marker" "$T/state/.doh-package-owned" .
assert_not_contains "failed install leaves no catch-all DNS route" "$Z2K_DOH_TEST_DB" "server='/#/127.0.0.1#5055'"

printf '203.0.113.8\n' > "$Z2K_DOH_LOOKUP_FILE"
export Z2K_DOH_EMIT_UDHCPC_WARNING=1
if z2k_ow_doh_install >"$T/install.stdout" 2>"$T/install.stderr"; then
    _t_ok
else
    _t_bad "package install creates an owned disabled resolver after live DNS checks"
fi
assert_contains "dnsmasq restart can emit the unrelated udhcpc no-lease warning" "$T/install.stderr" 'udhcpc: no lease, failing'
assert_contains "install uses BusyBox's supported port syntax for the direct listener query" "$Z2K_DOH_TEST_LOG" 'nslookup -port=5055 example.com 127.0.0.1'
assert_contains "install also queries the routed dnsmasq resolver on port 53" "$Z2K_DOH_TEST_LOG" 'nslookup example.com 127.0.0.1'
unset Z2K_DOH_EMIT_UDHCPC_WARNING
assert_file "z2kOW records package ownership after apk add" "$T/state/.doh-package-owned"
assert_contains "install keeps the package main section type intact" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config='main'"
assert_contains "install keeps force DNS off by default" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.force_dns='0'"
assert_contains "install creates only the stable named resolver section" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh='https-dns-proxy'"
assert_contains "install configures the canonical Xbox endpoint" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://xbox-dns.ru/dns-query'"
assert_contains "install configures Xbox bootstrap resolvers" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.bootstrap_dns='111.88.96.50,111.88.96.51'"
_xbox_port=$(awk -F= '$1 == "https-dns-proxy.z2kow_doh.listen_port" { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", value); print value; exit }' "$Z2K_DOH_TEST_DB")
assert_eq "Xbox uses the free port after the package's two stock resolver sections" 5055 "$_xbox_port"
uci delete "https-dns-proxy.z2kow_doh.listen_port"
assert_eq "missing owned listener port is reported as invalid config" \
    "error" "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_eq "missing owned listener port never falls back to a fake healthy default" \
    "resolver-config-changed" "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
uci set "https-dns-proxy.z2kow_doh.listen_port=$_xbox_port"
assert_not_contains "install leaves DoH disabled after its live check" "$Z2K_DOH_TEST_DB" "server='/#/127.0.0.1#5055'"
assert_eq "install status is installed-disabled" installed-disabled "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_eq "status exposes the selected Xbox preset" xbox "$(z2k_ow_doh_status | sed -n 's/.*provider=\([^ ]*\).*/\1/p')"
z2k_ow_doh_select_provider cloudflare || _t_bad "a built-in provider can replace the default while disabled"
assert_contains "Cloudflare preset configures its canonical endpoint" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://cloudflare-dns.com/dns-query'"
assert_eq "provider selection is retained in runtime status" cloudflare "$(z2k_ow_doh_status | sed -n 's/.*provider=\([^ ]*\).*/\1/p')"
if z2k_ow_doh_select_provider custom 'http://resolver.example/dns-query' '9.9.9.9'; then
    _t_bad "custom provider rejects a non-HTTPS endpoint"
else
    _t_ok
fi
z2k_ow_doh_select_provider custom 'https://resolver.example/dns-query?format=dns&mode=secure' '9.9.9.9,149.112.112.112' \
    || _t_bad "custom HTTPS endpoint and bootstrap addresses can be selected"
assert_contains "custom endpoint is applied to the owned resolver section" "$Z2K_DOH_TEST_DB" \
    "https-dns-proxy.z2kow_doh.resolver_url='https://resolver.example/dns-query?format=dns&mode=secure'"
assert_eq "custom provider selection survives status reload" custom "$(z2k_ow_doh_status | sed -n 's/.*provider=\([^ ]*\).*/\1/p')"
z2k_ow_doh_select_provider xbox || _t_bad "the Xbox preset can be restored after using a custom endpoint"

# Update/reinstall may regenerate z2k's ordinary config; DoH runtime settings
# remain in the persistent state/UCI layer and are never installed by default.
printf 'ENABLED=1\nGAME_WARP_ENABLED=0\n' > "$T/regenerated-config"
assert_eq "disabled DoH state survives a config regeneration" installed-disabled "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"

# Exercise the production TikTok UCI helper against the same dnsmasq section.
# A normal upstream is present before DoH starts; a concurrent user edit must
# remain after the owned catch-all route is removed.
uci add_list "dhcp.@dnsmasq[0].server=1.1.1.1"
export Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-hosts"
export Z2K_TIKTOK_UCI_MARKER="$T/state/.tiktok-addnhosts-owned"
export Z2K_TIKTOK_CONTENT_MARKER="$T/state/.tiktok-content-owned"
export Z2K_TIKTOK_ADDRESS_MARKER="$T/state/.tiktok-address-owned"
export Z2K_TIKTOK_EFFECTIVE_CONFIG="$T/dnsmasq.conf"
export Z2K_TIKTOK_STATE_FILE="$T/state/tiktok.state"
export Z2K_TIKTOK_CONFIG="$T/tiktok-config"
export Z2K_TIKTOK_UCI_BIN=uci Z2K_TIKTOK_DNSMASQ_INIT="$Z2K_DOH_DNSMASQ_INIT"
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$Z2K_TIKTOK_CONFIG"
# shellcheck disable=SC1091
. "$REPO/platform/openwrt/tiktok.sh"
_z2k_ow_tiktok_set_host 87.245.200.35 || _t_bad "production TikTok apply installs its exact managed target override"
assert_contains "TikTok primary override exists before DoH enable" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn.com/87.245.200.35"
_z2k_ow_tiktok_set_host 87.245.200.35 v77.tiktokcdn-eu.com || _t_bad "production TikTok apply installs EU managed target override"

z2k_ow_doh_enable || _t_bad "enable starts Xbox DoH and routes dnsmasq through its local listener"
assert_eq "enabled state survives adapter reload" healthy "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_contains "enabled state routes dnsmasq to the Xbox-only loopback listener" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/#/127.0.0.1#$_xbox_port'"
uci add_list "dhcp.@dnsmasq[0].server=9.9.9.9"
z2k_ow_doh_install || _t_bad "repeated install leaves an existing DoH setup untouched"
assert_eq "repeated install preserves the enabled state" healthy "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_contains "repeated install preserves the active dnsmasq route" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/#/127.0.0.1#$_xbox_port'"
rm -f "$Z2K_DOH_RUNNING_FILE"
assert_eq "running state is required for a healthy resolver" "proxy-not-running" \
    "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
: > "$Z2K_DOH_RUNNING_FILE"
: > "$Z2K_DOH_PROC_NET_UDP_FILE"
assert_eq "a process without its UDP listener is only starting" "starting" \
    "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
"$Z2K_DOH_PROXY_INIT" restart
uci del_list "dhcp.@dnsmasq[0].server=/#/127.0.0.1#$_xbox_port"
assert_eq "a running listener without the dnsmasq route is degraded" "dnsmasq-not-routed" \
    "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
z2k_ow_doh_enable || _t_bad "enable restores a removed dnsmasq route"
printf '\n' > "$Z2K_DOH_LOOKUP_FILE"
assert_eq "a routed local listener without a DNS answer is degraded" "listener-query-failed" \
    "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
printf '203.0.113.8\n' > "$Z2K_DOH_LOOKUP_FILE"
rm -f "$Z2K_DOH_DNSMASQ_RUNNING_FILE"
assert_eq "a stopped dnsmasq is degraded even when proxy is ready" "dnsmasq-not-running" \
    "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
: > "$Z2K_DOH_DNSMASQ_RUNNING_FILE"
assert_eq "restored live path returns to healthy" "healthy" \
    "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
assert_contains "TikTok primary override survives DoH enable" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn.com/87.245.200.35"
assert_contains "TikTok EU override survives DoH enable" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn-eu.com/87.245.200.35"
_doh_test_real_dnsmasq_tiktok "$_xbox_port"

z2k_ow_doh_set_force_dns 1 || _t_bad "force DNS toggles independently"
assert_contains "force DNS can be explicitly enabled" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.force_dns='1'"
z2k_ow_doh_restart || _t_bad "restart retains enabled resolver and status checks its live path"
assert_contains "restart preserves TikTok primary override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn.com/87.245.200.35"
assert_contains "restart preserves TikTok EU override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn-eu.com/87.245.200.35"
_doh_test_real_dnsmasq_tiktok "$_xbox_port"

z2k_ow_tiktok_disable || _t_bad "TikTok disable clears only its own dnsmasq overrides"
assert_contains "TikTok disable leaves DoH endpoint configured" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://xbox-dns.ru/dns-query'"
assert_contains "TikTok disable leaves DoH dnsmasq route intact" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/#/127.0.0.1#$_xbox_port'"
_z2k_ow_tiktok_set_host 87.245.200.35 || _t_bad "production TikTok apply can restore the managed primary override"
_z2k_ow_tiktok_set_host 87.245.200.35 v77.tiktokcdn-eu.com || _t_bad "production TikTok apply can restore the managed EU override"

z2k_ow_doh_set_force_dns 0 || _t_bad "force DNS can be disabled independently"
uci set "dhcp.@dnsmasq[0].noresolv=0"
z2k_ow_doh_disable || _t_bad "disable stops DoH without uninstalling its package or config"
assert_eq "disable retains installed package" 0 "$(_doh_test_package_installed_rc)"
assert_contains "disable retains z2k resolver section" "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://xbox-dns.ru/dns-query'"
assert_contains "disable retains TikTok primary override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn.com/87.245.200.35"
assert_contains "disable retains TikTok EU override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn-eu.com/87.245.200.35"
assert_contains "disable restores the prior dnsmasq upstream" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='1.1.1.1'"
assert_contains "disable preserves a concurrent dnsmasq upstream change" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='9.9.9.9'"
assert_contains "disable preserves a concurrent noresolv change" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].noresolv='0'"
assert_eq "disable is reported as installed-disabled" installed-disabled "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"

z2k_ow_doh_enable || _t_bad "re-enable restores local DNS routing"
z2k_ow_doh_uninstall || _t_bad "uninstall removes only DoH-owned configuration"
assert_not_contains "DoH uninstall removes its resolver section" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.z2kow_doh='
assert_not_contains "DoH uninstall removes only its own dnsmasq catch-all" "$Z2K_DOH_TEST_DB" "127.0.0.1#$_xbox_port"
assert_contains "DoH uninstall preserves the original dnsmasq upstream" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='1.1.1.1'"
assert_contains "DoH uninstall preserves the concurrent dnsmasq upstream" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='9.9.9.9'"
assert_contains "DoH uninstall preserves TikTok primary override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn.com/87.245.200.35"
assert_contains "DoH uninstall preserves TikTok EU override" "$Z2K_DOH_TEST_DB" "/v77.tiktokcdn-eu.com/87.245.200.35"
assert_not_contains "z2kOW removes its installed package" "$T/state/.doh-package-owned" .
assert_eq "owned package is removed by apk del" 1 "$(_doh_test_package_installed_rc)"

# An externally installed package keeps its existing global behavior while
# DoH is installed disabled, enabled temporarily by the user, then disabled.
: > "$Z2K_DOH_PACKAGE_FILE"
: > "$Z2K_DOH_TEST_DB"
rm -f "$Z2K_DOH_TEST_INIT_ENABLED" "$Z2K_DOH_TEST_INIT_RUNNING"
printf "dhcp.@dnsmasq[0]='dnsmasq'\nhttps-dns-proxy.config='main'\nhttps-dns-proxy.config.force_dns='1'\nhttps-dns-proxy.config.dnsmasq_config_update='0'\nhttps-dns-proxy.other='https-dns-proxy'\nhttps-dns-proxy.other.resolver_url='https://external.example/dns-query'\nhttps-dns-proxy.other.listen_port='5055'\n" >> "$Z2K_DOH_TEST_DB"
z2k_ow_doh_install || _t_bad "install coexists with an externally installed resolver section"
assert_contains "foreign resolver section is left untouched" "$Z2K_DOH_TEST_DB" "https-dns-proxy.other.resolver_url='https://external.example/dns-query'"
assert_not_contains "external package is not claimed by z2kOW" "$T/state/.doh-package-owned" .
assert_contains "disabled install preserves external force-DNS setting" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.force_dns='1'"
assert_contains "disabled install preserves external dnsmasq routing preference" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.dnsmasq_config_update='0'"
assert_not_contains "disabled integration has no active z2k resolver section" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.z2kow_doh='
assert_eq "external package install leaves DoH disabled" installed-disabled "$(z2k_ow_doh_status | sed -n 's/^state=\([^ ]*\).*/\1/p')"
z2k_ow_doh_enable || _t_bad "external package can enable the owned provider without claiming the package"
_external_xbox_port=$(awk -F= '$1 == "https-dns-proxy.z2kow_doh.listen_port" { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", value); print value; exit }' "$Z2K_DOH_TEST_DB")
if [ "$_external_xbox_port" != 5055 ]; then _t_ok; else _t_bad "selected listener avoids an external resolver port"; fi
assert_contains "external package settings are isolated only while DoH is enabled" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.dnsmasq_config_update='-'"
z2k_ow_doh_disable || _t_bad "external package can disable the owned provider"
assert_not_contains "disabling removes only the inactive z2k resolver instance" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.z2kow_doh='
assert_contains "disable restores external force-DNS setting" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.force_dns='1'"
assert_contains "disable restores external dnsmasq routing preference" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.dnsmasq_config_update='0'"
z2k_ow_doh_uninstall || _t_bad "external package resolver can be restored after Xbox DoH removal"
assert_contains "external force-DNS setting is restored" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.force_dns='1'"
assert_contains "external dnsmasq routing preference is restored" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.dnsmasq_config_update='0'"
assert_eq "externally installed package remains installed" 0 "$(_doh_test_package_installed_rc)"

# A new external resolver added after z2kOW installed its package is an outside
# reason to retain that package when removing only the Xbox integration.
rm -f "$Z2K_DOH_PACKAGE_FILE"
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\n" >> "$Z2K_DOH_TEST_DB"
z2k_ow_doh_install || _t_bad "fresh owned package can be installed after external package was removed"
z2k_ow_doh_enable || _t_bad "DoH can be enabled before an external resolver is added"
printf "https-dns-proxy.other='https-dns-proxy'\nhttps-dns-proxy.other.resolver_url='https://external.example/dns-query'\n" >> "$Z2K_DOH_TEST_DB"
z2k_ow_doh_uninstall || _t_bad "uninstall preserves external package/config that now has an external owner"
assert_contains "later external resolver survives DoH uninstall" "$Z2K_DOH_TEST_DB" "https-dns-proxy.other.resolver_url='https://external.example/dns-query'"
assert_not_contains "z2kOW resolver is removed independently" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.z2kow_doh='
assert_eq "package with a new external resolver is retained" 0 "$(_doh_test_package_installed_rc)"

# Changes to a resolver section that shipped with the package are also external
# ownership. A name-only snapshot used to miss edits to those baseline sections.
rm -f "$Z2K_DOH_PACKAGE_FILE" "$T/state/.doh-package-owned" "$T/state/.doh-uci-owned" \
    "$T/state/.doh-install-snapshot" "$T/state/.doh-main-snapshot"
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\n" >> "$Z2K_DOH_TEST_DB"
z2k_ow_doh_install || _t_bad "package defaults can be installed with z2kOW"
uci set "https-dns-proxy.@https-dns-proxy[0].resolver_url=https://user.example/dns-query"
z2k_ow_doh_uninstall || _t_bad "uninstall detects a user-edited baseline resolver section"
assert_eq "user-edited baseline resolver keeps the optional package" 0 "$(_doh_test_package_installed_rc)"
assert_contains "user-edited baseline resolver value survives uninstall" "$Z2K_DOH_TEST_DB" \
    "https-dns-proxy.@https-dns-proxy[0].resolver_url='https://user.example/dns-query'"

# Failed apk del retains the ownership receipt so uninstall can be retried.
rm -f "$Z2K_DOH_PACKAGE_FILE" "$T/state/.doh-package-owned" "$T/state/.doh-uci-owned" \
    "$T/state/.doh-install-snapshot" "$T/state/.doh-main-snapshot"
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\n" >> "$Z2K_DOH_TEST_DB"
z2k_ow_doh_install || _t_bad "owned package can be installed before deletion failure"
: > "$Z2K_DOH_APK_DEL_FAIL_FILE"
if z2k_ow_doh_uninstall >/dev/null 2>&1; then
    _t_bad "apk del failure is reported to the caller"
else
    _t_ok
fi
assert_file "apk del failure retains package ownership" "$T/state/.doh-package-owned"
assert_file "apk del failure retains baseline snapshot for retry" "$T/state/.doh-install-snapshot"
assert_eq "failed apk del leaves package installed" 0 "$(_doh_test_package_installed_rc)"
rm -f "$Z2K_DOH_APK_DEL_FAIL_FILE"
z2k_ow_doh_uninstall || _t_bad "owned package uninstall succeeds after apk recovers"
assert_eq "retry removes owned package" 1 "$(_doh_test_package_installed_rc)"

# A collision discovered after apk add must remain external, while the package
# that this failed attempt installed remains removable by its ownership marker.
rm -f "$Z2K_DOH_PACKAGE_FILE"
rm -f "$T/state/.doh-package-owned" "$T/state/.doh-uci-owned" \
    "$T/state/.doh-install-snapshot" "$T/state/.doh-main-snapshot"
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\nhttps-dns-proxy.z2kow_doh='https-dns-proxy'\nhttps-dns-proxy.z2kow_doh.resolver_url='https://outside.example/dns-query'\n" \
    >> "$Z2K_DOH_TEST_DB"
if z2k_ow_doh_install >/dev/null 2>&1; then
    _t_bad "install refuses an existing unowned Xbox resolver section"
else
    _t_ok
fi
assert_file "failed package install keeps a cleanup ownership marker" "$T/state/.doh-package-owned"
assert_eq "unowned collision is reported without being relabeled" "resolver-section-not-owned" \
    "$(z2k_ow_doh_status | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
z2k_ow_doh_uninstall || _t_bad "failed install can remove its owned optional package"
assert_contains "failed install cleanup preserves the pre-existing foreign Xbox section" \
    "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://outside.example/dns-query'"
assert_eq "failed owned package is removed cleanly" 1 "$(test -f "$Z2K_DOH_PACKAGE_FILE"; echo $?)"
assert_not_contains "failed install clears only its own package marker" "$T/state/.doh-package-owned" .

_t_done
