#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan ow-dnsproxy
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ow-dnsproxy.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
assert_path_presence() {
    local _description="$1" _expected="$2" _path="$3" _actual
    if [ -e "$_path" ]; then _actual=0; else _actual=1; fi
    assert_eq "$_description" "$_expected" "$_actual"
}
export T
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH" Z2K_STATE="$T/state" Z2K_ROOT="$REPO" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_DOH_UCI_BIN=uci Z2K_DOH_APK_BIN=apk Z2K_DOH_PIDOF_BIN=pidof
export Z2K_DOH_PROXY_INIT="$T/dnsproxy.init" Z2K_DOH_DNSMASQ_INIT="$T/dnsmasq.init"
export Z2K_DOH_OLD_INIT="$T/https-dns-proxy.init"
export Z2K_DOH_TEST_DB="$T/uci.db" Z2K_DOH_TEST_LOG="$T/calls" Z2K_DOH_PACKAGE_FILE="$T/installed"
export Z2K_DOH_RUNNING_FILE="$T/running" Z2K_DOH_ENABLED_FILE="$T/enabled"
export Z2K_DOH_DRILL_BIN=missing-drill-must-not-be-needed Z2K_DOH_NSLOOKUP_BIN=nslookup
: > "$Z2K_DOH_TEST_DB"
printf "dhcp.@dnsmasq[0]='dnsmasq'\ndhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'\ndhcp.@dnsmasq[0].noresolv='1'\ndhcp.@dnsmasq[0].server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_backup_noresolv='-1'\n" > "$Z2K_DOH_TEST_DB"
printf "network.lan.ipaddr='192.168.1.1'\nfirewall.z2k_unrelated='redirect'\nfirewall.z2k_unrelated.name='leave-alone'\n" >> "$Z2K_DOH_TEST_DB"
printf "https-dns-proxy.z2kow_doh='https-dns-proxy'\nhttps-dns-proxy.z2kow_doh.resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.z2kow_doh.bootstrap_dns='8.8.8.8,8.8.4.4'\n" >> "$Z2K_DOH_TEST_DB"
: > "$T/legacy-installed"
: > "$T/legacy-running"
: > "$T/legacy-enabled"
. "$REPO/platform/openwrt/doh.sh"
printf 'https-dns-proxy\n' > "$Z2K_STATE/.doh-package-owned"
printf 'z2kow_doh\n' > "$Z2K_STATE/.doh-uci-owned"
cat > "$Z2K_DOH_OLD_INIT" <<'STUB'
#!/bin/sh
printf 'legacy %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "${1:-}" in
  enabled) [ -f "$T/legacy-enabled" ] ;;
  enable) printf '1\n' > "$T/legacy-enabled" ;;
  disable) rm -f "$T/legacy-enabled" ;;
  restart|start) printf '1\n' > "$T/legacy-running" ;;
  stop) rm -f "$T/legacy-running"; : > "$T/legacy-stopped"; if [ -f "$T/legacy-stop-readds-route" ]; then printf "dhcp.@dnsmasq[0].server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].server='127.0.0.1#5054'\n" >> "$Z2K_DOH_TEST_DB"; fi ;;
esac
STUB
chmod +x "$Z2K_DOH_OLD_INIT"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
[ "${1:-}" = -q ] && shift
cmd=$1; shift
db=$Z2K_DOH_TEST_DB
case "$cmd" in
  get) awk -F= -v k="$1" '$1==k{v=substr($0,index($0,"=")+1);gsub(/^\047|\047$/,"",v);print v;found=1}END{if(!found)exit 1}' "$db" ;;
  show|export) target=${1:-}; [ -z "$target" ] && { cat "$db"; exit 0; }; if [ "$cmd" = show ] && [ "$target" = dhcp ] && [ -f "$T/aggregate-dhcp-list-values" ]; then awk -F= '{k=$1;v=substr($0,index($0,"=")+1);sub(/^\047/,"",v);sub(/\047$/,"",v);if(!seen[k]++)order[++n]=k;if(count[k]++)values[k]=values[k] " " "\047" v "\047";else values[k]=k "=" "\047" v "\047"}END{for(i=1;i<=n;i++)print values[order[i]]}' "$db"; exit 0; fi; if [ "$cmd" = export ] && [ -s "$T/uci-export-$target" ]; then cat "$T/uci-export-$target"; exit 0; fi; grep -E "^${target}\." "$db" || : ;;
  set) item=$1; key=${item%%=*}; val=${item#*=}; awk -F= -v k="$key" '$1!=k' "$db" > "$db.tmp"; printf "%s='%s'\n" "$key" "$val" >> "$db.tmp"; mv "$db.tmp" "$db" ;;
  add_list) item=$1; key=${item%%=*}; val=${item#*=}; printf "%s='%s'\n" "$key" "$val" >> "$db" ;;
  del_list) item=$1; key=${item%%=*}; val="'${item#*=}'"; awk -F= -v k="$key" -v v="$val" '!($1==k&&substr($0,index($0,"=")+1)==v)' "$db" > "$db.tmp"; mv "$db.tmp" "$db" ;;
  delete) key=$1; awk -F= -v k="$key" '$1!=k&&index($1,k ".")!=1' "$db" > "$db.tmp"; mv "$db.tmp" "$db" ;;
  import) target=$1; cat > "$db.import"; awk -v p="$target." 'index($1,p)!=1' "$db" > "$db.tmp"; cat "$db.import" >> "$db.tmp"; mv "$db.tmp" "$db"; rm -f "$db.import" ;;
  commit)
    printf 'uci commit %s\n' "$1" >> "$Z2K_DOH_TEST_LOG"
    if [ "$1" = dhcp ] && [ -f "$T/fail-legacy-commit" ] && [ -f "$T/legacy-stopped" ]; then
      rm -f "$T/fail-legacy-commit"
      exit 1
    fi ;;
  *) exit 2 ;;
esac
STUB
cat > "$T/bin/apk" <<'STUB'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "$1 $2" in
  'info -e') case "$3" in dnsproxy) [ -f "$Z2K_DOH_PACKAGE_FILE" ] ;; https-dns-proxy) [ -f "$T/legacy-installed" ] ;; *) exit 1 ;; esac ;;
  'add dnsproxy')
    : > "$Z2K_DOH_PACKAGE_FILE"
    if ! grep -q '^dnsproxy\.global=' "$Z2K_DOH_TEST_DB"; then
      printf "dnsproxy.global='dnsproxy'\ndnsproxy.global.enabled='0'\ndnsproxy.cache='dnsproxy'\ndnsproxy.cache.enabled='0'\ndnsproxy.cache.size='65535'\ndnsproxy.servers='dnsproxy'\ndnsproxy.servers.bootstrap='tls://8.8.8.8'\ndnsproxy.servers.fallback='tls://9.9.9.9'\ndnsproxy.servers.upstream='tls://1.1.1.1'\n" >> "$Z2K_DOH_TEST_DB"
    fi ;;
  'del dnsproxy') rm -f "$Z2K_DOH_PACKAGE_FILE" ;;
  *) exit 2 ;;
esac
STUB
cat > "$Z2K_DOH_PROXY_INIT" <<'STUB'
#!/bin/sh
printf 'dnsproxy %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
case "$1" in
  enabled) [ -f "$Z2K_DOH_ENABLED_FILE" ] ;;
  enable) : > "$Z2K_DOH_ENABLED_FILE" ;;
  disable) rm -f "$Z2K_DOH_ENABLED_FILE" ;;
  restart|start) : > "$Z2K_DOH_RUNNING_FILE" ;;
  stop) rm -f "$Z2K_DOH_RUNNING_FILE" ;;
  *) exit 2 ;;
esac
STUB
cat > "$Z2K_DOH_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ ! -f "$T/dnsmasq-fail" ]
STUB
cat > "$T/bin/fw4" <<'STUB'
#!/bin/sh
printf 'fw4 %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ ! -f "$T/fw4-fail" ]
STUB
cat > "$T/bin/firewall.init" <<'STUB'
#!/bin/sh
printf 'firewall %s\n' "$*" >> "$Z2K_DOH_TEST_LOG"
[ ! -f "$T/firewall-fail" ]
STUB
cat > "$T/bin/pidof" <<'STUB'
#!/bin/sh
case "$1" in
  dnsproxy) [ -f "$Z2K_DOH_RUNNING_FILE" ] ;;
  https_dns_proxy|https-dns-proxy) [ -f "$T/legacy-running" ] ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T/nslookup.calls"
[ -f "$Z2K_DOH_RUNNING_FILE" ] || exit 1
[ ! -f "$T/upstream-fail" ] || exit 1
if [ -f "$T/nslookup-warmup" ]; then
  n=$(cat "$T/nslookup-warmup"); n=$((n + 1)); printf '%s\n' "$n" > "$T/nslookup-warmup"
  [ "$n" -ge 3 ] || { printf 'connection refused\n'; exit 1; }
fi
if [ -f "$T/nxdomain-response" ] && [ "$4" ]; then printf '** server can\047t find %s: NXDOMAIN\n' "$3"; exit 1; fi
if [ -f "$T/servfail-response" ]; then printf '** server can\047t find %s: SERVFAIL\n' "$3"; exit 0; fi
if [ -f "$T/nodata-response" ]; then
  if [ -f "$T/nodata-exchange-error" ]; then printf 'dnsproxy: ERROR exchange failed: unexpected EOF\n' >> "$T/dnsproxy.log"; fi
  printf 'Server: 127.0.0.1:5353\nAddress: 127.0.0.1:5353\nNon-authoritative answer:\n'
  exit 0
fi
printf 'Server: 127.0.0.1:5353\nAddress: 127.0.0.1:5353\nName: %s\nAddress 1: 203.0.113.8\n' "${3:-$1}"
STUB
cat > "$T/bin/logread" <<'STUB'
#!/bin/sh
cat "$T/dnsproxy.log" 2>/dev/null
STUB
chmod +x "$T/bin/uci" "$T/bin/apk" "$T/bin/pidof" "$T/bin/nslookup" "$T/bin/logread" "$Z2K_DOH_PROXY_INIT" "$Z2K_DOH_DNSMASQ_INIT"
chmod +x "$T/bin/fw4" "$T/bin/firewall.init"
export Z2K_DOH_FW4_BIN=fw4 Z2K_DOH_FIREWALL_INIT="$T/bin/firewall.init"
printf '0\n' > "$T/nslookup-warmup"

assert_eq 'install succeeds' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'install adds dnsproxy' "$Z2K_DOH_TEST_LOG" 'apk add dnsproxy'
assert_not_contains 'install does not add a drill runtime dependency' "$Z2K_DOH_TEST_LOG" 'apk add dnsproxy drill'
assert_file 'install snapshots the old https-dns-proxy UCI for migration' "$T/state/.https-dns-proxy-migration-snapshot"
assert_contains 'install snapshots old resolver service state' "$T/state/.https-dns-proxy-service-snapshot" 'enabled=1'
assert_contains 'install snapshots old resolver running state' "$T/state/.https-dns-proxy-service-snapshot" 'running=1'
assert_contains 'install leaves the old owned resolver config in place' "$Z2K_DOH_TEST_DB" "https-dns-proxy.z2kow_doh.resolver_url='https://dns.google/dns-query'"
assert_contains 'owned migration starts dnsproxy before cutover' "$Z2K_DOH_TEST_LOG" 'dnsproxy restart'
assert_contains 'dnsproxy listener is emitted as package UCI list values' "$Z2K_DOH_TEST_DB" "dnsproxy.global.listen_addr='127.0.0.1'"
assert_contains 'dnsproxy port uses package UCI list schema' "$Z2K_DOH_TEST_DB" "dnsproxy.global.listen_port='5353'"
assert_contains 'owned migration disables only the owned old service after cutover' "$Z2K_DOH_TEST_LOG" 'legacy stop'
assert_not_contains 'owned migration removes the old marked dnsmasq listener route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
assert_contains 'owned migration installs the dnsproxy listener route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5353'"
assert_eq 'direct, cutover, and post-stop probes retry transient dns readiness race' 5 "$(cat "$T/nslookup-warmup")"

: > "$T/dnsmasq-fail"
assert_eq 'provider switch reports dnsmasq restart failure after migration' 1 "$(z2k_ow_doh_select_provider quad9 '' '' 0 dot >/dev/null 2>&1; echo $?)"
rm -f "$T/dnsmasq-fail"
assert_contains 'failed post-migration provider switch keeps dnsproxy route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5353'"
assert_not_contains 'failed post-migration provider switch does not restore stopped legacy route 5053' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5053'
assert_not_contains 'failed post-migration provider switch does not restore stopped legacy route 5054' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5054'
assert_contains 'failed post-migration provider switch keeps DNS leak protection' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].noresolv='1'"
assert_contains 'failed post-migration provider switch restores previous upstream config' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://dns.google/dns-query'"
assert_path_presence 'failed post-migration provider switch leaves dnsproxy running' 0 "$Z2K_DOH_RUNNING_FILE"

# BusyBox prints the same non-authoritative marker for valid NOERROR/NODATA
# and dnsproxy's empty response after an upstream exchange error. The latter
# must never count as an upstream confirmation.
: > "$T/dnsproxy.log"
: > "$T/nodata-response"
assert_eq 'accepts genuine NODATA when dnsproxy reports no new exchange error' 0 "$( _z2k_ow_doh_direct_query >/dev/null 2>&1; echo $? )"
: > "$T/nodata-exchange-error"
assert_eq 'rejects empty answer after a new dnsproxy upstream exchange error' 1 "$( _z2k_ow_doh_direct_query >/dev/null 2>&1; echo $? )"
rm -f "$T/nodata-response" "$T/nodata-exchange-error"
: > "$T/servfail-response"
assert_eq 'rejects explicit SERVFAIL from direct probe' 1 "$( _z2k_ow_doh_direct_query >/dev/null 2>&1; echo $? )"
rm -f "$T/servfail-response"
assert_not_contains 'install does not remove legacy https-dns-proxy' "$Z2K_DOH_TEST_LOG" 'apk del https-dns-proxy'
assert_eq 'legacy API rejects unknown provider protocol' 1 "$(z2k_ow_doh_select_provider custom https://resolver.example/dns-query 8.8.8.8 0 doh3 >/dev/null 2>&1; echo $?)"
assert_eq 'legacy API rejects mismatched endpoint scheme' 1 "$(z2k_ow_doh_select_provider custom h3://resolver.example/dns-query 8.8.8.8 0 doh >/dev/null 2>&1; echo $?)"
assert_eq 'legacy custom hostname requires explicit bootstrap' 1 "$(z2k_ow_doh_select_provider custom tls://resolver.example '' 0 dot >/dev/null 2>&1; echo $?)"
assert_eq 'legacy custom literal IP is applied without substitution' 0 "$(z2k_ow_doh_select_provider custom tls://198.51.100.53 '' 0 dot >/dev/null 2>&1; echo $?)"
assert_contains 'literal IP endpoint remains exactly configured' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='tls://198.51.100.53'"
assert_not_contains 'literal IP endpoint needs no bootstrap list' "$Z2K_DOH_TEST_DB" 'dnsproxy\.servers\.bootstrap='
_quad9_stamp='sdns://AQMAAAAAAAAADDkuOS45Ljk6ODQ0MyBnyEe4yHWM0SAkVUO-dWdG3zTfHYTAC4xHA2jfgh2GPhkyLmRuc2NyeXB0LWNlcnQucXVhZDkubmV0'
assert_eq 'custom DNSCrypt stamp applies without bootstrap DNS' 0 "$(z2k_ow_doh_select_provider custom "$_quad9_stamp" '' 0 dnscrypt >/dev/null 2>&1; echo $?)"
assert_contains 'DNSCrypt stamp remains the configured upstream' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='$_quad9_stamp'"
assert_not_contains 'DNSCrypt stamp does not create an unrelated bootstrap list' "$Z2K_DOH_TEST_DB" 'dnsproxy\.servers\.bootstrap='
for _applet in od base64; do
  cat > "$T/bin/$_applet" <<'STUB'
#!/bin/sh
exit 127
STUB
  chmod +x "$T/bin/$_applet"
done
assert_eq 'DNSCrypt stamp validation works without optional od/base64 applets' 0 "$(z2k_ow_doh_provider_protocol_valid custom dnscrypt sdns://AQAAAAAAAAAADzEyNy4wLjAuMToxNTQ0MyBxZJUKf-gqaZvDU0FhNSdRy-2TRSfPY5Sbqa6wv3jJsRgyLmRuc2NyeXB0LWNlcnQuZG5zLnRlc3Q >/dev/null 2>&1; echo $?)"
assert_eq 'DNSCrypt stamp with its resolver address does not need bootstrap DNS' 0 "$( _z2k_ow_doh_profile_endpoint sdns://AQAAAAAAAAAADzEyNy4wLjAuMToxNTQ0MyBxZJUKf-gqaZvDU0FhNSdRy-2TRSfPY5Sbqa6wv3jJsRgyLmRuc2NyeXB0LWNlcnQuZG5zLnRlc3Q '' >/dev/null 2>&1; echo $?)"
rm -f "$T/bin/od" "$T/bin/base64"
for _provider in xbox comss google quad9 xyz geohide_ru geohide_eu geohide_us dns_ai malw astracat mafioznik malw_cloudflare nullsproxy cloudflare default; do
  _z2k_ow_doh_preset "$_provider"
  _z2k_ow_doh_valid_bootstrap "$Z2K_DOH_BOOTSTRAP" >/dev/null 2>&1; _bootstrap_valid=$?
  assert_eq "$_provider DoH preset has a valid bootstrap resolver" 0 "$_bootstrap_valid"
  assert_eq "$_provider uses the same editable global bootstrap list" "$Z2K_DOH_DEFAULT_BOOTSTRAP" "$Z2K_DOH_BOOTSTRAP"
done
assert_contains 'global bootstrap has Quad9 and Google IPv4 resolvers' "$REPO/platform/openwrt/dnsproxy.sh" '9.9.9.9,149.112.112.112,8.8.8.8,8.8.4.4'
assert_contains 'global bootstrap has Quad9 and Google IPv6 resolvers' "$REPO/platform/openwrt/dnsproxy.sh" '2620:fe::fe,2620:fe::9,2001:4860:4860::8888,2001:4860:4860::8844'
assert_not_contains 'global bootstrap does not use Cloudflare provider addresses' "$REPO/platform/openwrt/dnsproxy.sh" 'Z2K_DOH_BOOTSTRAP=1\.1\.1\.1'
assert_eq 'Xbox DoH preset applies without an explicit UI bootstrap argument' 0 "$(z2k_ow_doh_select_provider xbox '' '' 0 doh >/dev/null 2>&1; echo $?)"
assert_contains 'Xbox DoH preset stores its bootstrap resolver' "$Z2K_DOH_TEST_DB" 'dnsproxy.servers.bootstrap='
assert_eq 'combined Cloudflare + Google preset applies as two upstreams' 0 "$(z2k_ow_doh_select_provider default '' '' 0 doh >/dev/null 2>&1; echo $?)"
assert_contains 'combined preset configures Cloudflare DoH endpoint' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://cloudflare-dns.com/dns-query'"
assert_contains 'combined preset configures Google DoH endpoint independently' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://dns.google/dns-query'"
assert_eq 'combined preset stores exactly two upstream entries' 2 "$(grep -Fc 'dnsproxy.servers.upstream=' "$Z2K_DOH_TEST_DB")"
assert_eq 'Quad9 supports documented DoQ' 0 "$(z2k_ow_doh_provider_protocol_valid quad9 doq >/dev/null 2>&1; echo $?)"
assert_eq 'DoH-only providers reject DoQ' 1 "$(z2k_ow_doh_provider_protocol_valid google doq >/dev/null 2>&1; echo $?)"
assert_eq 'Quad9 provider chooses its DoQ endpoint' 0 "$(z2k_ow_doh_select_provider quad9 '' '' 0 doq >/dev/null 2>&1; echo $?)"
assert_contains 'Quad9 DoQ endpoint remains protocol-matched' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='quic://dns.quad9.net:853'"

for _pair in 'doh https://resolver.example/dns-query' 'doh3 h3://resolver.example/dns-query' \
             'dot tls://resolver.example' 'doq quic://resolver.example' \
             'dnscrypt sdns://AQAAAAAAAAAAAAAA'; do
  set -- $_pair; _proto=$1 _endpoint=$2
  assert_eq "applies $_proto through legacy entrypoint" 0 "$(z2k_ow_doh_select_provider custom "$_endpoint" 8.8.8.8 0 "$_proto" >/dev/null 2>&1; echo $?)"
  assert_contains "writes $_proto endpoint to dnsproxy UCI" "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='$_endpoint'"
  assert_contains "keeps TLS validation enabled for $_proto" "$Z2K_DOH_TEST_DB" "dnsproxy.global.insecure='0'"
  assert_not_contains "does not configure plaintext fallback for $_proto" "$Z2K_DOH_TEST_DB" 'dnsproxy\.servers\.fallback='
  z2k_ow_doh_status > "$T/status-$_proto"
  assert_contains "reports $_proto only after direct upstream confirmation" "$T/status-$_proto" "protocol=$_proto actual_protocol=$_proto"
done
_dnsproxy_route_count=$(grep -Fc "dhcp.@dnsmasq[0].server='127.0.0.1#5353'" "$Z2K_DOH_TEST_DB")
assert_eq 'repeated provider changes keep one dnsproxy route in dnsmasq' 1 "$_dnsproxy_route_count"

assert_contains 'provider changes preserve TikTok dnsmasq overrides' "$Z2K_DOH_TEST_DB" 'dhcp.@dnsmasq[0].address='
z2k_ow_doh_status > "$T/status"
assert_contains 'status preserves the legacy working state' "$T/status" 'state=working'
assert_contains 'status reports configured protocol' "$T/status" 'protocol=dnscrypt'
assert_contains 'status reports the confirmed active DNSCrypt upstream protocol' "$T/status" 'actual_protocol=dnscrypt'
assert_contains 'status separates local and upstream confirmation' "$T/status" 'local_dns_state=working upstream_state=confirmed'
assert_contains 'status retains legacy API keys' "$T/status" 'package_owner=z2kow'
assert_contains 'status reports package default cache setting' "$T/status" 'cache_enabled=0 cache_size=65535'
assert_contains 'status reports unsupported upstream family selection truthfully' "$T/status" 'upstream_family=unsupported'
assert_eq 'direct health probe uses base nslookup without drill installed' 0 "$( _z2k_ow_doh_direct_query >/dev/null 2>&1; echo $?)"
grep -Eq -- '-timeout=2 -type=A z2k-health-[0-9]+-[0-9]+-[0-9]+\.example\.com 127\.0\.0\.1:5353' "$T/nslookup.calls" && _t_ok || _t_bad 'direct probe uses a unique uncached dnsproxy query'
assert_contains 'status reports redirect capability family' "$T/status" 'redirect_family=ipv4'
assert_eq 'cache setting accepts bounded byte size' 0 "$(z2k_ow_doh_set_cache 1 131072 >/dev/null 2>&1; echo $?)"
assert_contains 'cache setting writes package-supported UCI values' "$Z2K_DOH_TEST_DB" "dnsproxy.cache.enabled='1'"
assert_contains 'cache setting writes explicit byte limit' "$Z2K_DOH_TEST_DB" "dnsproxy.cache.size='131072'"
assert_eq 'cache setting rejects unreasonable byte limit' 1 "$(z2k_ow_doh_set_cache 1 999999999 >/dev/null 2>&1; echo $?)"
assert_contains 'rejected cache size leaves prior cache state unchanged' "$Z2K_DOH_TEST_DB" "dnsproxy.cache.size='131072'"
assert_eq 'provider change preserves cache settings' 0 "$(z2k_ow_doh_select_provider custom https://cache-preserve.example/dns-query 8.8.8.8 0 doh >/dev/null 2>&1; echo $?)"
assert_contains 'provider change preserves cache enable state' "$Z2K_DOH_TEST_DB" "dnsproxy.cache.enabled='1'"
assert_contains 'provider change preserves cache size' "$Z2K_DOH_TEST_DB" "dnsproxy.cache.size='131072'"
touch "$T/nxdomain-response"
assert_eq 'unique NXDOMAIN confirms direct upstream even when cache is enabled' 0 "$( _z2k_ow_doh_direct_query >/dev/null 2>&1; echo $?)"
rm -f "$T/nxdomain-response"
_z2k_ow_doh_uci add_list 'dnsproxy.servers.fallback=tls://fallback.example' >/dev/null
z2k_ow_doh_status > "$T/status-mixed"
assert_contains 'mixed upstream and fallback schemes leave protocol unknown' "$T/status-mixed" 'protocol=unknown actual_protocol=unknown'
assert_contains 'mixed schemes still expose confirmed upstream response' "$T/status-mixed" 'upstream_state=confirmed upstream_confirmed=1'
_z2k_ow_doh_uci delete 'dnsproxy.servers.fallback' >/dev/null
touch "$T/upstream-fail"
z2k_ow_doh_status > "$T/status-unverified"
assert_contains 'unverified endpoint leaves actual protocol unknown' "$T/status-unverified" 'actual_protocol=unknown'
assert_contains 'unverified upstream is reported as failed' "$T/status-unverified" 'upstream_state=failed'
rm -f "$T/upstream-fail"
cp "$Z2K_DOH_TEST_DB" "$T/cache-before-failure"
touch "$T/upstream-fail"
assert_eq 'failed cache restart health check rolls back' 1 "$(z2k_ow_doh_set_cache 0 65535 >/dev/null 2>&1; echo $?)"
grep '^dnsproxy\.cache\.' "$T/cache-before-failure" > "$T/cache-before-lines"
grep '^dnsproxy\.cache\.' "$Z2K_DOH_TEST_DB" > "$T/cache-after-lines"
cmp -s "$T/cache-before-lines" "$T/cache-after-lines" && _t_ok || _t_bad 'cache rollback restores previous UCI values'
rm -f "$T/upstream-fail"
touch "$T/fw4-fail"
assert_eq 'invalid fw4 redirect rolls back without activation' 1 "$(z2k_ow_doh_set_force_dns 1 >/dev/null 2>&1; echo $?)"
assert_not_contains 'failed firewall check removes its partial redirect' "$Z2K_DOH_TEST_DB" 'firewall\.z2kow_dns_redirect'
[ ! -e "$T/state/.dnsproxy-lan-redirect-owned" ] && _t_ok || _t_bad 'failed firewall check removes its ownership marker'
rm -f "$T/fw4-fail"
assert_eq 'explicit LAN DNS redirect applies through fw4 UCI' 0 "$(z2k_ow_doh_set_force_dns 1 >/dev/null 2>&1; echo $?)"
assert_contains 'LAN redirect records its distinct owned UCI section' "$Z2K_DOH_TEST_DB" "firewall.z2kow_dns_redirect='redirect'"
assert_contains 'LAN redirect intercepts TCP and UDP port 53 only from LAN' "$Z2K_DOH_TEST_DB" "firewall.z2kow_dns_redirect.src_dport='53'"
assert_contains 'LAN redirect scopes destination to LAN zone' "$Z2K_DOH_TEST_DB" "firewall.z2kow_dns_redirect.dest='lan'"
z2k_ow_doh_status > "$T/status-redirect"
assert_contains 'LAN redirect status reflects active owned rule' "$T/status-redirect" 'force_lan_dns=1 redirect_state=active redirect_snapshot=1'
_z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.proto=tcp' >/dev/null
assert_eq 'redirect removal refuses to overwrite a user-modified owned section' 1 "$(z2k_ow_doh_set_force_dns 0 >/dev/null 2>&1; echo $?)"
z2k_ow_doh_status > "$T/status-drift"
assert_contains 'redirect status exposes manual drift' "$T/status-drift" 'redirect_state=drift'
_z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.proto=tcp udp' >/dev/null
assert_eq 'LAN redirect removal succeeds' 0 "$(z2k_ow_doh_set_force_dns 0 >/dev/null 2>&1; echo $?)"
assert_contains 'LAN redirect removal preserves unrelated firewall section' "$Z2K_DOH_TEST_DB" "firewall.z2k_unrelated.name='leave-alone'"
assert_not_contains 'LAN redirect removes only its owned UCI section' "$Z2K_DOH_TEST_DB" 'firewall\.z2kow_dns_redirect'
z2k_ow_doh_diagnostics > "$T/diagnostics"
assert_contains 'diagnostics report direct dnsproxy probe' "$T/diagnostics" 'dnsproxy_direct_probe=working'
assert_contains 'diagnostics report dnsmasq path separately' "$T/diagnostics" 'dnsmasq_probe=working'
assert_eq 'recovery restarts and verifies dnsproxy and dnsmasq path' 0 "$(z2k_ow_doh_recover >/dev/null 2>&1; echo $?)"

cp "$Z2K_DOH_TEST_DB" "$T/before-upstream-failure"
: > "$T/upstream-fail"
assert_eq 'failed upstream query aborts provider switch' 1 "$(z2k_ow_doh_select_provider custom https://next.example/dns-query 8.8.8.8 0 doh >/dev/null 2>&1; echo $?)"
grep '^dnsproxy\.' "$T/before-upstream-failure" > "$T/dnsproxy-before"
grep '^dnsproxy\.' "$Z2K_DOH_TEST_DB" > "$T/dnsproxy-after"
cmp -s "$T/dnsproxy-before" "$T/dnsproxy-after" && _t_ok || _t_bad 'failed upstream query restores the prior dnsproxy UCI'
assert_contains 'failed upstream query leaves dnsmasq TikTok override untouched' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"
rm -f "$T/upstream-fail"

assert_eq 'disable restores dnsmasq route' 0 "$(z2k_ow_doh_disable >/dev/null 2>&1; echo $?)"
assert_not_contains 'disable removes only the owned dnsproxy server route' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5353'
assert_not_contains 'disable restores the pre-migration noresolv default' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.noresolv='
assert_file 'disable restarts the previously running legacy resolver' "$T/legacy-running"
assert_file 'disable reenables the previously enabled legacy resolver' "$T/legacy-enabled"
assert_contains 'disable preserves TikTok override' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"
assert_eq 'enable starts and routes through dnsproxy' 0 "$(z2k_ow_doh_enable >/dev/null 2>&1; echo $?)"
assert_path_presence 'enable stops the restored legacy resolver after dnsproxy cutover' 1 "$T/legacy-running"
assert_path_presence 'enable disables the restored legacy resolver after dnsproxy cutover' 1 "$T/legacy-enabled"

printf "dnsproxy.global='dnsproxy'\ndnsproxy.global.user_marker='keep-me'\n" >> "$Z2K_DOH_TEST_DB"
cp "$Z2K_DOH_TEST_DB" "$T/external-before"
assert_eq 'external config requires explicit replace' 1 "$(z2k_ow_doh_select_provider custom https://replacement.example/dns-query 8.8.8.8 0 doh >/dev/null 2>&1; echo $?)"
grep '^dnsproxy\.' "$T/external-before" > "$T/external-before-dnsproxy"
grep '^dnsproxy\.' "$Z2K_DOH_TEST_DB" > "$T/external-after-dnsproxy"
cmp -s "$T/external-before-dnsproxy" "$T/external-after-dnsproxy" && _t_ok || _t_bad 'refused replace leaves external UCI unchanged'
assert_eq 'confirmed replace snapshots then applies external config' 0 "$(z2k_ow_doh_select_provider custom https://replacement.example/dns-query 8.8.8.8 1 doh >/dev/null 2>&1; echo $?)"
assert_file 'confirmed replace retains reversible user snapshot' "$T/state/.dnsproxy-config-backup"
assert_not_contains 'confirmed replace does not retain unrelated external marker in active config' "$Z2K_DOH_TEST_DB" 'dnsproxy\.global\.user_marker='
assert_eq 'uninstall requires explicit confirmation to restore external config' 1 "$(z2k_ow_doh_uninstall 0 >/dev/null 2>&1; echo $?)"
assert_eq 'confirmed uninstall restores external config and removes owned package' 0 "$(z2k_ow_doh_uninstall 1 >/dev/null 2>&1; echo $?)"
assert_contains 'uninstall restores user-owned dnsproxy option' "$Z2K_DOH_TEST_DB" "dnsproxy.global.user_marker='keep-me'"
assert_contains 'TikTok override survives uninstall' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"
assert_file 'uninstall restores the previously running legacy resolver' "$T/legacy-running"
assert_file 'uninstall restores the previously enabled legacy resolver' "$T/legacy-enabled"

assert_eq 'force-DNS legacy endpoint fails safely without changing firewall rules' 1 "$(z2k_ow_doh_set_force_dns 1 >/dev/null 2>&1; echo $?)"
assert_not_contains 'no insecure flag is enabled in adapter source' "$REPO/platform/openwrt/dnsproxy.sh" 'insecure=1'
# Profile-level fallback validation rejects plaintext at the public boundary.

reset_migration_fixture() {
  rm -f "$Z2K_DOH_PACKAGE_FILE" "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_CONFIG_OWNED_FILE" \
    "$Z2K_DOH_CONFIG_BACKUP" "$Z2K_DOH_CONFIG_BASELINE" "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" \
    "$Z2K_DOH_INSTALL_SNAPSHOT" "$Z2K_DOH_SERVICE_SNAPSHOT" "$Z2K_DOH_STATE_FILE" \
    "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_ROUTE_SNAPSHOT" "$Z2K_DOH_LEGACY_ROUTE_TXN" \
    "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" \
    "$Z2K_DOH_REDIRECT_MARKER" "$T/fail-legacy-commit" "$T/legacy-stopped" \
    "$T/legacy-running" "$T/legacy-enabled" "$T/fail-baseline-second-write" \
    "$T/fail-state-write" "$T/baseline-write-count"
  : > "$Z2K_DOH_TEST_DB"
  printf "dhcp.@dnsmasq[0]='dnsmasq'\ndhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'\ndhcp.@dnsmasq[0].noresolv='1'\ndhcp.@dnsmasq[0].server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_server='127.0.0.1#5053'\ndhcp.@dnsmasq[0].doh_backup_noresolv='-1'\n" > "$Z2K_DOH_TEST_DB"
  printf "network.lan.ipaddr='192.168.1.1'\nhttps-dns-proxy.z2kow_doh='https-dns-proxy'\nhttps-dns-proxy.z2kow_doh.resolver_url='https://dns.google/dns-query'\nhttps-dns-proxy.z2kow_doh.bootstrap_dns='8.8.8.8,8.8.4.4'\n" >> "$Z2K_DOH_TEST_DB"
  : > "$T/legacy-installed"
  printf '1\n' > "$T/legacy-running"
  printf '1\n' > "$T/legacy-enabled"
}

reset_migration_fixture
: > "$T/fail-legacy-commit"
assert_eq 'failed legacy marker cleanup aborts migration' 1 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'legacy cleanup failure restores the old dnsmasq route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
assert_not_contains 'legacy cleanup failure removes the dnsproxy route' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5353'
assert_contains 'legacy cleanup rollback requests old resolver enable' "$Z2K_DOH_TEST_LOG" 'legacy enable'
assert_contains 'legacy cleanup rollback requests old resolver restart' "$Z2K_DOH_TEST_LOG" 'legacy restart'
assert_file 'legacy cleanup failure restarts the old owned resolver' "$T/legacy-running"
assert_file 'legacy cleanup failure reenables the old owned resolver' "$T/legacy-enabled"
assert_contains 'legacy cleanup failure preserves TikTok override' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"

reset_migration_fixture
REAL_MV=$(command -v mv)
export REAL_MV
cat > "$T/bin/mv" <<'STUB'
#!/bin/sh
last=
for arg do last=$arg; done
if [ "$last" = "$T/state/.dnsproxy-config-baseline" ] && [ -f "$T/fail-baseline-second-write" ]; then
  count=0
  [ ! -f "$T/baseline-write-count" ] || count=$(cat "$T/baseline-write-count")
  count=$((count + 1))
  printf '%s\n' "$count" > "$T/baseline-write-count"
  [ "$count" -lt 2 ] || exit 1
fi
[ "$last" != "$T/state/doh.state" ] || [ ! -f "$T/fail-state-write" ] || exit 1
exec "$REAL_MV" "$@"
STUB
chmod +x "$T/bin/mv"
: > "$T/fail-baseline-second-write"
assert_eq 'baseline persistence failure aborts migration after cutover' 1 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'baseline failure restores the old dnsmasq route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
assert_not_contains 'baseline failure removes the dnsproxy route' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5353'
assert_contains 'baseline rollback requests old resolver enable' "$Z2K_DOH_TEST_LOG" 'legacy enable'
assert_contains 'baseline rollback requests old resolver restart' "$Z2K_DOH_TEST_LOG" 'legacy restart'
assert_file 'baseline failure restarts the old owned resolver' "$T/legacy-running"
  assert_file 'baseline failure reenables the old owned resolver' "$T/legacy-enabled"
  assert_contains 'baseline failure preserves TikTok override' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"

reset_migration_fixture
: > "$T/fail-state-write"
assert_eq 'state persistence failure aborts migration after cutover' 1 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'state failure restores the old dnsmasq route' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
assert_not_contains 'state failure removes the dnsproxy route' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5353'
assert_file 'state failure restarts the old owned resolver' "$T/legacy-running"
assert_file 'state failure reenables the old owned resolver' "$T/legacy-enabled"
assert_contains 'state failure preserves TikTok override' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"

reset_migration_fixture
rm -f "$T/legacy-running" "$T/legacy-enabled"
assert_eq 'migration from an originally stopped and disabled service succeeds' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'migration records originally disabled legacy service' "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" 'enabled=0'
assert_contains 'migration records originally stopped legacy service' "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" 'running=0'
assert_eq 'disable preserves the originally stopped and disabled service' 0 "$(z2k_ow_doh_disable >/dev/null 2>&1; echo $?)"
assert_path_presence 'disable does not start a legacy service that was originally stopped' 1 "$T/legacy-running"
assert_path_presence 'disable does not enable a legacy service that was originally disabled' 1 "$T/legacy-enabled"

reset_migration_fixture
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#5353'
assert_eq 'migration with a preexisting dnsproxy route succeeds' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'migration records the preexisting dnsproxy route' "$Z2K_DOH_ROUTE_SNAPSHOT" 'route_preexisting=1'
assert_eq 'disable refuses to stop a resolver with a preexisting dnsmasq route' 1 "$(z2k_ow_doh_disable >/dev/null 2>&1; echo $?)"
assert_path_presence 'refused disable leaves dnsproxy running' 0 "$Z2K_DOH_RUNNING_FILE"
assert_path_presence 'refused disable leaves dnsproxy enabled' 0 "$Z2K_DOH_ENABLED_FILE"
assert_eq 'uninstall refuses to remove a resolver with a preexisting dnsmasq route' 1 "$(z2k_ow_doh_uninstall 1 >/dev/null 2>&1; echo $?)"
assert_path_presence 'refused uninstall leaves dnsproxy running' 0 "$Z2K_DOH_RUNNING_FILE"
assert_path_presence 'refused uninstall leaves dnsproxy enabled' 0 "$Z2K_DOH_ENABLED_FILE"
reset_migration_fixture
cat > "$T/uci-export-https-dns-proxy" <<'UCI'
config main 'config'
	option listen_addr '127.0.0.1'

config https-dns-proxy 'z2kow_doh'
	option resolver_url 'https://dns.google/dns-query'
	option bootstrap_dns '8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844'
	option listen_port '5053'

config https-dns-proxy 'secondary'
	option resolver_url 'https://dns.quad9.net/dns-query'
UCI
assert_eq 'migration parses bootstrap from actual OpenWrt UCI export syntax' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'migration preserves the old endpoint from actual UCI export syntax' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://dns.google/dns-query'"
assert_contains 'migration preserves the second legacy endpoint as a separate upstream' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://dns.quad9.net/dns-query'"
assert_not_contains 'migration does not combine legacy endpoints into one comma-delimited upstream' "$Z2K_DOH_TEST_DB" 'dnsproxy\.servers\.upstream=.*dns-query,https://'
assert_eq 'migration preserves exactly two legacy endpoints' 2 "$(grep -Fc 'dnsproxy.servers.upstream=' "$Z2K_DOH_TEST_DB")"
assert_contains 'migration preserves IPv4 bootstrap from actual UCI export syntax' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.bootstrap='8.8.8.8'"
assert_contains 'migration preserves IPv6 bootstrap from actual UCI export syntax' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.bootstrap='2001:4860:4860::8888'"
assert_contains 'migration snapshots the actual legacy UCI export' "$Z2K_DOH_OLD_BACKUP" "option bootstrap_dns '8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844'"
assert_not_contains 'actual UCI export migration removes the old dnsmasq route' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5053'
assert_contains 'actual UCI export migration switches dnsmasq to dnsproxy' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='127.0.0.1#5353'"
assert_contains 'actual UCI export migration stops the old owned resolver' "$Z2K_DOH_TEST_LOG" 'legacy stop'

reset_migration_fixture
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#5054'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=/mask.icloud.com/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=/mask-h2.icloud.com/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=/use-application-dns.net/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_server=127.0.0.1#5054'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_backup_server=/mask.icloud.com/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_backup_server=/mask-h2.icloud.com/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_backup_server=/use-application-dns.net/'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_backup_server=127.0.0.1#5053'
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].doh_backup_server=127.0.0.1#5054'
: > "$T/aggregate-dhcp-list-values"
: > "$T/legacy-stop-readds-route"
assert_eq 'migration handles actual aggregated UCI list output' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_not_contains 'aggregated legacy route migration removes old port 5053' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5053'
assert_not_contains 'aggregated legacy route migration removes old port 5054' "$Z2K_DOH_TEST_DB" 'dhcp\.@dnsmasq\[0\]\.server=.*127\.0\.0\.1#5054'
assert_contains 'aggregated legacy route migration preserves iCloud canary routes' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/mask.icloud.com/'"
assert_contains 'aggregated legacy route migration preserves Mozilla canary routes' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].server='/use-application-dns.net/'"
assert_eq 'aggregated legacy route migration keeps exactly one dnsproxy route' 1 "$(grep -F -c '127.0.0.1#5353' "$Z2K_DOH_TEST_DB")"

reset_migration_fixture
_z2k_ow_doh_uci add_list 'dhcp.@dnsmasq[0].server=127.0.0.1#5353'
: > "$T/aggregate-dhcp-list-values"
assert_eq 'migration preserves an aggregated preexisting dnsproxy route' 0 "$(z2k_ow_doh_install >/dev/null 2>&1; echo $?)"
assert_contains 'aggregated preexisting route is recorded as external ownership' "$Z2K_DOH_ROUTE_SNAPSHOT" 'route_preexisting=1'
assert_eq 'aggregated preexisting route is not duplicated' 1 "$(grep -F -c '127.0.0.1#5353' "$Z2K_DOH_TEST_DB")"
assert_eq 'disable refuses to stop dnsproxy while an aggregated preexisting route remains' 1 "$(z2k_ow_doh_disable >/dev/null 2>&1; echo $?)"
assert_path_presence 'blocked aggregated-route disable leaves dnsproxy running' 0 "$Z2K_DOH_RUNNING_FILE"

# The multi-upstream API accepts mixed encrypted protocols in one dnsproxy
# process, keeps fallback resolvers protected, and rolls the whole profile back.
_profile_upstreams='https://one.example/dns-query?token=a=b
h3://two.example/dns-query
tls://three.example
quic://four.example:853
sdns://AQAAAAAAAAAADzEyNy4wLjAuMToxNTQ0MyBxZJUKf-gqaZvDU0FhNSdRy-2TRSfPY5Sbqa6wv3jJsRgyLmRuc2NyeXB0LWNlcnQuZG5zLnRlc3Q'
_profile_fallbacks='tls://fallback.example
h3://fallback2.example'
_profile_routes='example.org=tls://route.example'
_profile_bootstrap='8.8.8.8
2001:4860:4860::8888'
assert_eq 'multi-upstream profile applies mixed protected transports' 0 "$(z2k_ow_doh_apply_profile "$_profile_upstreams" "$_profile_fallbacks" "$_profile_routes" parallel "$_profile_bootstrap" 0 >/dev/null 2>&1; echo $?)"
z2k_ow_doh_status > "$T/status-profile"
for _profile_key in upstreams fallbacks routes bootstrap; do
  case "$_profile_key" in
    upstreams) _profile_value=$_profile_upstreams ;;
    fallbacks) _profile_value=$_profile_fallbacks ;;
    routes) _profile_value=$_profile_routes ;;
    bootstrap) _profile_value=$_profile_bootstrap ;;
  esac
  _profile_b64=$(printf '%s' "$_profile_value" | base64 | tr -d '\n')
  assert_contains "doh.state persists full profile $_profile_key safely" "$Z2K_DOH_STATE_FILE" "profile_${_profile_key}_b64=$_profile_b64"
  _status_b64=$(tr ' ' '\n' < "$T/status-profile" | sed -n "s/^profile_${_profile_key}_b64=//p")
  _restored=$(printf '%s' "$_status_b64" | base64 -d 2>/dev/null)
  assert_eq "status restores profile $_profile_key after reload" "$_profile_value" "$_restored"
done
_profile_codec_sample='https://one.example/dns-query?token=a=b
h3://two.example
2001:4860:4860::8888'
_profile_codec_expected=$(printf '%s' "$_profile_codec_sample" | base64 | tr -d '\n')
_profile_codec_actual=$(Z2K_DOH_BASE64_BIN=missing _z2k_ow_doh_base64_encode "$_profile_codec_sample")
assert_eq 'profile state codec works when stock OpenWrt omits base64 and od applets' "$_profile_codec_expected" "$_profile_codec_actual"
assert_contains 'status restores profile mode after reload' "$T/status-profile" 'profile_mode=parallel'
assert_contains 'mixed DoH upstream with query parameters reaches dnsproxy UCI' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='https://one.example/dns-query?token=a=b'"
assert_contains 'mixed DoH3 upstream reaches dnsproxy UCI' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='h3://two.example/dns-query'"
assert_contains 'mixed DoT upstream reaches dnsproxy UCI' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='tls://three.example'"
assert_contains 'mixed DoQ upstream reaches dnsproxy UCI' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='quic://four.example:853'"
assert_contains 'mixed DNSCrypt upstream reaches dnsproxy UCI' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='sdns://"
assert_contains 'fallbacks use actual dnsproxy fallback list option' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.fallback='tls://fallback.example'"
assert_contains 'domain route uses dnsproxy upstream syntax' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='[/example.org/]tls://route.example'"
assert_contains 'profile writes actual dnsproxy upstream mode option' "$Z2K_DOH_TEST_DB" "dnsproxy.global.upstream_mode='parallel'"
assert_contains 'plain DoH does not get silently forced to HTTP/3' "$Z2K_DOH_TEST_DB" "dnsproxy.global.http3='0'"
assert_contains 'profile writes bootstrap IP list' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.bootstrap='2001:4860:4860::8888'"
assert_eq 'profile rejects hostname upstream without global bootstrap' 1 "$(z2k_ow_doh_apply_profile 'tls://bootstrap-required.example' '' '' parallel '' 0 >/dev/null 2>&1; echo $?)"
assert_eq 'profile keeps a literal IP upstream when bootstrap is empty' 0 "$(z2k_ow_doh_apply_profile 'tls://198.51.100.53' '' '' parallel '' 0 >/dev/null 2>&1; echo $?)"
assert_contains 'profile does not replace literal IP upstream' "$Z2K_DOH_TEST_DB" "dnsproxy.servers.upstream='tls://198.51.100.53'"
assert_not_contains 'literal IP profile has no generated bootstrap' "$Z2K_DOH_TEST_DB" 'dnsproxy\.servers\.bootstrap='
# dnsproxy fastest_addr returns the lowest-latency IP among the addresses it receives.
for _mode in load_balance fastest_addr; do
  assert_eq "profile accepts $_mode mode" 0 "$(z2k_ow_doh_apply_profile 'tls://mode.example' '' '' "$_mode" 8.8.8.8 0 >/dev/null 2>&1; echo $?)"
  assert_contains "$_mode is written to dnsproxy's native UCI option" "$Z2K_DOH_TEST_DB" "dnsproxy.global.upstream_mode='$_mode'"
done
assert_eq 'profile rejects plaintext fallback' 1 "$(z2k_ow_doh_apply_profile 'https://secure.example/dns-query' '8.8.8.8' '' load_balance 8.8.8.8 0 >/dev/null 2>&1; echo $?)"
assert_eq 'profile rejects unknown upstream mode' 1 "$(z2k_ow_doh_apply_profile 'https://secure.example/dns-query' '' '' random 8.8.8.8 0 >/dev/null 2>&1; echo $?)"
cp "$Z2K_DOH_TEST_DB" "$T/profile-before-failure"
: > "$T/upstream-fail"
assert_eq 'failed profile health check aborts profile application' 1 "$(z2k_ow_doh_apply_profile 'tls://failed.example' 'quic://fallback.example' 'example.org=h3://route.example' fastest_addr 8.8.8.8 0 >/dev/null 2>&1; echo $?)"
grep '^dnsproxy\.' "$T/profile-before-failure" > "$T/profile-before-lines"
grep '^dnsproxy\.' "$Z2K_DOH_TEST_DB" > "$T/profile-after-lines"
cmp -s "$T/profile-before-lines" "$T/profile-after-lines" && _t_ok || _t_bad 'failed profile restores the prior dnsproxy UCI'
assert_contains 'failed profile preserves TikTok dnsmasq override' "$Z2K_DOH_TEST_DB" "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.9'"
rm -f "$T/upstream-fail"

_t_done
