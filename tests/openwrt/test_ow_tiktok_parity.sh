#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tiktok-parity"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tiktok-parity.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/state" "$T/bin"
export Z2K_STATE="$T/state"
export Z2K_TIKTOK_STATE_FILE="$T/state/tiktok.state"
export Z2K_TIKTOK_RESOLVER_STATE="$T/resolv.auto"
export Z2K_TIKTOK_RESOLVER_FALLBACK="$T/resolv.fallback"
export Z2K_TIKTOK_RESOLVER_LIMIT=16

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tiktok.sh"

expected_domains='v77.tiktokcdn.com|direct|primary-target
v16-cla.tiktokcdn.com|cla|canonical-domain-source
v16-ies-music.tiktokcdn.com|ies|canonical-domain-source
sf16-music.tiktokcdn-eu.com|generic|canonical-domain-source'
actual_domains=$(_z2k_ow_tiktok_domain_catalog)
assert_eq "source TikTok domain catalog and provenance" "$expected_domains" "$actual_domains"

expected_curated='212.188.77.134|Moscow
212.188.77.135|Moscow
212.188.77.140|Moscow
212.188.77.136|Moscow
185.11.78.47|Minsk
143.244.42.18|Amsterdam
143.244.42.29|Amsterdam
143.244.42.21|Amsterdam
143.244.42.36|Amsterdam
143.244.42.15|Amsterdam
143.244.42.26|Amsterdam
143.244.42.17|Amsterdam
143.244.42.23|Amsterdam
37.19.202.33|Amsterdam
37.19.202.53|Amsterdam
37.19.202.47|Amsterdam
37.19.202.54|Amsterdam
37.19.202.46|Amsterdam
37.19.202.50|Amsterdam
37.19.202.51|Amsterdam
37.19.202.49|Amsterdam
37.19.202.52|Amsterdam
37.19.202.48|Amsterdam
37.19.203.36|Sofia
169.150.237.34|Sofia
87.245.200.8|RETN
87.245.200.66|RETN
87.245.200.10|RETN
87.245.200.35|RETN
87.245.200.64|RETN
87.245.200.34|RETN
87.245.200.56|RETN
87.245.200.32|RETN
87.245.200.57|RETN
87.245.200.9|RETN
87.245.200.24|RETN'
actual_curated=$(_z2k_ow_tiktok_curated_candidates)
assert_eq "all 36 curated source candidates and geo hints" "$expected_curated" "$actual_curated"

cat > "$Z2K_TIKTOK_RESOLVER_STATE" <<'EOF_RESOLVERS'
nameserver 127.0.0.1
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 999.1.2.3
nameserver 2001:db8::1
EOF_RESOLVERS
cat > "$Z2K_TIKTOK_RESOLVER_FALLBACK" <<'EOF_RESOLVERS'
nameserver 9.9.9.9
nameserver 8.8.8.8
nameserver 999.2.3.4
EOF_RESOLVERS
assert_eq "resolver discovery uses deduplicated non-loopback system IPv4 only" \
    '1.1.1.1
8.8.8.8
9.9.9.9' "$(_z2k_ow_tiktok_resolvers)"

cat > "$T/bin/nslookup" <<'EOF_NSLOOKUP'
#!/bin/sh
printf 'Server: %s\nAddress: %s:53\n\nNon-authoritative answer:\nName: %s\nAddress: 203.0.113.50\n' "$2" "$2" "$1"
EOF_NSLOOKUP
chmod +x "$T/bin/nslookup"
export PATH="$T/bin:$PATH" Z2K_TIKTOK_NSLOOKUP_BIN=nslookup
_discovered=$(_z2k_ow_tiktok_discover_candidates)
assert_eq "system resolvers queried across each source catalog domain" '12' "$(printf '%s\n' "$_discovered" | awk -F'|' '$1!="__QUERY__" {n++} END {print n+0}')"
assert_eq "each resolver query outcome is retained" '12' "$(printf '%s\n' "$_discovered" | awk -F'|' '$1=="__QUERY__" {n++} END {print n+0}')"
_discovered_row=$(printf '%s\n' "$_discovered" | _z2k_ow_tiktok_candidate_pool | awk -F'|' '$1=="203.0.113.50" {print;exit}')
assert_eq "DNS discovery preserves domain, mode, resolver and source provenance" \
    '203.0.113.50|v77.tiktokcdn.com,v16-cla.tiktokcdn.com,v16-ies-music.tiktokcdn.com,sf16-music.tiktokcdn-eu.com|direct,cla,ies,generic|1.1.1.1,8.8.8.8,9.9.9.9|system-wan|||domain-resolution|1|0|0' \
    "$_discovered_row"

nslookup_fixture='Server: 195.0.2.1
Address: 195.0.2.1:53

Non-authoritative answer:
example.cdn.test canonical name = edge.example.net
Name: edge.example.net
Address: 203.0.113.10
Address: 203.0.113.10
Address: 195.0.2.1
Address: 2001:db8::10
Address: not-an-ip'
assert_eq "nslookup parser accepts answer IPv4 only and drops resolver and duplicates" \
    '203.0.113.10' "$(printf '%s\n' "$nslookup_fixture" | _z2k_ow_tiktok_parse_nslookup 195.0.2.1)"
assert_eq "nslookup parser retains canonical name" 'edge.example.net' \
    "$(printf '%s\n' "$nslookup_fixture" | _z2k_ow_tiktok_parse_cname)"

resolution_rows='143.244.42.18|v77.tiktokcdn.com|direct|1.1.1.1|system-wan|edge.example.net
143.244.42.18|v16-cla.tiktokcdn.com|cla|8.8.8.8|provider-catalog:google-dns|edge.example.net'
candidate_row=$(printf '%s\n' "$resolution_rows" | _z2k_ow_tiktok_candidate_pool \
    | awk -F'|' '$1 == "143.244.42.18" { print; exit }')
assert_eq "duplicate DNS and curated observations merge provenance" \
    '143.244.42.18|v77.tiktokcdn.com,v16-cla.tiktokcdn.com|direct,cla,curated|1.1.1.1,8.8.8.8|system-wan,provider-catalog:google-dns,curated-community-fallback|edge.example.net|Amsterdam|mixed|1|1|0' \
    "$candidate_row"
assert_eq "candidate pool puts the 36 source fallback entries behind DNS candidates" \
    '36' "$(printf '%s\n' "$resolution_rows" | _z2k_ow_tiktok_candidate_pool | wc -l | tr -d ' ')"

assert_eq "source hysteresis accepts 25 percent and 40 ms improvement" \
    'switch|material-latency-improvement' "$(_z2k_ow_tiktok_hysteresis healthy 200 healthy 150)"
assert_eq "source hysteresis rejects an insufficient absolute improvement" \
    'keep|hysteresis-not-met' "$(_z2k_ow_tiktok_hysteresis healthy 200 healthy 160)"
assert_eq "unhealthy alternative cannot be selected" \
    'keep|alternative-unhealthy' "$(_z2k_ow_tiktok_hysteresis healthy 200 dead 10)"
assert_eq "verified alternative replaces an unhealthy current candidate" \
    'switch|current-unhealthy' "$(_z2k_ow_tiktok_hysteresis dead 200 healthy 999)"

assert_contains "TikTok config choice survives official generator regeneration" \
    "$REPO/lib/config_official.sh" 'saved_Z2K_TIKTOK_FEED_ENABLED=$(safe_config_read'
assert_contains "TikTok toggle is emitted in regenerated config" \
    "$REPO/lib/config_official.sh" 'Z2K_TIKTOK_FEED_ENABLED=${saved_Z2K_TIKTOK_FEED_ENABLED}'
assert_contains "new installs default TikTok feed repair off" \
    "$REPO/platform/openwrt/files/etc/z2k/config.default" 'Z2K_TIKTOK_FEED_ENABLED=0'

_t_done
