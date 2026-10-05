#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tiktok-checkhost"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tiktok-checkhost.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/state"
export Z2K_STATE="$T/state" Z2K_TIKTOK_STATE_FILE="$T/state/tiktok.state"
export Z2K_TIKTOK_CONFIG="$T/config" Z2K_TIKTOK_CHECKHOST_API="https://check-host.fixture"
export Z2K_TIKTOK_CHECKHOST_NODE_LIMIT=3 Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS=2
export Z2K_TIKTOK_CHECKHOST_POLL_SECONDS=0 Z2K_TIKTOK_CURL_BIN="$T/bin/checkhost-curl"
export Z2K_TIKTOK_JSHN="$T/jshn.sh" Z2K_TIKTOK_JSON_QUERY="$T/json-query.py"
export Z2K_TIKTOK_RESOLVER_STATE="$T/resolv" Z2K_TIKTOK_RESOLVER_FALLBACK="$T/no-resolv"
export CHECKHOST_FIXTURE_MODE=ok CHECKHOST_FIXTURE_LOG="$T/api.log"
printf 'Z2K_TIKTOK_FEED_ENABLED=1\n' > "$Z2K_TIKTOK_CONFIG"
: > "$Z2K_TIKTOK_RESOLVER_STATE"

cat > "$T/json-query.py" <<'PY'
import json, os, sys
op, key = sys.argv[1], sys.argv[2]
value = json.loads(os.environ["JSHN_DATA"])
for part in filter(None, os.environ.get("JSHN_PATH", "").split("|")):
    value = value[int(part)-1] if isinstance(value, list) else value[part]
if op == "keys": print(" ".join(str(i+1) for i in range(len(value))) if isinstance(value, list) else " ".join(value.keys()))
elif op == "values": print(" ".join(map(str, value.get(key, []))) if isinstance(value, dict) else "")
elif op == "var":
    v = value.get(key, "") if isinstance(value, dict) else ""
    print("" if v is None else (json.dumps(v, separators=(",", ":")) if isinstance(v, (dict, list)) else v))
elif op == "exists":
    try:
        value = value[int(key)-1] if isinstance(value, list) else value[key]
        print("1")
    except (KeyError, IndexError, ValueError): print("0")
PY
cat > "$T/jshn.sh" <<'JSHN'
json_load() { : "${JSON_PREFIX}" "${JSON_UNSET}"; JSHN_DATA=$1; JSHN_PATH=; export JSHN_DATA JSHN_PATH; }
_json_query() { python3 "$Z2K_TIKTOK_JSON_QUERY" "$1" "${2:-}"; }
json_select() {
    if [ "$1" = .. ]; then case "$JSHN_PATH" in *\|*) JSHN_PATH=${JSHN_PATH%|*} ;; *) JSHN_PATH= ;; esac; export JSHN_PATH; return 0; fi
    [ "$(_json_query exists "$1")" = 1 ] || return 1
    JSHN_PATH="${JSHN_PATH:+$JSHN_PATH|}$1"; export JSHN_PATH
}
json_get_keys() { _v=$(_json_query keys); eval "$1=\"\$_v\""; }
json_get_var() { _v=$(_json_query var "$2"); eval "$1=\"\$_v\""; }
json_get_values() { _v=$(_json_query values "$2"); eval "$1=\"\$_v\""; }
JSHN

cat > "$T/nodes.json" <<'JSON'
{"nodes":{"ru1.node.check-host.net":{"asn":"AS14576","ip":"185.159.82.88","location":["ru","Russia","Moscow"]},"ru2.node.check-host.net":{"asn":"AS14576","ip":"185.159.82.89","location":["ru","Russia","Kazan"]},"de1.node.check-host.net":{"asn":"AS24940","ip":"46.4.143.48","location":["de","Germany","Berlin"]},"fr1.node.check-host.net":{"asn":"AS16276","ip":"51.15.0.1","location":["fr","France","Paris"]},"us1.node.check-host.net":{"asn":"AS18978","ip":"5.253.30.82","location":["us","USA","Los Angeles"]}}}
JSON
cat > "$T/results.json" <<'JSON'
{"ru1.node.check-host.net":[{"A":["203.0.113.77"],"AAAA":[],"TTL":300}],"de1.node.check-host.net":[{"A":["203.0.113.77"],"AAAA":[],"TTL":120}],"fr1.node.check-host.net":[{"A":[],"AAAA":[],"TTL":null}],"us1.node.check-host.net":null}
JSON
cat > "$T/bin/checkhost-curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >> "$CHECKHOST_FIXTURE_LOG"
[ "$CHECKHOST_FIXTURE_MODE" = fail ] && exit 22
case "$*" in
    *check-host.fixture/nodes/ips*) cat "$CHECKHOST_NODES_JSON" ;;
    *check-host.fixture/check-dns*) printf '{"ok":1,"request_id":"fixture-123"}\n' ;;
    *check-host.fixture/check-result/fixture-123*) cat "$CHECKHOST_RESULTS_JSON" ;;
    *) exit 2 ;;
esac
CURL
chmod +x "$T/bin/checkhost-curl"
export CHECKHOST_NODES_JSON="$T/nodes.json" CHECKHOST_RESULTS_JSON="$T/results.json"

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tiktok.sh"

nodes=$(_z2k_ow_tiktok_checkhost_node_catalog)
expected_nodes=$(printf 'ru1.node.check-host.net|Russia|Moscow|AS14576\nde1.node.check-host.net|Germany|Berlin|AS24940\nfr1.node.check-host.net|France|Paris|AS16276')
assert_eq "node catalog prefers unique countries across a repeated-country pool" "$expected_nodes" "$nodes"

export Z2K_JOB_ID=checkhost-progress-regression
observations=$(_z2k_ow_tiktok_checkhost_discover 2> "$T/checkhost-progress.log")
printf '%s\n' "$observations" > "$T/observations"
assert_contains "Check-Host progress names the first discovery domain" "$T/checkhost-progress.log" '[1/5] v77.tiktokcdn.com'
assert_contains "Check-Host progress reports the last discovery domain" "$T/checkhost-progress.log" '[5/5] sf16-music.tiktokcdn-eu.com'
assert_contains "Check-Host progress reports its selected distributed node count" "$T/checkhost-progress.log" 'узлов: 3'
unset Z2K_JOB_ID
assert_eq "five discovery domains are checked at three distributed nodes" '10' "$(wc -l < "$T/observations" | tr -d ' ')"
assert_contains "Check-Host provenance keeps node, country, city, ASN, domain, IP and TTL" "$T/observations" '203.0.113.77|ru1.node.check-host.net|Russia|Moscow|AS14576|v77.tiktokcdn.com|300'
assert_not_contains "null and empty DNS replies do not create candidate observations" "$T/observations" 'us1.node.check-host.net'
assert_eq "one check-dns request is sent for every discovery domain" '5' "$(grep -c 'check-dns' "$CHECKHOST_FIXTURE_LOG")"
assert_eq "result polling is bounded at the configured two attempts" '10' "$(grep -c 'check-result/fixture-123' "$CHECKHOST_FIXTURE_LOG")"
assert_contains "requests advertise the official JSON API" "$CHECKHOST_FIXTURE_LOG" 'Accept: application/json'
assert_not_contains "requests do not use HTML or csrf_token" "$CHECKHOST_FIXTURE_LOG" 'csrf_token'

if strict_observations=$(set -u; unset JSON_PREFIX JSON_UNSET; _z2k_ow_tiktok_checkhost_discover); then
    assert_eq "Check-Host discovery completes under the WebPanel CGI nounset mode" '10' \
        "$(printf '%s\n' "$strict_observations" | wc -l | tr -d ' ')"
else
    _t_bad "Check-Host discovery completes under the WebPanel CGI nounset mode"
fi
strict_after_jshn=$(set -u; unset JSON_PREFIX JSON_UNSET; \
    _z2k_ow_tiktok_checkhost_request_id '{"request_id":"fixture-123"}' >/dev/null; \
    case "$-" in *u*) printf preserved ;; *) printf disabled ;; esac)
assert_eq "jshn compatibility does not disable nounset for its CGI caller" 'preserved' "$strict_after_jshn"

_cached_rows=$(printf '%s\n' "$observations" | _z2k_ow_tiktok_serialize_lines)
_now=$(date +%s)
_z2k_ow_tiktok_checkhost_cache_write "$_cached_rows" "$_now"
CHECKHOST_FIXTURE_MODE=fail
combined=$(_z2k_ow_tiktok_discover_combined 1)
printf '%s\n' "$combined" > "$T/combined"
assert_contains "Check-Host failure keeps successful cached observations and local fallback" "$T/combined" '203.0.113.77|v77.tiktokcdn.com|check-host|ru1.node.check-host.net|check-host|Moscow|Russia|AS14576|300'
candidate=$(printf '%s\n' "$combined" | _z2k_ow_tiktok_candidate_pool | awk -F'|' '$1 == "203.0.113.77" { print; exit }')
printf '%s\n' "$candidate" > "$T/candidate"
assert_eq "duplicate IP observations preserve distinct nodes, countries and ASNs" '2|2|2' \
    "$(printf '%s\n' "$candidate" | awk -F'|' '{ print $12 "|" $13 "|" $14 }')"
assert_contains "candidate stores each discovery domain that returned the IP" "$T/candidate" 'v77.tiktokcdn.com,v77.tiktokcdn-eu.com,v16-cla.tiktokcdn.com,v16-ies-music.tiktokcdn.com,sf16-music.tiktokcdn-eu.com'
assert_contains "successful Check-Host data has a persisted cache timestamp" "$Z2K_TIKTOK_STATE_FILE" 'checkhost_cache_epoch='

_t_done
