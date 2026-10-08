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
export CURL_RESOLVE_TEST_LOG="$T/curl-resolve.log"
export CURL_ARGS_TEST_LOG="$T/curl-args.log"
export CURL_PAIR_TEST_LOG="$T/curl-pairs.log"
export NSLOOKUP_TEST_LOG="$T/nslookup.log"
export TIKTOK_DNS_IP="143.244.42.18" TIKTOK_PROBE_MODE=ok
export Z2K_STATE="$T/state"
export Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-cdn-hosts"
export Z2K_TIKTOK_UCI_MARKER="$T/state/.tiktok-addnhosts-owned"
export Z2K_TIKTOK_CONTENT_MARKER="$T/state/.tiktok-host-content-owned"
export Z2K_TIKTOK_ADDRESS_MARKER="$T/state/.tiktok-address-owned"
export Z2K_TIKTOK_EFFECTIVE_CONFIG="$T/dnsmasq.conf"
export Z2K_TIKTOK_STATE_FILE="$T/state/tiktok-cdn.state"
export Z2K_TIKTOK_CONFIG="$T/config"
export Z2K_TIKTOK_APPLY_LOCK="$T/state/apply.lock"
export Z2K_TIKTOK_DNSMASQ_INIT="$T/dnsmasq-init"
export Z2K_TIKTOK_CHECKHOST_ENABLED=0
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
    "add_list dhcp.@dnsmasq[0].address="*)
        _entry=${2#*=}
        printf "dhcp.@dnsmasq[0].address='%s'\n" "$_entry" >> "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#*=}
        awk -v path="$_path" '
            $0 ~ /\.addnhosts=/ {
                key=substr($0, 1, index($0, "=")-1)
                value=substr($0, index($0, "=")+1)
                needle="\047" path "\047"
                gsub(needle, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value != "") print key "=" value
                next
            }
            { print }
        ' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].address="*)
        _entry=${2#*=}
        awk -v entry="$_entry" 'index($0, ".address=\047" entry "\047") == 0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf '%s -> %s\n' "$2" "$1" >> "$NSLOOKUP_TEST_LOG"
_ip=${TIKTOK_DNS_IP}
if [ "$2" = 127.0.0.1 ]; then
    _ip=$(sed -n "s#^address=/$1/##p" "$Z2K_TIKTOK_EFFECTIVE_CONFIG" 2>/dev/null | tail -1)
    [ -n "$_ip" ] || _ip=${TIKTOK_LOCAL_DNS_IP:-$TIKTOK_DNS_IP}
fi
printf 'Server: %s\nAddress: %s:53\n\nNon-authoritative answer:\nName: %s\nAddress: %s\n' "$2" "$2" "$1" "$_ip"
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
_resolve=""
printf '%s\n' "$*" >> "$CURL_ARGS_TEST_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --resolve ]; then _resolve=$2; printf '%s\n' "$2" >> "$CURL_RESOLVE_TEST_LOG"; shift 2; continue; fi
    shift
done
_ip=${_resolve##*:}
_host=${_resolve%%:443:*}
_prior_ip_probes=$(grep -Fx "$_resolve" "$CURL_PAIR_TEST_LOG" 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$_ip" >> "$CURL_TEST_LOG"
printf '%s\n' "$_resolve" >> "$CURL_PAIR_TEST_LOG"
if [ "${TIKTOK_PROBE_WAIT:-0}" = 1 ] \
    || { [ "${TIKTOK_PROBE_WAIT_IP:-}" = "$_ip" ] \
        && { [ -z "${TIKTOK_PROBE_WAIT_HOST:-}" ] || [ "${TIKTOK_PROBE_WAIT_HOST:-}" = "$_host" ]; }; }; then
    : > "$TIKTOK_PROBE_STARTED"
    while [ ! -e "$TIKTOK_PROBE_RELEASE" ]; do sleep 0.05; done
fi
if [ "${TIKTOK_PROBE_MODE:-ok}" = fail ]; then exit 28; fi
if [ "${TIKTOK_FAIL_HOST:-}" = "$_host" ]; then exit 28; fi
if [ "${TIKTOK_FAIL_IP_HOST:-}" = "$_host=$_ip" ]; then exit 28; fi
if [ "${TIKTOK_FAIL_STABILITY:-}" = "$_ip" ] && [ "${_prior_ip_probes:-0}" -ge 1 ]; then exit 28; fi
case "$_ip" in
    143.244.42.18)
        case "${TIKTOK_PROBE_MODE:-ok}" in ok|slow) ;; *) exit 28 ;; esac
        [ "${TIKTOK_PROBE_MODE:-ok}" = fail ] && exit 28
        _http=${TIKTOK_HTTP_CODE:-200}
        printf 'HTTP/2 %s\r\nX-77-POP: ams\r\nX-77-Cache: HIT\r\nServer: edge\r\n\nZ2M_TIKTOK_METRICS:%s|0.020000|0.030000|0.080000' "$_http" "$_http"
        exit 0 ;;
    203.0.113.20)
        case "${TIKTOK_PROBE_MODE:-ok}" in
            alt) _total=0.035000; _pop=fra ;;
            slow) _total=0.055000; _pop=fra ;;
            ok) [ "${TIKTOK_ALLOW_IP:-}" = "$_ip" ] || exit 28; _total=0.035000; _pop=fra ;;
            *) exit 28 ;;
        esac
        printf 'HTTP/2 200\r\nX-77-POP: %s\r\nX-77-Cache: HIT\r\nServer: edge\r\n\nZ2M_TIKTOK_METRICS:200|0.010000|0.020000|%s' "$_pop" "$_total"
        exit 0 ;;
    *) exit 28 ;;
esac
STUB
cat > "$Z2K_TIKTOK_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_TEST_LOG"
[ "${1:-}" = restart ] || exit 1
[ "${DNSMASQ_FAIL_RESTART:-0}" = 1 ] && exit 1
if [ -n "${DNSMASQ_FAIL_ENTRY:-}" ] && grep -F "$DNSMASQ_FAIL_ENTRY" "$UCI_TEST_DB" >/dev/null 2>&1; then
    printf 'injected-failure=%s\n' "$DNSMASQ_FAIL_ENTRY" >> "$DNSMASQ_TEST_LOG"
    exit 1
fi
: > "$Z2K_TIKTOK_EFFECTIVE_CONFIG"
while IFS= read -r _line; do
    case "$_line" in
        *.address=*)
            _entry=${_line#*=}
            _entry=$(printf '%s' "$_entry" | tr -d "'\"")
            printf 'address=%s\n' "$_entry" >> "$Z2K_TIKTOK_EFFECTIVE_CONFIG"
            ;;
    esac
done < "$UCI_TEST_DB"
STUB
chmod 0755 "$T/bin/uci" "$T/bin/nslookup" "$T/bin/curl" "$Z2K_TIKTOK_DNSMASQ_INIT"

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tiktok.sh"
export TIKTOK_FAIL_HOST=v77.tiktokcdn-eu.com
if z2k_ow_tiktok_manual_select 143.244.42.18; then
    _t_bad "manual choice rejects a CDN that fails TLS/SNI for the EU target"
else
    _t_ok
fi
assert_eq "manual target-specific rejection does not persist manual mode" 'auto' "$(z2k_ow_tiktok_mode)"
unset TIKTOK_FAIL_HOST
: > "$CURL_TEST_LOG"
z2k_ow_tiktok_check || _t_bad "initial TikTok CDN selection succeeds"
assert_contains "verified CDN uses the native dnsmasq address override" "$UCI_TEST_DB" '/v77.tiktokcdn.com/143.244.42.18'
assert_contains "effective dnsmasq config contains the selected IP" "$Z2K_TIKTOK_EFFECTIVE_CONFIG" 'address=/v77.tiktokcdn.com/143.244.42.18'
assert_not_contains "new runtime does not register the legacy addnhosts file" "$UCI_TEST_DB" 'tiktok-cdn-hosts'
assert_contains "state records healthy selection" "$Z2K_TIKTOK_STATE_FILE" 'state=healthy'
assert_contains "state separates successful target verification" "$Z2K_TIKTOK_STATE_FILE" 'candidate_verified=1'
assert_contains "state confirms effective DNS application" "$Z2K_TIKTOK_STATE_FILE" 'dns_override_applied=1'
assert_contains "state records selected CDN" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'
assert_contains "state persists the full discovery candidate pool" "$Z2K_TIKTOK_STATE_FILE" 'candidate_pool='
assert_contains "state persists resolver discovery inputs" "$Z2K_TIKTOK_STATE_FILE" 'resolver_sources=1.1.1.1'
assert_contains "state persists per-query DNS outcomes" "$Z2K_TIKTOK_STATE_FILE" '__QUERY__|v77.tiktokcdn.com'
assert_contains "state persists probe observations" "$Z2K_TIKTOK_STATE_FILE" 'probe_observations='
assert_file "native DNS ownership marker is persistent" "$Z2K_TIKTOK_ADDRESS_MARKER"
assert_contains "native override always uses the managed target for TLS/SNI" "$CURL_TEST_LOG" '143.244.42.18'
assert_contains "TLS/SNI probe headers and metrics are retained" "$Z2K_TIKTOK_STATE_FILE" 'x77_pop=ams'
assert_contains "selected candidate source metadata is retained" "$Z2K_TIKTOK_STATE_FILE" 'selected_source_domain=v77.tiktokcdn.com'
assert_contains "selected candidate retains all observed domains" "$Z2K_TIKTOK_STATE_FILE" 'selected_domains=v77.tiktokcdn.com,v77.tiktokcdn-eu.com,v16-cla.tiktokcdn.com,v16-ies-music.tiktokcdn.com,sf16-music.tiktokcdn-eu.com'
assert_contains "selected candidate merges DNS and curated provenance" "$Z2K_TIKTOK_STATE_FILE" 'selected_modes=direct,cla,ies,generic,curated'
assert_contains "selected candidate retains DNS and fallback evidence" "$Z2K_TIKTOK_STATE_FILE" 'dns_observed=1'
assert_contains "selected candidate records curated observation" "$Z2K_TIKTOK_STATE_FILE" 'curated_observed=1'
assert_contains "stable selection records a last verified epoch" "$Z2K_TIKTOK_STATE_FILE" 'last_verified_epoch='
assert_contains "TLS handshake time is recorded from SNI probe" "$Z2K_TIKTOK_STATE_FILE" 'tls_latency_ms=30'
assert_contains "HTTP response and CDN POP headers are recorded" "$Z2K_TIKTOK_STATE_FILE" 'http_status=200'
assert_eq "both managed targets are tested twice for stable selection" '4' "$(grep -c '^143.244.42.18$' "$CURL_TEST_LOG")"
assert_contains "both managed target dnsmasq overrides are owned" "$UCI_TEST_DB" '/v77.tiktokcdn-eu.com/143.244.42.18'

# All five canonical CDN domains must be probed with their own SNI/Host.
for _host in v77.tiktokcdn.com v77.tiktokcdn-eu.com v16-cla.tiktokcdn.com v16-ies-music.tiktokcdn.com sf16-music.tiktokcdn-eu.com; do
    if _probe=$(_z2k_ow_tiktok_probe_report 143.244.42.18 "$_host"); then
        _t_ok
    else
        _t_bad "hostname-specific TLS probe accepts $_host"
    fi
done
assert_contains "v16-cla probe pins SNI to its hostname" "$CURL_RESOLVE_TEST_LOG" 'v16-cla.tiktokcdn.com:443:143.244.42.18'
assert_contains "v16-ies probe pins SNI to its hostname" "$CURL_RESOLVE_TEST_LOG" 'v16-ies-music.tiktokcdn.com:443:143.244.42.18'
assert_contains "sf16 probe pins SNI to its hostname" "$CURL_RESOLVE_TEST_LOG" 'sf16-music.tiktokcdn-eu.com:443:143.244.42.18'

# An HTTP 403/404 from the CDN root is still an observed HTTP response, and
# never claims that an actual media object was delivered.
export TIKTOK_HTTP_CODE=403
if _probe=$(_z2k_ow_tiktok_probe_report 143.244.42.18 v16-cla.tiktokcdn.com); then _t_ok; else _t_bad "HTTP 403 does not invalidate confirmed transport"; fi
assert_eq "root HTTP status remains available for diagnostics" '403' "$(printf '%s' "$_probe" | cut -d'|' -f5)"
unset TIKTOK_HTTP_CODE

# A successful TLS probe is not enough to report healthy when applying the
# effective dnsmasq address fails.
export DNSMASQ_FAIL_RESTART=1
if z2k_ow_tiktok_check explicit; then _t_bad "dnsmasq restart failure is reported"; else _t_ok; fi
assert_contains "failed DNS apply has its own state" "$Z2K_TIKTOK_STATE_FILE" 'state=dns-apply-error'
assert_contains "failed DNS apply preserves candidate verification" "$Z2K_TIKTOK_STATE_FILE" 'candidate_verified=1'
assert_contains "failed DNS apply is explicitly false" "$Z2K_TIKTOK_STATE_FILE" 'dns_override_applied=0'
unset DNSMASQ_FAIL_RESTART
z2k_ow_tiktok_check explicit || _t_bad "DNS apply recovers after restart failure is removed"

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
assert_contains "first failure preserves the owned DNS override" "$UCI_TEST_DB" '/v77.tiktokcdn.com/143.244.42.18'
z2k_ow_tiktok_check explicit || _t_bad "second selected-IP failure triggers failover scan"
assert_contains "verified alternate is selected after threshold" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=203.0.113.20'
assert_contains "stability probe metadata is retained" "$Z2K_TIKTOK_STATE_FILE" 'x77_pop=fra'
assert_contains "alternate uses the source stability repeat count" "$Z2K_TIKTOK_STATE_FILE" 'stability_probe_count=2'
assert_contains "failover records previous and new selected addresses" "$Z2K_TIKTOK_STATE_FILE" 'last_failover_from=143.244.42.18'
assert_contains "failover records destination" "$Z2K_TIKTOK_STATE_FILE" 'last_failover_to=203.0.113.20'
assert_contains "DNS override follows verified alternate" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'
assert_contains "effective config follows verified failover" "$Z2K_TIKTOK_EFFECTIVE_CONFIG" 'address=/v77.tiktokcdn.com/203.0.113.20'

# Repeated failures never erase the last known-good pin: the source fix is
# fail-open before first selection and last-known-good thereafter.
TIKTOK_PROBE_MODE=fail
z2k_ow_tiktok_check explicit || _t_bad "first post-failover failure handled"
z2k_ow_tiktok_check explicit || _t_bad "repeated post-failover failure handled"
assert_contains "repeated failure reports degraded health" "$Z2K_TIKTOK_STATE_FILE" 'state=degraded'
assert_contains "repeated failure retains last known-good override" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'

# A user/upstream dnsmasq override has priority. The OpenWrt extension removes
# only its own hosts record and does not delete the foreign setting.
printf "dhcp.@dnsmasq[0].address='/not-v77.tiktokcdn.com/203.0.113.10'\n" >> "$UCI_TEST_DB"
if z2k_ow_tiktok_external_override; then _t_bad "unrelated DNS suffix is not treated as TikTok owner"; else _t_ok; fi
grep -v 'not-v77\.tiktokcdn\.com' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.10'\n" >> "$UCI_TEST_DB"
z2k_ow_tiktok_check || _t_bad "external TikTok DNS owner is accepted"
[ -z "$(grep -F '/v77.tiktokcdn.com/203.0.113.20' "$UCI_TEST_DB" 2>/dev/null)" ] && _t_ok || _t_bad "owned override is cleared when an external owner appears"
assert_contains "foreign DNS override remains untouched" "$UCI_TEST_DB" '203.0.113.10'
assert_contains "state exposes external ownership" "$Z2K_TIKTOK_STATE_FILE" 'state=external'

# UCI may put multiple list values on one assignment and dnsmasq address values
# may name several domains before the shared address.
grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].address='/example.org/198.51.100.1' '/v77.tiktokcdn.com/198.51.100.2'\n" >> "$UCI_TEST_DB"
if z2k_ow_tiktok_external_override; then _t_ok; else _t_bad "external owner in later UCI list value is detected"; fi
grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"

# Legacy addnhosts entries are migrated without removing a foreign list value.
cp "$UCI_TEST_DB" "$T/uci.before-list-membership"
grep -v '\.addnhosts=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
printf "dhcp.@dnsmasq[0].addnhosts='/etc/other-hosts' '%s'\n" "$Z2K_TIKTOK_HOSTS_FILE" >> "$UCI_TEST_DB"
printf '%s\n' "$Z2K_TIKTOK_HOSTS_FILE" > "$Z2K_TIKTOK_UCI_MARKER"
printf '203.0.113.20 v77.tiktokcdn.com\n' > "$Z2K_TIKTOK_HOSTS_FILE"
cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"
_z2k_ow_tiktok_state_write healthy 203.0.113.20 35 0 1 migration-test
z2k_ow_tiktok_prepare || _t_bad "prepare migrates the owned legacy include"
assert_not_contains "migration removes the old TikTok addnhosts reference" "$UCI_TEST_DB" "$Z2K_TIKTOK_HOSTS_FILE"
assert_contains "migration preserves the other addnhosts value" "$UCI_TEST_DB" '/etc/other-hosts'
assert_contains "migration preserves the selected address in native config" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'
[ ! -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "migration removes the owned legacy file"
cp "$T/uci.before-list-membership" "$UCI_TEST_DB"

grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
z2k_ow_tiktok_disable || _t_bad "TikTok autofix disables cleanly"
[ "$(awk -F= '$1=="Z2K_TIKTOK_FEED_ENABLED"{print $2}' "$Z2K_TIKTOK_CONFIG")" = 1 ] && _t_ok || _t_bad "adapter cleanup leaves config choice to caller"
[ -z "$(grep -F '/v77.tiktokcdn.com/' "$UCI_TEST_DB" 2>/dev/null)" ] && _t_ok || _t_bad "disable clears the owned native override"
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
z2k_ow_tiktok_enable || _t_bad "TikTok autofix re-enables and probes"
assert_contains "re-enable restores verified CDN" "$UCI_TEST_DB" '/v77.tiktokcdn.com/143.244.42.18'

# Manual mode persists a chosen candidate, re-probes it against the target,
# and keeps auto selection from silently changing it.
TIKTOK_PROBE_MODE=alt TIKTOK_DNS_IP=203.0.113.20
export Z2K_JOB_ID=manual-progress-regression
_manual_started=$(date +%s)
z2k_ow_tiktok_manual_select 203.0.113.20 2> "$T/manual-progress.log" || _t_bad "manual selection re-verifies and applies the candidate"
_manual_finished=$(date +%s)
assert_contains "manual apply logs the target-specific recheck" "$T/manual-progress.log" 'перепроверяю выбранный 203.0.113.20'
assert_contains "manual apply logs the owned DNS apply stage" "$T/manual-progress.log" 'применяю owned dnsmasq override'
assert_contains "manual apply logs effective DNS confirmation" "$T/manual-progress.log" 'effective DNS подтверждает 203.0.113.20'
unset Z2K_JOB_ID
assert_contains "manual choice persists its mode" "$Z2K_TIKTOK_CONFIG" 'Z2K_TIKTOK_MODE=manual'
assert_contains "manual choice persists its IP" "$Z2K_TIKTOK_CONFIG" 'Z2K_TIKTOK_MANUAL_IP=203.0.113.20'
assert_contains "manual choice applies a native target override" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'
assert_contains "manual choice is effective in dnsmasq config" "$Z2K_TIKTOK_EFFECTIVE_CONFIG" 'address=/v77.tiktokcdn.com/203.0.113.20'
assert_contains "manual choice records candidate verification" "$Z2K_TIKTOK_STATE_FILE" 'candidate_verified=1'
assert_contains "manual choice records effective DNS application" "$Z2K_TIKTOK_STATE_FILE" 'dns_override_applied=1'
_manual_selected_at=$(sed -n 's/^selected_at_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")
_manual_verified_at=$(sed -n 's/^last_verified_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")
case "$_manual_selected_at:$_manual_verified_at" in *[!0-9:]*) _t_bad "manual timestamps are valid epoch seconds" ;; *)
    [ "$_manual_selected_at" -ge "$_manual_started" ] && [ "$_manual_selected_at" -le "$_manual_finished" ] \
        && _t_ok || _t_bad "manual selection timestamp records the completed production apply"
    [ "$_manual_verified_at" -ge "$_manual_started" ] && [ "$_manual_verified_at" -le "$_manual_finished" ] \
        && _t_ok || _t_bad "manual verification timestamp records the completed production apply" ;;
esac
# Re-checking the same preferred IP updates verification time, never selection
# time. Use a deterministic clock so the regression cannot pass by coincidence.
date() {
    if [ "${1:-}" = +%s ] && [ -n "${TIKTOK_NOW:-}" ]; then printf '%s\n' "$TIKTOK_NOW"; else command date "$@"; fi
}
_manual_selected_at=$(sed -n 's/^selected_at_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")
TIKTOK_NOW=$((_manual_selected_at + 1800))
z2k_ow_tiktok_manual_check || _t_bad "repeated manual health-check succeeds"
assert_eq "repeated manual health-check preserves original selection epoch" "$_manual_selected_at" "$(sed -n 's/^selected_at_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")"
unset TIKTOK_NOW

# Legacy state writes that omit a selection event preserve the prior epoch;
# they never substitute the latest verification time.
_manual_selected_at=$(sed -n 's/^selected_at_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")
_z2k_ow_tiktok_state_write healthy 203.0.113.20 40 0 200 timestamp-regression
assert_eq "state writer does not infer selection time from verification time" "$_manual_selected_at" "$(sed -n 's/^selected_at_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")"
_restart_choice=$(sh -c '. "$1"; printf "%s|%s" "$(z2k_ow_tiktok_mode)" "$( _z2k_ow_tiktok_manual_ip)"' sh "$REPO/platform/openwrt/tiktok.sh")
assert_eq "manual mode and selected IP survive a runtime restart" 'manual|203.0.113.20' "$_restart_choice"
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
z2k_ow_tiktok_check explicit || _t_bad "scheduled verification keeps manual mode"
assert_contains "auto evaluation does not overwrite a manual selection" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=203.0.113.20'
assert_contains "manual selection remains the effective address" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'
assert_contains "unavailable manual candidate remains selected" "$Z2K_TIKTOK_STATE_FILE" 'state=manual-unavailable'
if z2k_ow_tiktok_manual_select 185.11.78.47; then _t_bad "manual selection rejects an unverified candidate"; else _t_ok; fi
assert_contains "rejected manual IP does not replace persisted choice" "$Z2K_TIKTOK_CONFIG" 'Z2K_TIKTOK_MANUAL_IP=203.0.113.20'
assert_contains "failed manual recheck does not replace the old DNS address" "$UCI_TEST_DB" '/v77.tiktokcdn.com/203.0.113.20'
export Z2K_JOB_ID=auto-progress-regression
z2k_ow_tiktok_use_auto 2> "$T/auto-progress.log" || _t_bad "returning to auto restores normal selection"
assert_contains "return to auto logs the mode change" "$T/auto-progress.log" 'возвращаю режим auto'
assert_contains "return to auto logs the normal selection pipeline" "$T/auto-progress.log" 'запускаю штатный discovery'
unset Z2K_JOB_ID
assert_contains "auto mode clears the manual IP" "$Z2K_TIKTOK_CONFIG" 'Z2K_TIKTOK_MANUAL_IP='
assert_contains "auto mode is persisted" "$Z2K_TIKTOK_CONFIG" 'Z2K_TIKTOK_MODE=auto'
assert_contains "auto selection returns to the live verified candidate" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'

# Returning to auto must serialize its persistent mode/IP writes against an
# in-flight manual apply, then start the normal selection only after unlock.
cp "$Z2K_TIKTOK_CONFIG" "$T/auto-lock.config"
sed -i 's/^Z2K_TIKTOK_MODE=.*/Z2K_TIKTOK_MODE=manual/' "$T/auto-lock.config"
sed -i 's/^Z2K_TIKTOK_MANUAL_IP=.*/Z2K_TIKTOK_MANUAL_IP=203.0.113.20/' "$T/auto-lock.config"
if Z2K_TIKTOK_CONFIG="$T/auto-lock.config" sh -c '
    . "$1"
    lock_held=0
    _z2k_ow_tiktok_apply_lock_acquire() { [ "$lock_held" = 0 ] || return 1; lock_held=1; }
    _z2k_ow_tiktok_apply_lock_release() { [ "$lock_held" = 1 ] || return 1; lock_held=0; }
    _z2k_ow_tiktok_config_set() {
        [ "$lock_held" = 1 ] || return 1
        awk -F= -v key="$1" -v value="$2" \
            '\''$1 == key { print key "=" value; found=1; next } { print } END { if (!found) print key "=" value }'\'' \
            "$Z2K_TIKTOK_CONFIG" > "$Z2K_TIKTOK_CONFIG.new" || return 1
        mv "$Z2K_TIKTOK_CONFIG.new" "$Z2K_TIKTOK_CONFIG"
    }
    z2k_ow_tiktok_check() {
        [ "$1" = explicit ] && [ "$lock_held" = 0 ] \
            && [ "$(z2k_ow_tiktok_mode)" = auto ] && [ -z "$(_z2k_ow_tiktok_manual_ip)" ]
    }
    z2k_ow_tiktok_use_auto
' sh "$REPO/platform/openwrt/tiktok.sh"; then
    _t_ok
else
    _t_bad "auto mode persists under the apply lock and selects only after release"
fi

# ICMP is informational only; a failed ping cannot make the target TLS probe dead.
cat > "$T/bin/ping" <<'STUB'
#!/bin/sh
if [ "${TIKTOK_PING_MODE:-blocked}" = available ]; then
    printf '64 bytes from %s: time=23.4 ms\n' "${4:-candidate}"
    exit 0
fi
exit 1
STUB
chmod +x "$T/bin/ping"
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
z2k_ow_tiktok_check explicit || _t_bad "TLS probe remains healthy when ICMP is blocked"
assert_contains "ICMP failure does not mark a TLS-verified candidate dead" "$Z2K_TIKTOK_STATE_FILE" 'state=healthy'

# Manual candidate scans are capped and every probe pins SNI to the managed target.
: > "$CURL_TEST_LOG"; : > "$CURL_RESOLVE_TEST_LOG"; : > "$CURL_ARGS_TEST_LOG"
export TIKTOK_PING_MODE=available
export Z2K_JOB_ID=runtime-progress-regression
: > "$T/probe-progress.log"
Z2K_TIKTOK_CANDIDATE_LIMIT=4 Z2K_TIKTOK_CANDIDATE_PARALLELISM=2 z2k_ow_tiktok_probe_all \
    2> "$T/probe-progress.log" \
    || _t_bad "bounded candidate probe-all completes"
assert_contains "probe-all logs the discovery stage" "$T/probe-progress.log" 'Обнаружение CDN-кандидатов'
assert_contains "probe-all reports each completed candidate" "$T/probe-progress.log" '[1/4]'
assert_contains "probe-all reports both managed-target results" "$T/probe-progress.log" 'v77.tiktokcdn.com'
assert_contains "probe-all reports a concrete final candidate summary" "$T/probe-progress.log" 'Итог: проверено 4 кандидата'
unset Z2K_JOB_ID
assert_eq "probe-all respects its candidate limit across both targets" '8' "$(wc -l < "$CURL_TEST_LOG" | tr -d ' ')"
assert_contains "candidate probe-all pins the primary managed target hostname" "$CURL_RESOLVE_TEST_LOG" 'v77.tiktokcdn.com:443:'
assert_contains "candidate probe-all pins the EU managed target hostname" "$CURL_RESOLVE_TEST_LOG" 'v77.tiktokcdn-eu.com:443:'
assert_contains "candidate HTTPS probes request the primary managed target URL" "$CURL_ARGS_TEST_LOG" 'https://v77.tiktokcdn.com/'
assert_contains "candidate HTTPS probes request the EU managed target URL" "$CURL_ARGS_TEST_LOG" 'https://v77.tiktokcdn-eu.com/'
assert_not_contains "candidate HTTPS probes do not substitute a source-domain hostname" "$CURL_ARGS_TEST_LOG" 'https://v16-cla.tiktokcdn.com/'
assert_contains "probe-all records optional ICMP latency without making it a health requirement" "$Z2K_TIKTOK_STATE_FILE" '|compatible|23;'
_candidates_checked=$(sed -n 's/^candidates_checked_epoch=//p' "$Z2K_TIKTOK_STATE_FILE")
case "$_candidates_checked" in ''|*[!0-9]*) _t_bad "probe-all records its own completion epoch" ;; *) _t_ok ;; esac
_duplicate_probes=$(sed -n 's/^probe_observations=//p' "$Z2K_TIKTOK_STATE_FILE" \
    | tr ';' '\n' | cut -d'|' -f1 | sort | uniq -d)
assert_eq "probe-all records each candidate once" '' "$_duplicate_probes"
_duplicate_candidates=$(sed -n 's/^candidate_pool=//p' "$Z2K_TIKTOK_STATE_FILE" \
    | tr ';' '\n' | cut -d'|' -f1 | sort | uniq -d)
assert_eq "discovery plus curated candidate list contains unique IPs" '' "$_duplicate_candidates"

# A replacement record for the same hostname is foreign until the stored exact
# content ownership proof agrees; disable must preserve that record.
printf "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/198.51.100.7'\n" >> "$UCI_TEST_DB"
z2k_ow_tiktok_disable || _t_bad "disable removes its address and preserves a foreign replacement"
assert_contains "disable preserves the foreign dnsmasq address" "$UCI_TEST_DB" '/v77.tiktokcdn.com/198.51.100.7'
if z2k_ow_tiktok_external_override; then _t_ok; else _t_bad "foreign same-host address remains external after disable"; fi
grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"

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
_z2k_ow_tiktok_set_host 143.244.42.18 || _t_bad "race precondition installs the owned address"
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
_z2k_ow_tiktok_set_host 143.244.42.18 || _t_bad "legacy selection precondition installs its current address"
z2k_ow_tiktok_check explicit || _t_bad "legacy selected IP migrates during verification"
assert_contains "legacy selection is labeled with legacy provenance" "$Z2K_TIKTOK_STATE_FILE" 'selected_mode=legacy'
assert_contains "legacy selection source is retained" "$Z2K_TIKTOK_STATE_FILE" 'selected_provenance=legacy'

# The winner's mandatory stability repeat is independent of its first success;
# a failed repeat must reject it and retain the previous selected address.
_current="198.51.100.99"
_z2k_ow_tiktok_set_host "$_current" || _t_bad "stability precondition installs its current address"
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
[ -z "$(grep -F '/v77.tiktokcdn.com/' "$UCI_TEST_DB" 2>/dev/null)" ] && _t_ok || _t_bad "first-run fail-open installs no DNS pin"

# Uninstall removes its marked exact address and preserves every foreign DNS entry.
printf "dhcp.@dnsmasq[0].hostrecord='foreign.example,198.51.100.9'\n" >> "$UCI_TEST_DB"
z2k_ow_tiktok_uninstall || _t_bad "TikTok adapter cleanup succeeds"
assert_not_contains "uninstall removes only its managed address" "$UCI_TEST_DB" '/v77.tiktokcdn.com/'
assert_contains "uninstall preserves foreign dnsmasq records" "$UCI_TEST_DB" 'foreign.example,198.51.100.9'
[ ! -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes owned TikTok hosts file"
[ ! -e "$Z2K_TIKTOK_ADDRESS_MARKER" ] && _t_ok || _t_bad "uninstall removes native ownership marker"

# A new hostname-specific choice records a preferred address for that domain
# and applies only that domain's owned dnsmasq address.
TIKTOK_PROBE_MODE=alt TIKTOK_DNS_IP=203.0.113.20
if z2k_ow_tiktok_manual_select 203.0.113.20 v16-cla.tiktokcdn.com; then _t_ok; else _t_bad "v16-cla preferred selection succeeds"; fi
assert_eq "new manual selection uses preferred-with-fallback policy" preferred "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com policy)"
assert_eq "preferred address is stored per hostname" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com preferred_ip)"
assert_eq "active address is stored per hostname" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_contains "v16-cla owns its own DNS address" "$UCI_TEST_DB" '/v16-cla.tiktokcdn.com/203.0.113.20'
assert_not_contains "v16-cla selection does not assign that IP to another v16 hostname" "$UCI_TEST_DB" '/v16-ies-music.tiktokcdn.com/203.0.113.20'
assert_contains "domain state is schema-versioned" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" 'schema_version=2'
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
z2k_ow_tiktok_manual_select 143.244.42.18 v16-ies-music.tiktokcdn.com \
    || _t_bad "v16-ies-music can select an independent address"
assert_eq "v16 domains retain independent active IPs" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_eq "v16-ies-music has its own active IP" 143.244.42.18 "$(_z2k_ow_tiktok_domain_state_get v16-ies-music.tiktokcdn.com selected_ip)"
assert_contains "both independently selected v16 addresses are owned" "$UCI_TEST_DB" '/v16-ies-music.tiktokcdn.com/143.244.42.18'

# Full discovery for one hostname records only probes made with that hostname
# and leaves the currently applied DNS map untouched.
_domain_dns_before=$(grep -F '/v16-cla.tiktokcdn.com/' "$UCI_TEST_DB")
TIKTOK_PROBE_MODE=alt
z2k_ow_tiktok_probe_all v16-cla.tiktokcdn.com || _t_bad "hostname-specific candidate discovery completes"
assert_contains "full discovery probes a v16 candidate with exact SNI" "$CURL_PAIR_TEST_LOG" 'v16-cla.tiktokcdn.com:443:203.0.113.20'
assert_contains "full discovery persists the exact hostname observation" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" 'domain.v16-cla.tiktokcdn.com.candidate_observations=198.51.100.99|'
assert_contains "full discovery records the hostname-verified reserve" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" '203.0.113.20|35|10|20|200|fra|HIT|edge|ok|ok|verified'
assert_contains "full discovery records its candidate pool per hostname" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" 'domain.v16-cla.tiktokcdn.com.candidate_pool=198.51.100.99|'
assert_eq "full discovery does not change the selected DNS address" "$_domain_dns_before" "$(grep -F '/v16-cla.tiktokcdn.com/' "$UCI_TEST_DB")"
TIKTOK_PROBE_MODE=ok

# A policy probe may finish after a newer user selection. It must revalidate
# its state snapshot under the apply lock before replacing that selection.
_policy_output=$( (set -u; z2k_ow_tiktok_domain_policy_set v16-ies-music.tiktokcdn.com auto) 2>&1)
_policy_rc=$?
[ "$_policy_rc" -eq 0 ] && _t_ok || _t_bad "auto policy succeeds under nounset"
assert_eq "auto policy emits no nounset diagnostics" "" "$_policy_output"
_policy_output=$( (set -u; z2k_ow_tiktok_domain_policy_set v16-cla.tiktokcdn.com preferred) 2>&1)
_policy_rc=$?
[ "$_policy_rc" -eq 0 ] && _t_ok || _t_bad "preferred policy with active IP succeeds under nounset"
assert_eq "preferred policy with active IP emits no nounset diagnostics" "" "$_policy_output"
z2k_ow_tiktok_domain_policy_set v16-ies-music.tiktokcdn.com auto \
    || _t_bad "v16-ies-music returns to auto before the policy race check"
rm -f "$T/policy-probe-started" "$T/policy-probe-release"
export TIKTOK_PROBE_WAIT_IP=143.244.42.18 TIKTOK_PROBE_WAIT_HOST=v16-ies-music.tiktokcdn.com
export TIKTOK_PROBE_STARTED="$T/policy-probe-started" TIKTOK_PROBE_RELEASE="$T/policy-probe-release"
z2k_ow_tiktok_domain_policy_set v16-ies-music.tiktokcdn.com strict >/dev/null 2>&1 &
_policy_pid=$!
_wait=0
while [ ! -e "$T/policy-probe-started" ] && [ "$_wait" -lt 100 ]; do sleep 0.05; _wait=$((_wait + 1)); done
if [ -e "$T/policy-probe-started" ]; then _t_ok; else _t_bad "strict policy probe reached its hostname-specific wait"; fi
TIKTOK_PROBE_MODE=alt z2k_ow_tiktok_manual_select 203.0.113.20 v16-ies-music.tiktokcdn.com \
    || _t_bad "newer user selection completes while the old policy probe waits"
: > "$T/policy-probe-release"
if wait "$_policy_pid"; then _t_bad "stale strict-policy probe is rejected"; else _t_ok; fi
unset TIKTOK_PROBE_WAIT_IP TIKTOK_PROBE_WAIT_HOST TIKTOK_PROBE_STARTED TIKTOK_PROBE_RELEASE
assert_eq "stale policy probe preserves newer preferred policy" preferred "$(_z2k_ow_tiktok_domain_state_get v16-ies-music.tiktokcdn.com policy)"
assert_eq "stale policy probe preserves newer selected IP" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-ies-music.tiktokcdn.com selected_ip)"
TIKTOK_PROBE_MODE=ok TIKTOK_DNS_IP=143.244.42.18
_domain_selected_at=$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_at_epoch)
export TIKTOK_ALLOW_IP=203.0.113.20
_z2k_ow_tiktok_check_domains automatic || _t_bad "healthy per-domain verification succeeds"
assert_eq "routine per-domain checks preserve selection time" "$_domain_selected_at" "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_at_epoch)"
unset TIKTOK_ALLOW_IP
cp "$Z2K_TIKTOK_ADDRESS_MARKER" "$T/domain-address-marker.before-rollback"
export DNSMASQ_FAIL_RESTART=1
if z2k_ow_tiktok_domain_select v16-cla.tiktokcdn.com 143.244.42.18; then
    _t_bad "multi-host DNS apply reports a restart failure"
else
    _t_ok
fi
unset DNSMASQ_FAIL_RESTART
assert_eq "failed multi-host DNS apply rolls back ownership marker" "$(cat "$T/domain-address-marker.before-rollback")" "$(cat "$Z2K_TIKTOK_ADDRESS_MARKER")"
assert_contains "failed multi-host DNS apply retains the original v16-cla address" "$UCI_TEST_DB" '/v16-cla.tiktokcdn.com/203.0.113.20'
assert_contains "failed multi-host DNS apply retains the newer v16-ies selection" "$UCI_TEST_DB" '/v16-ies-music.tiktokcdn.com/203.0.113.20'
assert_eq "failed multi-host DNS apply does not commit the new host state" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"

# Preferred selections stay recorded while a failed active IP accrues two
# independent failures; only then does a freshly verified reserve take over.
_domain_last_verified=$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com last_verified_epoch)
export TIKTOK_FAIL_IP_HOST="v16-cla.tiktokcdn.com=203.0.113.20"
_z2k_ow_tiktok_check_domains automatic || _t_bad "first per-domain health evaluation completes"
assert_eq "first failure does not switch the preferred IP" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_eq "first failure increments the per-domain counter" 1 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com failure_count)"
export DNSMASQ_FAIL_ENTRY='/v16-cla.tiktokcdn.com/143.244.42.18'
if _z2k_ow_tiktok_check_domains automatic; then
    _t_bad "failed reserve DNS application is reported"
else
    _t_ok
fi
unset DNSMASQ_FAIL_ENTRY
assert_contains "the DNS fixture failed only the proposed v16-cla mapping" "$DNSMASQ_TEST_LOG" 'injected-failure=/v16-cla.tiktokcdn.com/143.244.42.18'
assert_eq "failed reserve apply keeps the old active IP" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_eq "failed reserve apply preserves the active selection time" "$_domain_selected_at" "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_at_epoch)"
assert_eq "failed reserve apply preserves the old IP verification time" "$_domain_last_verified" "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com last_verified_epoch)"
assert_eq "failed reserve apply preserves confirmation that the old DNS was active" 1 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com dns_override_applied)"
assert_eq "failed reserve apply does not record a failover" "" "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com last_failover_epoch)"
_z2k_ow_tiktok_check_domains automatic || _t_bad "second per-domain health evaluation completes"
unset TIKTOK_FAIL_IP_HOST
assert_eq "confirmed failure activates a verified reserve" 143.244.42.18 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_eq "failover keeps the user's preferred IP" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com preferred_ip)"
assert_file "v16-cla records a failover epoch" "$Z2K_TIKTOK_DOMAIN_STATE_FILE"
assert_contains "v16-cla records the failover source epoch" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" 'domain.v16-cla.tiktokcdn.com.last_failover_epoch='
assert_eq "v16-cla failover records the previous address" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com last_failover_from)"
assert_eq "v16-cla failover records the reserve address" 143.244.42.18 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com last_failover_to)"
export Z2K_TIKTOK_RECOVERY_COOLDOWN=0
export TIKTOK_ALLOW_IP=203.0.113.20
_z2k_ow_tiktok_check_domains automatic || _t_bad "first preferred recovery observation completes"
assert_eq "one good preferred observation does not recover early" 143.244.42.18 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
_z2k_ow_tiktok_check_domains automatic || _t_bad "second preferred recovery observation completes"
assert_eq "preferred address recovers after stable observations" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get v16-cla.tiktokcdn.com selected_ip)"
assert_file "preferred recovery records an epoch" "$Z2K_TIKTOK_DOMAIN_STATE_FILE"
assert_contains "preferred recovery records its timestamp" "$Z2K_TIKTOK_DOMAIN_STATE_FILE" 'domain.v16-cla.tiktokcdn.com.last_recovery_epoch='
unset TIKTOK_ALLOW_IP
unset Z2K_TIKTOK_RECOVERY_COOLDOWN

# Strict policy remains pinned through two failures; preferred-with-fallback
# is the policy exercised above.
TIKTOK_PROBE_MODE=alt
z2k_ow_tiktok_manual_select 203.0.113.20 sf16-music.tiktokcdn-eu.com \
    || _t_bad "strict-policy fixture has a hostname-verified preference"
z2k_ow_tiktok_domain_policy_set sf16-music.tiktokcdn-eu.com strict \
    || _t_bad "strict policy can be selected for one hostname"
export TIKTOK_FAIL_IP_HOST="sf16-music.tiktokcdn-eu.com=203.0.113.20"
TIKTOK_PROBE_MODE=ok
_z2k_ow_tiktok_check_domains automatic || _t_bad "first strict-policy health evaluation completes"
_z2k_ow_tiktok_check_domains automatic || _t_bad "second strict-policy health evaluation completes"
assert_eq "strict policy retains the selected IP after failure threshold" 203.0.113.20 "$(_z2k_ow_tiktok_domain_state_get sf16-music.tiktokcdn-eu.com selected_ip)"
unset TIKTOK_FAIL_IP_HOST

_t_done
