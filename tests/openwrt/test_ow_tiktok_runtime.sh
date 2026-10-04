#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tiktok-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tiktok.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH"
export UCI_TEST_DB="$T/uci.db" UCI_TEST_LOG="$T/uci.log" DNSMASQ_TEST_LOG="$T/dnsmasq.log"
export CURL_TEST_LOG="$T/curl.log"
export NSLOOKUP_TEST_LOG="$T/nslookup.log"
export TIKTOK_DNS_IP="143.244.42.18" TIKTOK_PROBE_MODE=ok
export Z2K_STATE="$T/state"
export Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-cdn-hosts"
export Z2K_TIKTOK_UCI_MARKER="$T/state/.tiktok-addnhosts-owned"
export Z2K_TIKTOK_CONTENT_MARKER="$T/state/.tiktok-host-content-owned"
export Z2K_TIKTOK_STATE_FILE="$T/state/tiktok-cdn.state"
export Z2K_TIKTOK_CONFIG="$T/config"
export Z2K_TIKTOK_APPLY_LOCK="$T/state/apply.lock"
export Z2K_TIKTOK_DNSMASQ_INIT="$T/dnsmasq-init"
export Z2K_TIKTOK_UCI_BIN=uci Z2K_TIKTOK_CURL_BIN=curl Z2K_TIKTOK_NSLOOKUP_BIN=nslookup
printf "dhcp.cfg0001='dnsmasq'\n" > "$UCI_TEST_DB"
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$Z2K_TIKTOK_CONFIG"
printf 'nameserver 1.1.1.1\n' > "$T/resolv.auto"
export Z2K_TIKTOK_RESOLVER_STATE="$T/resolv.auto" Z2K_TIKTOK_RESOLVER_FALLBACK="$T/no-fallback"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$UCI_TEST_LOG"
case "$*" in
    "-q show dhcp.@dnsmasq[0]") exit 0 ;;
    "-q show dhcp") cat "$UCI_TEST_DB" ;;
    "commit dhcp") exit 0 ;;
    "add_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#*=}
        printf "dhcp.@dnsmasq[0].addnhosts='%s'\n" "$_path" >> "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#*=}
        awk -v path="$_path" 'index($0, ".addnhosts=\047" path "\047") == 0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf '%s -> %s\n' "$2" "$1" >> "$NSLOOKUP_TEST_LOG"
printf 'Server: %s\nAddress: %s:53\n\nNon-authoritative answer:\nName: %s\nAddress: %s\n' "$2" "$2" "$1" "$TIKTOK_DNS_IP"
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
_resolve=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --resolve ]; then _resolve=$2; shift 2; continue; fi
    shift
done
_ip=${_resolve##*:}
_prior_ip_probes=$(grep -Fx "$_ip" "$CURL_TEST_LOG" 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$_ip" >> "$CURL_TEST_LOG"
if [ "${TIKTOK_PROBE_WAIT:-0}" = 1 ]; then
    : > "$TIKTOK_PROBE_STARTED"
    while [ ! -e "$TIKTOK_PROBE_RELEASE" ]; do sleep 0.05; done
fi
if [ "${TIKTOK_PROBE_MODE:-ok}" = fail ]; then exit 28; fi
if [ "${TIKTOK_FAIL_STABILITY:-}" = "$_ip" ] && [ "${_prior_ip_probes:-0}" -ge 1 ]; then exit 28; fi
case "$_ip" in
    143.244.42.18)
        case "${TIKTOK_PROBE_MODE:-ok}" in ok|slow) ;; *) exit 28 ;; esac
        [ "${TIKTOK_PROBE_MODE:-ok}" = fail ] && exit 28
        printf 'HTTP/2 200\r\nX-77-POP: ams\r\nX-77-Cache: HIT\r\nServer: edge\r\n\nZ2M_TIKTOK_METRICS:200|0.020000|0.030000|0.080000'
        exit 0 ;;
    203.0.113.20)
        case "${TIKTOK_PROBE_MODE:-ok}" in alt) _total=0.035000; _pop=fra ;; slow) _total=0.055000; _pop=fra ;; *) exit 28 ;; esac
        printf 'HTTP/2 200\r\nX-77-POP: %s\r\nX-77-Cache: HIT\r\nServer: edge\r\n\nZ2M_TIKTOK_METRICS:200|0.010000|0.020000|%s' "$_pop" "$_total"
        exit 0 ;;
    *) exit 28 ;;
esac
STUB
cat > "$Z2K_TIKTOK_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_TEST_LOG"
[ "${1:-}" = reload ]
STUB
chmod 0755 "$T/bin/uci" "$T/bin/nslookup" "$T/bin/curl" "$Z2K_TIKTOK_DNSMASQ_INIT"

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tiktok.sh"
z2k_ow_tiktok_check || _t_bad "initial TikTok CDN selection succeeds"
assert_contains "owned dnsmasq include is registered" "$UCI_TEST_DB" "$Z2K_TIKTOK_HOSTS_FILE"
assert_contains "verified CDN is pinned with hosts syntax" "$Z2K_TIKTOK_HOSTS_FILE" '143.244.42.18 v77.tiktokcdn.com'
assert_contains "state records healthy selection" "$Z2K_TIKTOK_STATE_FILE" 'state=healthy'
assert_contains "state records selected CDN" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'
assert_contains "state persists the full discovery candidate pool" "$Z2K_TIKTOK_STATE_FILE" 'candidate_pool='
assert_contains "state persists resolver discovery inputs" "$Z2K_TIKTOK_STATE_FILE" 'resolver_sources=1.1.1.1'
assert_contains "state persists per-query DNS outcomes" "$Z2K_TIKTOK_STATE_FILE" '__QUERY__|v77.tiktokcdn.com'
assert_contains "state persists probe observations" "$Z2K_TIKTOK_STATE_FILE" 'probe_observations='
assert_file "ownership marker is persistent" "$Z2K_TIKTOK_UCI_MARKER"
assert_contains "TLS/SNI probe headers and metrics are retained" "$Z2K_TIKTOK_STATE_FILE" 'x77_pop=ams'
assert_contains "selected candidate source metadata is retained" "$Z2K_TIKTOK_STATE_FILE" 'selected_source_domain=v77.tiktokcdn.com'
assert_contains "selected candidate retains all observed domains" "$Z2K_TIKTOK_STATE_FILE" 'selected_domains=v77.tiktokcdn.com,v16-cla.tiktokcdn.com,v16-ies-music.tiktokcdn.com,sf16-music.tiktokcdn-eu.com'
assert_contains "selected candidate merges DNS and curated provenance" "$Z2K_TIKTOK_STATE_FILE" 'selected_modes=direct,cla,ies,generic,curated'
assert_contains "selected candidate retains DNS and fallback evidence" "$Z2K_TIKTOK_STATE_FILE" 'dns_observed=1'
assert_contains "selected candidate records curated observation" "$Z2K_TIKTOK_STATE_FILE" 'curated_observed=1'
assert_contains "stable selection records a last verified epoch" "$Z2K_TIKTOK_STATE_FILE" 'last_verified_epoch='
assert_contains "TLS handshake time is recorded from SNI probe" "$Z2K_TIKTOK_STATE_FILE" 'tls_latency_ms=30'
assert_contains "HTTP response and CDN POP headers are recorded" "$Z2K_TIKTOK_STATE_FILE" 'http_status=200'
assert_eq "best initial candidate is repeated for stability" '2' "$(grep -c '^143.244.42.18$' "$CURL_TEST_LOG")"

# A healthy candidate inside the 3600-second lease is probed directly without
# rediscovery; scheduled and explicit checks still perform full evaluation.
_queries_before=$(wc -l < "$UCI_TEST_LOG")
z2k_ow_tiktok_check automatic || _t_bad "healthy lease fast path succeeds"
assert_contains "healthy lease refreshes verification timestamp" "$Z2K_TIKTOK_STATE_FILE" 'reason=current-ip-fast-path'

# An expired 3600-second lease leaves fast path and runs domain discovery.
sed -i 's/^last_verified_epoch=.*/last_verified_epoch=1/' "$Z2K_TIKTOK_STATE_FILE"
_query_before=$(wc -l < "$NSLOOKUP_TEST_LOG")
z2k_ow_tiktok_check automatic || _t_bad "expired lease triggers an evaluation"
_query_after=$(wc -l < "$NSLOOKUP_TEST_LOG")
[ "$_query_after" -gt "$_query_before" ] && _t_ok || _t_bad "expired lease rediscovers CDN candidates"

# A modest latency improvement is insufficient until both source hysteresis
# conditions pass, and the current selection metadata must remain selected.
TIKTOK_PROBE_MODE=slow TIKTOK_DNS_IP=203.0.113.20
z2k_ow_tiktok_check explicit || _t_bad "healthy-current hysteresis evaluation succeeds"
assert_contains "insufficient improvement keeps incumbent" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'
assert_contains "insufficient improvement records hysteresis keep" "$Z2K_TIKTOK_STATE_FILE" 'reason=hysteresis-not-met'
assert_contains "kept incumbent retains its own source metadata" "$Z2K_TIKTOK_STATE_FILE" 'selected_source_domain=v77.tiktokcdn.com'

# The source threshold requires two consecutive failures before scanning and
# selecting an alternate. The alternate is verified again for stability.
TIKTOK_PROBE_MODE=alt TIKTOK_DNS_IP=203.0.113.20
z2k_ow_tiktok_check explicit || _t_bad "first selected-IP failure is handled"
assert_contains "first failure preserves the current candidate" "$Z2K_TIKTOK_STATE_FILE" 'failure_count=1'
assert_contains "first failure preserves the owned DNS pin" "$Z2K_TIKTOK_HOSTS_FILE" '143.244.42.18 v77.tiktokcdn.com'
z2k_ow_tiktok_check explicit || _t_bad "second selected-IP failure triggers failover scan"
assert_contains "verified alternate is selected after threshold" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=203.0.113.20'
assert_contains "stability probe metadata is retained" "$Z2K_TIKTOK_STATE_FILE" 'x77_pop=fra'
assert_contains "alternate uses the source stability repeat count" "$Z2K_TIKTOK_STATE_FILE" 'stability_probe_count=2'
assert_contains "failover records previous and new selected addresses" "$Z2K_TIKTOK_STATE_FILE" 'last_failover_from=143.244.42.18'
assert_contains "failover records destination" "$Z2K_TIKTOK_STATE_FILE" 'last_failover_to=203.0.113.20'
assert_contains "DNS pin follows verified alternate" "$Z2K_TIKTOK_HOSTS_FILE" '203.0.113.20 v77.tiktokcdn.com'

# Repeated failures never erase the last known-good pin: the source fix is
# fail-open before first selection and last-known-good thereafter.
TIKTOK_PROBE_MODE=fail
z2k_ow_tiktok_check explicit || _t_bad "first post-failover failure handled"
z2k_ow_tiktok_check explicit || _t_bad "repeated post-failover failure handled"
assert_contains "repeated failure reports degraded health" "$Z2K_TIKTOK_STATE_FILE" 'state=degraded'
assert_contains "repeated failure retains last known-good override" "$Z2K_TIKTOK_HOSTS_FILE" '203.0.113.20 v77.tiktokcdn.com'

# A user/upstream dnsmasq override has priority. The OpenWrt extension removes
# only its own hosts record and does not delete the foreign setting.
printf "dhcp.@dnsmasq[0].address='/not-v77.tiktokcdn.com/203.0.113.10'\n" >> "$UCI_TEST_DB"
if z2k_ow_tiktok_external_override; then _t_bad "unrelated DNS suffix is not treated as TikTok owner"; else _t_ok; fi
grep -v 'not-v77\.tiktokcdn\.com' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.10'\n" >> "$UCI_TEST_DB"
z2k_ow_tiktok_check || _t_bad "external TikTok DNS owner is accepted"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "owned pin is cleared when an external owner appears"
assert_contains "foreign DNS override remains untouched" "$UCI_TEST_DB" '203.0.113.10'
assert_contains "state exposes external ownership" "$Z2K_TIKTOK_STATE_FILE" 'state=external'

# UCI may put multiple list values on one assignment and dnsmasq address values
# may name several domains before the shared address.
grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].address='/example.org/198.51.100.1' '/v77.tiktokcdn.com/198.51.100.2'\n" >> "$UCI_TEST_DB"
if z2k_ow_tiktok_external_override; then _t_ok; else _t_bad "external owner in later UCI list value is detected"; fi
grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"

# Exact UCI list membership must work when an unrelated addnhosts path precedes
# the adapter-owned include in one `uci show` value.
cp "$UCI_TEST_DB" "$T/uci.before-list-membership"
grep -v '\.addnhosts=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].addnhosts='/etc/other-hosts' '%s'\n" "$Z2K_TIKTOK_HOSTS_FILE" >> "$UCI_TEST_DB"
if _z2k_ow_tiktok_registered; then _t_ok; else _t_bad "registered addnhosts path matches a later list member"; fi
z2k_ow_tiktok_prepare || _t_bad "prepare recognizes owned include in later list position"
cp "$T/uci.before-list-membership" "$UCI_TEST_DB"

grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
z2k_ow_tiktok_disable || _t_bad "TikTok autofix disables cleanly"
[ "$(awk -F= '$1=="Z2K_TIKTOK_FEED_ENABLED"{print $2}' "$Z2K_TIKTOK_CONFIG")" = 1 ] && _t_ok || _t_bad "adapter cleanup leaves config choice to caller"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "disable clears only the owned pin"
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
z2k_ow_tiktok_enable || _t_bad "TikTok autofix re-enables and probes"
assert_contains "re-enable restores verified CDN" "$Z2K_TIKTOK_HOSTS_FILE" '143.244.42.18 v77.tiktokcdn.com'

# A replacement record for the same hostname is foreign until the stored exact
# content ownership proof agrees; disable must preserve that record.
printf '198.51.100.7 v77.tiktokcdn.com\n' > "$Z2K_TIKTOK_HOSTS_FILE"
z2k_ow_tiktok_disable || _t_bad "disable completes while preserving a foreign replacement IP"
if [ "$(cat "$Z2K_TIKTOK_CONTENT_MARKER")" = '143.244.42.18 v77.tiktokcdn.com' ]; then _t_ok; else _t_bad "content ownership marker retains last applied exact entry"; fi
assert_contains "disable preserves the foreign replacement record" "$Z2K_TIKTOK_HOSTS_FILE" '198.51.100.7 v77.tiktokcdn.com'
if z2k_ow_tiktok_prepare; then _t_bad "prepare refuses to overwrite a foreign replacement IP"; else _t_ok; fi
assert_contains "prepare keeps the foreign replacement record intact" "$Z2K_TIKTOK_HOSTS_FILE" '198.51.100.7 v77.tiktokcdn.com'
printf '143.244.42.18 v77.tiktokcdn.com\n' > "$Z2K_TIKTOK_HOSTS_FILE"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"

# Periodic lifecycle guard: a check that overlaps service stop may finish its
# network probes, but it must not be able to write a new DNS pin afterwards.
export Z2K_TIKTOK_REQUIRE_READY="$T/core-ready"
: > "$Z2K_TIKTOK_REQUIRE_READY"
z2k_ow_tiktok_clear || _t_bad "precondition clears the owned pin"
rm -f "$Z2K_TIKTOK_REQUIRE_READY"
z2k_ow_tiktok_check || _t_bad "stopped-service guard returns cleanly"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "stopped-service guard blocks DNS resurrection"
unset Z2K_TIKTOK_REQUIRE_READY

# A real in-flight probe may finish after stop removes core-ready; its result
# must not recreate the DNS pin.
export Z2K_TIKTOK_REQUIRE_READY="$T/core-ready"
: > "$Z2K_TIKTOK_REQUIRE_READY"
rm -f "$T/probe-release"
export TIKTOK_PROBE_WAIT=1 TIKTOK_PROBE_STARTED="$T/probe-started" TIKTOK_PROBE_RELEASE="$T/probe-release"
z2k_ow_tiktok_clear || _t_bad "race precondition clears owned pin"
z2k_ow_tiktok_check explicit >/dev/null 2>&1 &
_check_pid=$!
_wait=0
while [ ! -e "$T/probe-started" ] && [ "$_wait" -lt 100 ]; do sleep 0.05; _wait=$((_wait + 1)); done
if [ -e "$T/probe-started" ]; then _t_ok; else _t_bad "stop race reached a real blocked probe"; fi
rm -f "$Z2K_TIKTOK_REQUIRE_READY"
: > "$T/probe-release"
wait "$_check_pid" || true
unset TIKTOK_PROBE_WAIT TIKTOK_PROBE_STARTED TIKTOK_PROBE_RELEASE Z2K_TIKTOK_REQUIRE_READY
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "in-flight probe cannot resurrect DNS after stop"

# Disabling while a real probe is blocked must prevent its later apply, even
# while the service remains ready.
export Z2K_TIKTOK_REQUIRE_READY="$T/core-ready"
: > "$Z2K_TIKTOK_REQUIRE_READY"
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$Z2K_TIKTOK_CONFIG"
rm -f "$T/probe-started" "$T/probe-release"
export TIKTOK_PROBE_WAIT=1 TIKTOK_PROBE_STARTED="$T/probe-started" TIKTOK_PROBE_RELEASE="$T/probe-release"
z2k_ow_tiktok_check explicit >/dev/null 2>&1 &
_check_pid=$!
_wait=0
while [ ! -e "$T/probe-started" ] && [ "$_wait" -lt 100 ]; do sleep 0.05; _wait=$((_wait + 1)); done
if [ -e "$T/probe-started" ]; then _t_ok; else _t_bad "disable race reached a real blocked probe"; fi
printf 'Z2K_TIKTOK_FEED_ENABLED=0\n' > "$Z2K_TIKTOK_CONFIG"
z2k_ow_tiktok_disable || _t_bad "disable during probe succeeds"
: > "$T/probe-release"
wait "$_check_pid" || true
unset TIKTOK_PROBE_WAIT TIKTOK_PROBE_STARTED TIKTOK_PROBE_RELEASE Z2K_TIKTOK_REQUIRE_READY
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "in-flight probe cannot restore a pin after disable"
assert_contains "in-flight disable leaves feature off" "$Z2K_TIKTOK_STATE_FILE" 'state=off'
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$Z2K_TIKTOK_CONFIG"

# The source loop bounds the original candidate-pool index at 12 before it
# skips the selected IP. A healthy thirteenth candidate must remain excluded.
printf '143.244.42.18 v77.tiktokcdn.com\n' > "$Z2K_TIKTOK_HOSTS_FILE"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"
_now=$(date +%s)
_z2k_ow_tiktok_state_write healthy 143.244.42.18 100 1 1 test-index-bound 1 1 1
_z2k_ow_tiktok_discover_candidates() { :; }
_z2k_ow_tiktok_candidate_pool() {
    printf '143.244.42.18||||||||0|1|0\n'
    for _i in 2 3 4 5 6 7 8 9 10 11 12; do
        printf '198.51.100.%s||||||||0|1|0\n' "$_i"
    done
    printf '203.0.113.20||||||||0|1|0\n'
}
TIKTOK_PROBE_MODE=alt
_curl_start=$(wc -l < "$CURL_TEST_LOG")
z2k_ow_tiktok_check explicit || _t_bad "thirteenth-candidate parity evaluation completes"
assert_contains "candidate beyond source index bound cannot replace the current IP" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'
_tail_curls=$(tail -n "+$((_curl_start + 1))" "$CURL_TEST_LOG")
if printf '%s\n' "$_tail_curls" | grep -Fxq '203.0.113.20'; then
    _t_bad "candidate index 13 is not probed"
else
    _t_ok
fi
TIKTOK_PROBE_MODE=ok
cat > "$Z2K_TIKTOK_STATE_FILE" <<EOF_LEGACY
state=healthy
selected_ip=143.244.42.18
latency_ms=80
failure_count=0
last_verified_epoch=$(date +%s)
EOF_LEGACY
printf '143.244.42.18 v77.tiktokcdn.com\n' > "$Z2K_TIKTOK_HOSTS_FILE"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"
z2k_ow_tiktok_check explicit || _t_bad "legacy selected IP migrates during verification"
assert_contains "legacy selection is labeled with legacy provenance" "$Z2K_TIKTOK_STATE_FILE" 'selected_mode=legacy'
assert_contains "legacy selection source is retained" "$Z2K_TIKTOK_STATE_FILE" 'selected_provenance=legacy'

# The winner's mandatory stability repeat is independent of its first success;
# a failed repeat must reject it and retain the previous selected address.
_current="198.51.100.99"
printf '%s v77.tiktokcdn.com\n' "$_current" > "$Z2K_TIKTOK_HOSTS_FILE"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"
_z2k_ow_tiktok_state_write healthy "$_current" 100 1 1 test-stability-repeat
_z2k_ow_tiktok_candidate_pool() {
    printf '%s||||||||0|0|0\n' "$_current"
    printf '203.0.113.20||||||||0|1|0\n'
}
: > "$CURL_TEST_LOG"
export TIKTOK_PROBE_MODE=alt TIKTOK_FAIL_STABILITY=203.0.113.20
z2k_ow_tiktok_check explicit || _t_bad "failed stability repeat is handled"
assert_contains "failed repeat retains the prior selected IP" "$Z2K_TIKTOK_STATE_FILE" "selected_ip=$_current"
assert_contains "failed repeat is stored in probe observations" "$Z2K_TIKTOK_STATE_FILE" '203.0.113.20|failed'
unset TIKTOK_FAIL_STABILITY

# With no previously verified address and no reachable probes the source
# algorithm fails open to regular DNS and leaves no selected candidate.
rm -f "$Z2K_TIKTOK_STATE_FILE"
TIKTOK_PROBE_MODE=fail
z2k_ow_tiktok_check explicit || _t_bad "initial probe exhaustion is handled"
assert_contains "first-run failure is degraded" "$Z2K_TIKTOK_STATE_FILE" 'state=degraded'
[ -z "$(awk -F= '$1=="selected_ip"{print $2}' "$Z2K_TIKTOK_STATE_FILE")" ] && _t_ok || _t_bad "first-run fail-open has no selected IP"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "first-run fail-open installs no DNS pin"

# If another package has added records to the shared path, uninstall must not
# unregister or delete that file just because the original marker exists.
cp "$UCI_TEST_DB" "$T/uci.before-uninstall"
cp "$Z2K_TIKTOK_UCI_MARKER" "$T/marker.before-uninstall"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$T/hosts.before-uninstall"
printf '198.51.100.9 other-package.example\n' > "$Z2K_TIKTOK_HOSTS_FILE"
if z2k_ow_tiktok_uninstall; then _t_bad "uninstall refuses externally modified owned include"; else _t_ok; fi
assert_contains "uninstall leaves the shared UCI addnhosts registration" "$UCI_TEST_DB" "$Z2K_TIKTOK_HOSTS_FILE"
assert_contains "uninstall preserves the external addnhosts entry" "$Z2K_TIKTOK_HOSTS_FILE" 'other-package.example'
assert_file "uninstall retains ownership marker after refusing foreign content" "$Z2K_TIKTOK_UCI_MARKER"
cp "$T/uci.before-uninstall" "$UCI_TEST_DB"
cp "$T/marker.before-uninstall" "$Z2K_TIKTOK_UCI_MARKER"
cp "$T/hosts.before-uninstall" "$Z2K_TIKTOK_HOSTS_FILE"

z2k_ow_tiktok_uninstall || _t_bad "TikTok adapter cleanup succeeds"
assert_not_contains "uninstall removes only its addnhosts reference" "$UCI_TEST_DB" 'tiktok-cdn-hosts'
[ ! -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes owned TikTok hosts file"
[ ! -e "$Z2K_TIKTOK_UCI_MARKER" ] && _t_ok || _t_bad "uninstall removes TikTok ownership marker"

_t_done
