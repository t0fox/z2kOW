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
cat > "$T/bin/paste" <<'STUB'
#!/bin/sh
echo "paste intentionally unavailable in OpenWrt base system" >&2
exit 127
STUB
chmod 0755 "$T/bin/paste"
export Z2K_STATE="$T/state" Z2K_ROOT="$REPO"
export Z2K_DOH_UCI_BIN=uci Z2K_DOH_APK_BIN=apk
export Z2K_DOH_PROXY_INIT="$T/https-dns-proxy.init"
export Z2K_DOH_DNSMASQ_INIT="$T/dnsmasq.init"
export Z2K_DOH_PROC_NET_UDP_FILE="$T/net-udp"
export Z2K_DOH_TEST_DB="$T/uci.db" Z2K_DOH_TEST_LOG="$T/calls.log"
export Z2K_DOH_CONFIG_FILE="$T/https-dns-proxy.config"
export Z2K_DOH_PACKAGE_FILE="$T/package-installed"
export Z2K_DOH_RUNNING_FILE="$T/proxy-running"
export Z2K_DOH_ENABLED_FILE="$T/service-enabled"
export Z2K_DOH_DNSMASQ_RUNNING_FILE="$T/dnsmasq-running"
export Z2K_DOH_DNSMASQ_RUNTIME_DIR="$T/dnsmasq-runtime"
export Z2K_DOH_LOOKUP_FILE="$T/lookup-result"
export Z2K_DOH_LISTENER_FILE="$T/listener-ready"
export Z2K_DOH_TEST_INIT_ENABLED="$T/init-enabled-before"
export Z2K_DOH_TEST_INIT_RUNNING="$T/init-running-before"
export Z2K_DOH_APK_DEL_FAIL_FILE="$T/apk-del-fail"
export Z2K_DOH_START_MODE_FILE="$T/start-mode"
export Z2K_DOH_DELAY_LISTENER_FILE="$T/delay-listener-polls"
export Z2K_DOH_READY_POLL_FILE="$T/ready-polls"
export Z2K_DOH_QUERY_FAIL_FILE="$T/query-fail-count"
export Z2K_DOH_FAIL_ENDPOINT_FILE="$T/fail-endpoint"
export Z2K_DOH_DNSMASQ_FAIL_COUNT_FILE="$T/dnsmasq-fail-count"
export Z2K_DOH_READY_TIMEOUT=3
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
        awk -F= -v k="$key" '$1 == k { v=substr($0,index($0,"=")+1); gsub(/^\047|\047$/, "", v); print v; found=1 } END { if (!found) exit 1 }' "$Z2K_DOH_TEST_DB"
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
        case "$key" in
            https-dns-proxy.@https-dns-proxy\[*\])
                remove_index=$(printf '%s\n' "$key" | sed 's/.*\[\([0-9][0-9]*\)\]$/\1/')
                awk -F= -v k="$key" -v p='https-dns-proxy.@https-dns-proxy[' -v removed="$remove_index" '
                    {
                        name=$1; value=substr($0,index($0,"=")+1)
                        if (name == k || index(name,k ".") == 1) next
                        if (index(name,p) == 1) {
                            suffix=substr(name,length(p)+1); bracket_pos=index(suffix,"]")
                            index_value=substr(suffix,1,bracket_pos-1)
                            if (index_value ~ /^[0-9]+$/ && index_value > removed)
                                name=p (index_value-1) substr(suffix,bracket_pos)
                        }
                        print name "=" value
                    }
                ' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
                ;;
            *)
                awk -F= -v k="$key" '$1 != k && index($1,k ".") != 1' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
                ;;
        esac
        mv "$Z2K_DOH_TEST_DB.new" "$Z2K_DOH_TEST_DB"
        ;;
    export)
        target=$1
        grep -E "^${target}\." "$Z2K_DOH_TEST_DB" || true
        ;;
    import)
        target=$1
        cat > "$Z2K_DOH_TEST_DB.import"
        awk -v p="${target}." 'index($1,p)!=1' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_TEST_DB.new" || exit 1
        cat "$Z2K_DOH_TEST_DB.import" >> "$Z2K_DOH_TEST_DB.new"
        mv "$Z2K_DOH_TEST_DB.new" "$Z2K_DOH_TEST_DB"
        rm -f "$Z2K_DOH_TEST_DB.import"
        ;;
    commit)
        target=$1
        [ "$target" = https-dns-proxy ] || exit 0
        grep -E '^https-dns-proxy\.' "$Z2K_DOH_TEST_DB" > "$Z2K_DOH_CONFIG_FILE" || : > "$Z2K_DOH_CONFIG_FILE"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/apk" <<'STUB'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "$1 $2" in
    'info -e') [ -f "$Z2K_DOH_PACKAGE_FILE" ] ;;
    'add https-dns-proxy')
        printf 'installed\n' > "$Z2K_DOH_PACKAGE_FILE"
        # Match the package's shipped UCI layout: "config main 'config'"
        # appears in uci show as section "config" with type "main".
        if ! grep -q "^https-dns-proxy.config='" "$Z2K_DOH_TEST_DB"; then
            printf "https-dns-proxy.config='main'\nhttps-dns-proxy.config.canary_domains_icloud='1'\nhttps-dns-proxy.config.canary_domains_mozilla='1'\nhttps-dns-proxy.config.dnsmasq_config_update='*'\nhttps-dns-proxy.config.force_dns='1'\nhttps-dns-proxy.config.notrack_dns='1'\nhttps-dns-proxy.config.force_dns_port='53'\nhttps-dns-proxy.config.force_dns_port='853'\nhttps-dns-proxy.config.force_dns_src_interface='lan'\nhttps-dns-proxy.config.procd_trigger_wan6='0'\nhttps-dns-proxy.config.heartbeat_domain='heartbeat.mossdef.org'\nhttps-dns-proxy.config.heartbeat_sleep_timeout='10'\nhttps-dns-proxy.config.heartbeat_wait_timeout='10'\nhttps-dns-proxy.config.user='nobody'\nhttps-dns-proxy.config.group='nogroup'\nhttps-dns-proxy.config.listen_addr='127.0.0.1'\nhttps-dns-proxy.config.force_ip_family='auto'\nhttps-dns-proxy.@https-dns-proxy[0]='https-dns-proxy'\nhttps-dns-proxy.@https-dns-proxy[0].resolver_url='https://cloudflare-dns.com/dns-query'\nhttps-dns-proxy.@https-dns-proxy[0].bootstrap_dns='1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001'\nhttps-dns-proxy.@https-dns-proxy[0].listen_port='5053'\nhttps-dns-proxy.@https-dns-proxy[1]='https-dns-proxy'\nhttps-dns-proxy.@https-dns-proxy[1].resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.@https-dns-proxy[1].bootstrap_dns='8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844'\nhttps-dns-proxy.@https-dns-proxy[1].listen_port='5054'\n" >> "$Z2K_DOH_TEST_DB"
        fi
        uci -q commit https-dns-proxy
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
    restart|start|reload) : > "$Z2K_DOH_RUNNING_FILE" ;;
    stop)
        rm -f "$Z2K_DOH_RUNNING_FILE"
        ;;
    status) [ -f "$Z2K_DOH_RUNNING_FILE" ] ;;
    *) exit 2 ;;
esac
STUB
cat > "$Z2K_DOH_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ "${1:-}" = restart ] || exit 1
if [ -f "$Z2K_DOH_DNSMASQ_FAIL_COUNT_FILE" ]; then
    _remaining=$(cat "$Z2K_DOH_DNSMASQ_FAIL_COUNT_FILE" 2>/dev/null); _remaining=${_remaining:-0}
    if [ "$_remaining" -gt 0 ]; then
        printf '%s\n' "$((_remaining - 1))" > "$Z2K_DOH_DNSMASQ_FAIL_COUNT_FILE"
        printf 'dnsmasq restart failed by test fixture\n' >&2
        exit 1
    fi
fi
if [ "${Z2K_DOH_EMIT_UDHCPC_WARNING:-0}" = 1 ]; then
    printf 'udhcpc: started, v1.37.0\nudhcpc: broadcasting discover\nudhcpc: no lease, failing\n' >&2
fi
mkdir -p "$Z2K_DOH_DNSMASQ_RUNTIME_DIR"
{
    if [ -f "$Z2K_DOH_PACKAGE_FILE" ]; then
        awk -F= '$1 ~ /^https-dns-proxy\..+\.listen_port$/ { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value); print "server=127.0.0.1#" value }' "$Z2K_DOH_TEST_DB"
    fi
} > "$Z2K_DOH_DNSMASQ_RUNTIME_DIR/dnsmasq.conf.fixture"
if [ -n "${Z2K_TIKTOK_EFFECTIVE_CONFIG:-}" ]; then
    awk -F= '$1 ~ /\.address$/ { value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value); print "address=" value }' \
        "$Z2K_DOH_TEST_DB" > "$Z2K_TIKTOK_EFFECTIVE_CONFIG"
fi
STUB
cat > "$T/bin/pidof" <<'STUB'
#!/bin/sh
case "$1" in
    https-dns-proxy)
        if [ -f "$Z2K_DOH_RUNNING_FILE" ]; then echo 123; exit 0; fi
        exit 1
        ;;
    dnsmasq)
        if [ -f "$Z2K_DOH_DNSMASQ_RUNNING_FILE" ]; then echo 456; exit 0; fi
        exit 1
        ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf 'nslookup %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
host=${1:-}; server=${2:-}
[ -n "$host" ] && [ "$server" = 127.0.0.1 ] || exit 2
[ -f "$Z2K_DOH_DNSMASQ_RUNNING_FILE" ] || exit 1
answer=$(cat "$Z2K_DOH_LOOKUP_FILE" 2>/dev/null)
[ -n "$answer" ] || { echo 'router DNS lookup failed' >&2; exit 1; }
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
    printf 'server=/#/127.0.0.1#%s\n' "$_upstream_port" > "$T/dnsmasq-real.conf"
    awk -F= '
        $1 ~ /^dhcp\.[^.]+\.address$/ {
            value=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",value)
            n=split(value,a,/[[:space:]]+/)
            for(i=1;i<=n;i++) if(a[i] ~ /^\/v77\.tiktokcdn(-eu)?\.com\//) print "address=" a[i]
        }
    ' "$Z2K_DOH_TEST_DB" | sed "s/#$_resolver_port/#$_upstream_port/" >> "$T/dnsmasq-real.conf"
    assert_contains "real dnsmasq fixture models the package catch-all route" "$T/dnsmasq-real.conf" "server=/#/127.0.0.1#$_upstream_port"
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
_doh_field() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}
_doh_config_value() { uci -q get "https-dns-proxy.$1" 2>/dev/null; }

_status=$(z2k_ow_doh_status)
printf '%s\n' "$_status" > "$T/status"
assert_contains "absent component is explicit" "$T/status" 'state=not-installed'

# Install only adds the package. It does not create resolver config, enable the
# service, restart DNS, or run a provider health check.
: > "$Z2K_DOH_TEST_LOG"
if z2k_ow_doh_install >"$T/install.stdout" 2>"$T/install.stderr"; then _t_ok
else _t_bad "install succeeds independently of provider availability"; fi
assert_file "APK package ownership is recorded for a newly installed package" "$T/state/.doh-package-owned"
assert_contains "install added only the https-dns-proxy package" "$Z2K_DOH_TEST_LOG" 'apk add https-dns-proxy'
assert_not_contains "install does not start the resolver service" "$Z2K_DOH_TEST_LOG" '^proxy (enable|restart|start|reload)'
assert_not_contains "install does not restart dnsmasq" "$Z2K_DOH_TEST_LOG" '^dnsmasq restart$'
assert_not_contains "install does not perform network health checks" "$Z2K_DOH_TEST_LOG" '^nslookup '
assert_eq "install leaves the resolver service stopped" 1 "$(test -f "$Z2K_DOH_RUNNING_FILE"; echo $?)"
assert_eq "fresh package config is detected from its actual resolver URLs" default "$(_doh_field "$(z2k_ow_doh_status)" provider)"
assert_eq "installed but stopped package reports disabled" disabled "$(_doh_field "$(z2k_ow_doh_status)" state)"

# Applying a provider uses standard package UCI sections. The package itself
# routes dnsmasq; z2kOW never writes a parallel hand-built DHCP route.
uci add_list 'dhcp.@dnsmasq[0].server=1.1.1.1'
uci add_list 'dhcp.@dnsmasq[0].address=/v77.tiktokcdn.com/87.245.200.35'
uci add_list 'dhcp.@dnsmasq[0].address=/v77.tiktokcdn-eu.com/87.245.200.35'
: > "$Z2K_DOH_TEST_LOG"
z2k_ow_doh_select_provider xbox || _t_bad "apply replaces fresh package defaults with Xbox DNS"
assert_eq "provider is detected from the active resolver_url" xbox "$(_doh_field "$(z2k_ow_doh_status)" provider)"
assert_eq "Xbox endpoint is generated as standard UCI" 'https://xbox-dns.ru/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"
assert_not_contains "apply removes both anonymous package default resolvers after UCI index shifts" \
    "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.@https-dns-proxy\[[0-9]+\]\.resolver_url='
assert_eq "single resolver listens on the package default loopback port" 5053 "$(_doh_config_value z2kow_doh.listen_port)"
assert_contains "apply restarts https-dns-proxy" "$Z2K_DOH_TEST_LOG" 'proxy restart'
assert_eq "apply performs one package service reload/restart" 1 "$(grep -Ec '^proxy (reload|restart)$' "$Z2K_DOH_TEST_LOG")"
assert_contains "apply restarts dnsmasq" "$Z2K_DOH_TEST_LOG" 'dnsmasq restart'
assert_not_contains "apply does not gate success on a network lookup" "$Z2K_DOH_TEST_LOG" '^nslookup '
assert_eq "resolver apply preserves upstream DNS" 1.1.1.1 "$(uci -q get 'dhcp.@dnsmasq[0].server')"
assert_contains "resolver apply preserves the TikTok primary override" "$Z2K_DOH_TEST_DB" '/v77.tiktokcdn.com/87.245.200.35'
assert_contains "resolver apply preserves the TikTok EU override" "$Z2K_DOH_TEST_DB" '/v77.tiktokcdn-eu.com/87.245.200.35'
assert_eq "the package-managed dnsmasq integration remains enabled" '*' "$(_doh_config_value config.dnsmasq_config_update)"
assert_eq "working status comes from the running proxy process and actual UCI config" working "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "DoH status exposes a running proxy as available to diagnostics" available "$(_doh_field "$(z2k_ow_doh_status)" proxy)"
assert_eq "DoH status exposes the active dnsmasq listener route to diagnostics" available "$(_doh_field "$(z2k_ow_doh_status)" dnsmasq)"
mv "$Z2K_DOH_DNSMASQ_RUNTIME_DIR/dnsmasq.conf.fixture" "$T/dnsmasq.conf.saved"
assert_eq "missing runtime dnsmasq route is visible to diagnostics" route-missing "$(_doh_field "$(z2k_ow_doh_status)" dnsmasq)"
assert_eq "missing runtime dnsmasq route is not reported as working" error "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "missing runtime dnsmasq route has a specific status reason" dnsmasq-listener-route-missing "$(_doh_field "$(z2k_ow_doh_status)" reason)"
mv "$T/dnsmasq.conf.saved" "$Z2K_DOH_DNSMASQ_RUNTIME_DIR/dnsmasq.conf.fixture"
: > "$Z2K_DOH_ENABLED_FILE"
rm -f "$Z2K_DOH_RUNNING_FILE"
assert_eq "enabled resolver with a stopped proxy reports an error, not disabled" error "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "stopped enabled proxy has an actionable reason" proxy-not-running "$(_doh_field "$(z2k_ow_doh_status)" reason)"
assert_eq "DoH status marks a stopped proxy unavailable to diagnostics" unavailable "$(_doh_field "$(z2k_ow_doh_status)" proxy)"
: > "$Z2K_DOH_RUNNING_FILE"

# Every StressOzz preset is represented as endpoint/bootstrap data. Applying
# any preset is a config/restart operation, not an inline health transaction.
while IFS='|' read -r _provider _label _endpoint _bootstrap; do
    [ -n "$_provider" ] || continue
    : > "$Z2K_DOH_TEST_LOG"
    z2k_ow_doh_select_provider "$_provider" || _t_bad "preset $_provider applies"
    assert_eq "preset $_provider is detected from resolver URL" "$_provider" "$(_doh_field "$(z2k_ow_doh_status)" provider)"
    assert_not_contains "preset $_provider applies without DNS health gating" "$Z2K_DOH_TEST_LOG" '^nslookup '
    case "$_provider" in
        default)
            assert_eq "default profile writes Cloudflare as resolver one" 'https://cloudflare-dns.com/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"
            assert_eq "default profile writes Google as resolver two" 'https://dns.google/dns-query' "$(_doh_config_value z2kow_doh_1.resolver_url)"
            assert_eq "default profile uses two standard listener ports" 5054 "$(_doh_config_value z2kow_doh_1.listen_port)"
            ;;
        *)
            assert_eq "preset $_provider writes its canonical endpoint" "$_endpoint" "$(_doh_config_value z2kow_doh.resolver_url)"
            if [ -n "$_bootstrap" ]; then
                assert_eq "preset $_provider writes its bootstrap resolver list" "$_bootstrap" "$(_doh_config_value z2kow_doh.bootstrap_dns)"
            else
                assert_eq "preset $_provider omits an unnecessary per-resolver bootstrap override" '' "$(_doh_config_value z2kow_doh.bootstrap_dns)"
            fi
            assert_eq "single preset $_provider removes the second z2k resolver" 1 "$(uci -q get https-dns-proxy.z2kow_doh_1 >/dev/null 2>&1; echo $?)"
            ;;
    esac
done <<'PRESETS'
xbox|Xbox DNS|https://xbox-dns.ru/dns-query|
comss|Comss|https://dns.comss.one/dns-query|92.38.152.163,93.115.24.204,2a03:90c0:56::1a5,2a02:7b40:5eb0:e95d::1
google|Google|https://dns.google/dns-query|8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844
quad9|Quad9|https://dns.quad9.net/dns-query|9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9
xyz|XyZ DNS|https://dns.yo1nk.app/dns-query|
geohide_ru|GeoHide RU|https://geohide.ru/dns-query|
geohide_eu|GeoHide EU|https://eu.geohide.ru/dns-query|
geohide_us|GeoHide US|https://us.geohide.ru/dns-query|
cloudflare|Cloudflare|https://cloudflare-dns.com/dns-query|1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001
dns_ai|dns.dns-ai.ru|https://dns.dns-ai.ru/dns-query|
malw|dns.malw.link|https://dns.malw.link/dns-query|
astracat|dns.astracat.ru|https://dns.astracat.ru/dns-query|
mafioznik|dns.mafioznik.xyz|https://dns.mafioznik.xyz/dns-query|
malw_cloudflare|dns.malw.link Cloudflare Gateway|https://5u35p8m9i7.cloudflare-gateway.com/dns-query|
nullsproxy|dns.nullsproxy.com|https://dns.nullsproxy.com/dns-query|
default|Cloudflare + Google|https://cloudflare-dns.com/dns-query,https://dns.google/dns-query|
PRESETS

z2k_ow_doh_select_provider custom 'https://resolver.example/dns-query' '1.1.1.1,2606:4700:4700::1111' \
    || _t_bad "custom provider accepts a valid IPv4/IPv6 bootstrap list"
assert_eq "custom provider endpoint is detected from active UCI" custom "$(_doh_field "$(z2k_ow_doh_status)" provider)"
assert_eq "custom provider endpoint is stored in package UCI" 'https://resolver.example/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"
if z2k_ow_doh_select_provider custom 'http://resolver.example/dns-query' '1.1.1.1'; then
    _t_bad "custom provider rejects non-HTTPS URLs"
else
    _t_ok
fi

# The package's global policy is not rewritten from provider presets. Existing
# package defaults and user choices remain authoritative; the separate force
# DNS toggle changes only force_dns.
assert_eq "apply preserves dnsmasq_config_update package behavior" '*' "$(_doh_config_value config.dnsmasq_config_update)"
assert_eq "apply preserves force_dns package default" 1 "$(_doh_config_value config.force_dns)"
assert_eq "apply preserves notrack_dns package default" 1 "$(_doh_config_value config.notrack_dns)"
assert_eq "apply preserves package force DNS ports 53 and 853" '53,853' "$(uci -q get 'https-dns-proxy.config.force_dns_port' | tr '\n' ',' | sed 's/,$//')"
assert_eq "apply preserves the LAN force-DNS source" lan "$(_doh_config_value 'config.force_dns_src_interface')"
assert_eq "apply preserves the package loopback listen address" 127.0.0.1 "$(_doh_config_value config.listen_addr)"
z2k_ow_doh_set_force_dns 0 || _t_bad "force DNS toggle updates only the package main section"
assert_eq "force DNS toggle is reflected from UCI" 0 "$(_doh_field "$(z2k_ow_doh_status)" force_lan_dns)"
assert_eq "force DNS toggle leaves provider URL untouched" 'https://resolver.example/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"

# Check is a standalone diagnostic. Failure reports an error but leaves the
# package, service config, and selected provider in place.
: > "$Z2K_DOH_LOOKUP_FILE"
if z2k_ow_doh_check >"$T/check-fail.stdout" 2>"$T/check-fail.stderr"; then
    _t_bad "check reports a failed router DNS query"
else
    _t_ok
fi
assert_file "failed Check keeps the installed package" "$T/package-installed"
assert_eq "failed Check keeps the active custom resolver" 'https://resolver.example/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"
assert_eq "failed Check does not change service/config status" working "$(_doh_field "$(z2k_ow_doh_status)" state)"
printf '203.0.113.8\n' > "$Z2K_DOH_LOOKUP_FILE"
: > "$Z2K_DOH_RUNNING_FILE"
: > "$Z2K_DOH_ENABLED_FILE"
z2k_ow_doh_check >/dev/null || _t_bad "Check succeeds when service and dnsmasq return an answer"
assert_eq "successful Check does not write a duplicate provider flag" 1 "$(test -f "$T/state/doh.provider"; echo $?)"
: > "$Z2K_DOH_TEST_LOG"
if env -u Z2K_DOH_NSLOOKUP_BIN -u Z2K_DOH_HEALTH_HOST sh -uc '. "$Z2K_ROOT/platform/openwrt/doh.sh"; z2k_ow_doh_check' \
    >"$T/check-nounset.stdout" 2>"$T/check-nounset.stderr"; then
    _t_ok
else
    _t_bad "Check works under set -u without optional test overrides"
fi
assert_contains "nounset-safe Check reaches the default nslookup command" "$Z2K_DOH_TEST_LOG" 'nslookup example.com 127.0.0.1'
assert_contains "Check diagnostics name the detected provider and endpoint" "$T/check-nounset.stdout" 'provider=custom endpoint=https://resolver.example/dns-query'
assert_contains "Check diagnostics include the returned DNS answer" "$T/check-nounset.stdout" 'answer=203.0.113.8'
assert_contains "Check diagnostics report success" "$T/check-nounset.stdout" 'result=success'
Z2K_DOH_EMIT_UDHCPC_WARNING=1 z2k_ow_doh_restart > "$T/restart-filtered.stdout" 2>&1 \
    || _t_bad "dnsmasq restart succeeds while OpenWrt performs its one-shot DHCP probe"
assert_not_contains "successful DoH restart omits only harmless dnsmasq udhcpc probe chatter" \
    "$T/restart-filtered.stdout" 'udhcpc:'
assert_contains "DHCP probe filtering does not skip the dnsmasq restart" "$Z2K_DOH_TEST_LOG" 'dnsmasq restart'

# Real dnsmasq reads the package-managed route and continues to serve the
# TikTok local address overrides alongside the DoH catch-all.
_external_port=$(_doh_config_value z2kow_doh.listen_port)
_doh_test_real_dnsmasq_tiktok "$_external_port"

# A user-owned package/config is never overwritten by install. Apply requires
# explicit replacement confirmation, snapshots the original config, and Remove
# deletes the package after a second explicit confirmation while restoring the
# user's UCI file for a later reimport.
rm -f "$T/package-installed" "$T/state/.doh-package-owned" "$T/state/.doh-uci-owned" \
    "$T/state/.doh-config-backup" "$T/state/.doh-config-baseline" "$T/state/.doh-service-snapshot"
rm -f "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\ndhcp.@dnsmasq[0].noresolv='1'\ndhcp.@dnsmasq[0].server='/mask.icloud.com/'\ndhcp.@dnsmasq[0].server='/mask-h2.icloud.com/'\ndhcp.@dnsmasq[0].server='/use-application-dns.net/'\ndhcp.@dnsmasq[0].server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].server='127.0.0.1#5054'\ndhcp.@dnsmasq[0].doh_backup_noresolv='-1'\ndhcp.@dnsmasq[0].doh_backup_server='/mask.icloud.com/'\ndhcp.@dnsmasq[0].doh_backup_server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_backup_server='127.0.0.1#5054'\ndhcp.@dnsmasq[0].doh_server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_server='127.0.0.1#5054'\ndhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/87.245.200.35'\nhttps-dns-proxy.config='main'\nhttps-dns-proxy.config.force_dns='0'\nhttps-dns-proxy.config.dnsmasq_config_update='*'\nhttps-dns-proxy.config.custom_marker='preserve-me'\nhttps-dns-proxy.outside='https-dns-proxy'\nhttps-dns-proxy.outside.resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.outside.bootstrap_dns='8.8.8.8,8.8.4.4'\nhttps-dns-proxy.outside.listen_port='5054'\n" > "$Z2K_DOH_TEST_DB"
printf 'installed\n' > "$Z2K_DOH_PACKAGE_FILE"
: > "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_RUNNING_FILE"
uci commit https-dns-proxy
cp "$Z2K_DOH_CONFIG_FILE" "$T/external-original"
: > "$Z2K_DOH_TEST_LOG"
z2k_ow_doh_install || _t_bad "install recognizes and preserves an already-installed package"
assert_not_contains "external-package install does not call apk add" "$Z2K_DOH_TEST_LOG" '^apk add '
assert_eq "existing configured provider is detected by URL" google "$(_doh_field "$(z2k_ow_doh_status)" provider)"
assert_eq "pre-existing config is flagged for explicit confirmation" 1 "$(_doh_field "$(z2k_ow_doh_status)" external_config)"
cp "$Z2K_DOH_TEST_DB" "$T/external-before-apply"
if z2k_ow_doh_select_provider xbox; then
    _t_bad "apply refuses to silently replace an external resolver configuration"
else
    _t_ok
fi
cmp -s "$T/external-before-apply" "$Z2K_DOH_TEST_DB" && _t_ok || _t_bad "refused apply leaves external UCI untouched"
z2k_ow_doh_select_provider xbox '' '' 1 || _t_bad "explicitly confirmed apply takes a reversible UCI snapshot"
assert_file "confirmed replacement saves the original package config" "$T/state/.doh-config-backup"
assert_eq "confirmed apply installs the selected resolver" 'https://xbox-dns.ru/dns-query' "$(_doh_config_value z2kow_doh.resolver_url)"
assert_not_contains "confirmed apply removes the replaced external resolver" "$Z2K_DOH_TEST_DB" '^https-dns-proxy\.outside='
assert_contains "confirmed apply leaves unrelated package main values in place" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.custom_marker='preserve-me'"
if z2k_ow_doh_uninstall; then
    _t_bad "Remove requires explicit confirmation before deleting an external package"
else
    _t_ok
fi
assert_file "unconfirmed Remove leaves the external package installed" "$Z2K_DOH_PACKAGE_FILE"
z2k_ow_doh_uninstall 1 || _t_bad "confirmed Remove deletes the external package and restores its config"
cmp -s "$T/external-original" "$Z2K_DOH_CONFIG_FILE" && _t_ok || _t_bad "Remove restores the original https-dns-proxy config"
assert_contains "restored UCI keeps the user's resolver section" "$Z2K_DOH_TEST_DB" "https-dns-proxy.outside.resolver_url='https://dns.google/dns-query'"
assert_contains "restored UCI keeps unrelated package main settings" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.custom_marker='preserve-me'"
assert_not_contains "Remove removes the active route to the new listener" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
assert_not_contains "Remove removes the restored user's route to its old listener" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5054'"
assert_not_contains "Remove removes legacy DoH route markers for deleted listeners" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].doh_server='127.0.0.1#5053'"
assert_not_contains "Remove removes legacy backup routes for deleted listeners" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].doh_backup_server='127.0.0.1#5054'"
assert_not_contains "Remove restores dnsmasq noresolv to its pre-DoH default" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].noresolv='1'"
assert_not_contains "Remove consumes the legacy noresolv backup marker" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].doh_backup_noresolv="
assert_contains "Remove preserves unrelated encrypted-DNS canary routing" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/mask.icloud.com/'"
assert_contains "Remove preserves the TikTok local DNS override" "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/87.245.200.35'"
assert_not_contains "confirmed Remove deletes the external package" "$Z2K_DOH_PACKAGE_FILE" 'installed'
assert_eq "Remove disables the service rather than restoring it" 1 "$(test -f "$Z2K_DOH_ENABLED_FILE"; echo $?)"
assert_eq "Remove stops the service rather than restoring it" 1 "$(test -f "$Z2K_DOH_RUNNING_FILE"; echo $?)"
assert_eq "Remove refreshes DoH status to not installed" not-installed "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_not_contains "Remove clears package-generated dnsmasq listener routes" "$Z2K_DOH_DNSMASQ_RUNTIME_DIR/dnsmasq.conf.fixture" '127.0.0.1#505[34]'
nslookup example.com 127.0.0.1 >/dev/null || _t_bad "router DNS remains available after DoH removal"

# Remove means package removal even if there was no z2kOW resolver receipt;
# the user's package config is left in UCI for reimport.
rm -f "$T/state/.doh-uci-owned" "$T/state/.doh-config-backup"
printf 'installed\n' > "$Z2K_DOH_PACKAGE_FILE"
: > "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_RUNNING_FILE"
z2k_ow_doh_uninstall 1 || _t_bad "confirmed Remove deletes an external-only package"
assert_contains "external-only UCI remains available after Remove" "$Z2K_DOH_TEST_DB" "https-dns-proxy.outside.resolver_url='https://dns.google/dns-query'"
assert_not_contains "external-only package is actually deleted" "$Z2K_DOH_PACKAGE_FILE" 'installed'

# A stale https-dns-proxy UCI file can exist even when the package is absent.
# Installation must preserve and flag it; Remove restores it after deleting
# the package z2kOW added.
rm -f "$Z2K_DOH_PACKAGE_FILE" "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_ENABLED_FILE"
rm -f "$T/state"/.doh-* "$T/state"/doh.*
: > "$Z2K_DOH_TEST_DB"
printf "https-dns-proxy.config='main'\nhttps-dns-proxy.config.custom_marker='before-install'\nhttps-dns-proxy.outside='https-dns-proxy'\nhttps-dns-proxy.outside.resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.outside.listen_port='5053'\n" > "$Z2K_DOH_TEST_DB"
uci commit https-dns-proxy
cp "$Z2K_DOH_CONFIG_FILE" "$T/preinstall-config"
z2k_ow_doh_install || _t_bad "package installs when an https-dns-proxy UCI file already exists"
assert_contains "pre-install config receipt is non-empty" "$T/state/.doh-preinstall-config-present" '1'
assert_eq "pre-install UCI is reported as external and requires confirmation" 1 "$(_doh_field "$(z2k_ow_doh_status)" external_config)"
# Preserve edits made while the package was installed but before z2kOW first
# takes ownership; the apply-time backup is the exact state Remove must restore.
uci set https-dns-proxy.config.custom_marker=edited-after-install
uci set https-dns-proxy.outside.resolver_url=https://dns.quad9.net/dns-query
uci commit https-dns-proxy
cp "$Z2K_DOH_TEST_DB" "$T/preinstall-before-apply"
if z2k_ow_doh_select_provider xbox; then
    _t_bad "pre-install UCI is not silently overwritten"
else
    _t_ok
fi
cmp -s "$T/preinstall-before-apply" "$Z2K_DOH_TEST_DB" && _t_ok || _t_bad "refused apply leaves pre-install UCI untouched"
cp "$Z2K_DOH_CONFIG_FILE" "$T/preapply-config"
z2k_ow_doh_select_provider xbox '' '' 1 || _t_bad "confirmed apply snapshots the latest pre-replacement UCI"
z2k_ow_doh_uninstall 1 || _t_bad "Remove deletes the package z2kOW installed while restoring pre-install UCI"
assert_not_contains "Remove deletes the z2kOW-installed package" "$Z2K_DOH_PACKAGE_FILE" 'installed'
cmp -s "$T/preapply-config" "$Z2K_DOH_CONFIG_FILE" && _t_ok || {
    diff -u "$T/preapply-config" "$Z2K_DOH_CONFIG_FILE" >&2 || true
    _t_bad "Remove restores the latest config before replacement"
}
assert_contains "restored config retains edits made after package installation" "$Z2K_DOH_TEST_DB" "https-dns-proxy.config.custom_marker='edited-after-install'"
assert_contains "restored config retains the latest user resolver" "$Z2K_DOH_TEST_DB" "https-dns-proxy.outside.resolver_url='https://dns.quad9.net/dns-query'"

# Removing a z2kOW resolver from a pre-existing package restores the exact
# user's main-only config while deleting the confirmed package.
rm -f "$T/state"/.doh-* "$T/state"/doh.* "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_TEST_DB"
printf "https-dns-proxy.config='main'\nhttps-dns-proxy.config.custom_marker='user-main-only'\n" > "$Z2K_DOH_TEST_DB"
printf 'installed\n' > "$Z2K_DOH_PACKAGE_FILE"
uci commit https-dns-proxy
cp "$Z2K_DOH_CONFIG_FILE" "$T/main-only-before-apply"
z2k_ow_doh_install || _t_bad "already-installed package accepts DoH management without reinstalling"
assert_eq "main-only pre-existing UCI is treated as user-owned before Apply" 1 "$(_doh_field "$(z2k_ow_doh_status)" external_config)"
z2k_ow_doh_select_provider xbox '' '' 1 || _t_bad "Apply replaces a confirmed main-only config with an active resolver"
assert_eq "Apply makes the selected resolver active" working "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "Apply clears external ownership once its resolver is active" 0 "$(_doh_field "$(z2k_ow_doh_status)" external_config)"
printf 'preexisting_config=1\n' > "$Z2K_DOH_INSTALL_SNAPSHOT"
z2k_ow_doh_uninstall 1 > "$T/remove-main-only.stdout" || _t_bad "Remove restores a main-only user config and deletes the package"
assert_contains "Remove explains that the external resolver config was preserved" "$T/remove-main-only.stdout" 'пользовательская конфигурация https-dns-proxy сохранена'
[ ! -e "$Z2K_DOH_INSTALL_SNAPSHOT" ] && _t_ok || _t_bad "Remove cleans the stale package install receipt"
cmp -s "$T/main-only-before-apply" "$Z2K_DOH_CONFIG_FILE" && _t_ok || _t_bad "Remove restores the main-only UCI exactly"
assert_not_contains "Remove deletes the package installed before z2kOW" "$Z2K_DOH_PACKAGE_FILE" 'installed'
assert_eq "restored main-only config reports DoH as not installed" not-installed "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "restored UCI remains available for later package reimport" 0 "$(test -s "$Z2K_DOH_CONFIG_FILE"; echo $?)"

# Package-delete command failures must be visible to the async job and retain
# enough ownership state for the user to retry.
rm -f "$T/state"/.doh-* "$T/state"/doh.* "$Z2K_DOH_PACKAGE_FILE" "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_TEST_DB"
rm -f "$Z2K_DOH_CONFIG_FILE"
z2k_ow_doh_install || _t_bad "install package for failure-gate coverage"
z2k_ow_doh_select_provider xbox || _t_bad "apply resolver for failure-gate coverage"
: > "$Z2K_DOH_APK_DEL_FAIL_FILE"
if z2k_ow_doh_uninstall 1 >"$T/remove-apk-fail.stdout" 2>"$T/remove-apk-fail.stderr"; then
    _t_bad "Remove reports apk del failure"
else
    _t_ok
fi
assert_file "failed apk del keeps package state visible" "$Z2K_DOH_PACKAGE_FILE"
assert_file "failed apk del keeps ownership receipts for retry" "$Z2K_DOH_PACKAGE_OWNED_FILE"
rm -f "$Z2K_DOH_APK_DEL_FAIL_FILE"
z2k_ow_doh_uninstall 1 || _t_bad "Remove can retry after apk del failure"
assert_not_contains "successful retry leaves the package absent" "$Z2K_DOH_PACKAGE_FILE" 'installed'

# Removal is complete once the package, service, and generated listener routes
# are gone. A loopback DNS probe is not a removal prerequisite: after apk del
# this router may not answer on 127.0.0.1:53, which previously turned a
# successful purge into a failed job and left stale ownership receipts behind.
rm -f "$T/state"/.doh-* "$T/state"/doh.* "$Z2K_DOH_PACKAGE_FILE" \
    "$Z2K_DOH_RUNNING_FILE" "$Z2K_DOH_ENABLED_FILE"
: > "$Z2K_DOH_TEST_DB"
rm -f "$Z2K_DOH_CONFIG_FILE"
z2k_ow_doh_install || _t_bad "install package for post-removal DNS failure coverage"
z2k_ow_doh_select_provider xbox || _t_bad "apply resolver for post-removal DNS failure coverage"
: > "$Z2K_DOH_LOOKUP_FILE"
: > "$Z2K_DOH_TEST_LOG"
if z2k_ow_doh_uninstall 1 >"$T/remove-dns-unavailable.stdout" 2>"$T/remove-dns-unavailable.stderr"; then
    _t_ok
else
    _t_bad "Remove succeeds when only the post-removal loopback DNS probe would fail"
fi
assert_not_contains "Remove does not run a loopback health probe after purging the package" \
    "$Z2K_DOH_TEST_LOG" '^nslookup '
assert_not_contains "Remove leaves the package absent after a loopback DNS failure" \
    "$Z2K_DOH_PACKAGE_FILE" 'installed'
assert_eq "Remove reports the package absent after a successful purge" \
    not-installed "$(_doh_field "$(z2k_ow_doh_status)" state)"
assert_eq "uninstalled DoH reports no package owner" \
    none "$(_doh_field "$(z2k_ow_doh_status)" package_owner)"
assert_eq "uninstalled DoH marks proxy status not applicable" \
    not-applicable "$(_doh_field "$(z2k_ow_doh_status)" proxy)"
assert_eq "uninstalled DoH marks dnsmasq status not applicable" \
    not-applicable "$(_doh_field "$(z2k_ow_doh_status)" dnsmasq)"
[ ! -e "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && _t_ok || _t_bad "Remove clears package ownership after successful purge"
[ ! -e "$Z2K_DOH_CONFIG_OWNED_FILE" ] && _t_ok || _t_bad "Remove clears resolver ownership after successful purge"
assert_not_contains "Remove does not claim DNS was verified" "$T/remove-dns-unavailable.stdout" 'DNS работает'

_t_done
