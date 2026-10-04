#!/bin/sh
# OpenWrt-only TikTok CDN feed repair.
#
# This is intentionally isolated from upstream z2k strategy/config logic.  It
# owns one dnsmasq addnhosts file for v77.tiktokcdn.com, discovers candidate
# CDN addresses, verifies them with the real hostname over TLS, and keeps the
# last known-good address.  External DNS overrides always win.

Z2K_TIKTOK_HOST="${Z2K_TIKTOK_HOST:-v77.tiktokcdn.com}"
Z2K_TIKTOK_HOSTS_FILE="${Z2K_TIKTOK_HOSTS_FILE:-${Z2K_STATE:-/etc/z2k/state}/tiktok-cdn-hosts}"
Z2K_TIKTOK_UCI_MARKER="${Z2K_TIKTOK_UCI_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-addnhosts-owned}"
Z2K_TIKTOK_CONTENT_MARKER="${Z2K_TIKTOK_CONTENT_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-host-content-owned}"
Z2K_TIKTOK_STATE_FILE="${Z2K_TIKTOK_STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/tiktok-cdn.state}"
Z2K_TIKTOK_CONFIG="${Z2K_TIKTOK_CONFIG:-${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}}"
Z2K_TIKTOK_UCI_SECTION="${Z2K_TIKTOK_UCI_SECTION:-dhcp.@dnsmasq[0]}"
Z2K_TIKTOK_UCI_BIN="${Z2K_TIKTOK_UCI_BIN:-uci}"
Z2K_TIKTOK_DNSMASQ_INIT="${Z2K_TIKTOK_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
Z2K_TIKTOK_APPLY_LOCK="${Z2K_TIKTOK_APPLY_LOCK:-${Z2K_LOCKS:-${Z2K_TMP:-/tmp/z2k}/locks}/tiktok-apply.lock}"
Z2K_TIKTOK_CURL_BIN="${Z2K_TIKTOK_CURL_BIN:-curl}"
Z2K_TIKTOK_NSLOOKUP_BIN="${Z2K_TIKTOK_NSLOOKUP_BIN:-nslookup}"
Z2K_TIKTOK_MAX_PROBES="${Z2K_TIKTOK_MAX_PROBES:-12}"
Z2K_TIKTOK_SUCCESS_TARGET="${Z2K_TIKTOK_SUCCESS_TARGET:-4}"
Z2K_TIKTOK_RESOLVER_LIMIT=16
Z2K_TIKTOK_DNS_TIMEOUT="${Z2K_TIKTOK_DNS_TIMEOUT:-3}"
Z2K_TIKTOK_FAILOVER_THRESHOLD=2
Z2K_TIKTOK_SELECTED_LEASE_SECONDS=3600
Z2K_TIKTOK_HYSTERESIS_RELATIVE=0.75
Z2K_TIKTOK_HYSTERESIS_ABSOLUTE_MS=40
Z2K_TIKTOK_STABILITY_PROBES=2

_z2k_ow_tiktok_valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
        { exit 0 }
    ' >/dev/null 2>&1
}

_z2k_ow_tiktok_state_get() {
    [ -r "$Z2K_TIKTOK_STATE_FILE" ] || return 0
    sed -n "s/^$1=//p" "$Z2K_TIKTOK_STATE_FILE" 2>/dev/null | head -1
}

_z2k_ow_tiktok_state_write() {
    local _argc=$#
    local _state="$1" _ip="${2:-}" _lat="${3:-}" _fail="${4:-0}" _verified="${5:-0}" _reason="${6:-}"
    local _selected_at="${7:-$_verified}" _discovered="${8:-0}" _evaluated="${9:-$_verified}"
    local _source_domain="${10:-}" _mode="${11:-}" _provenance="${12:-}" _geo="${13:-}"
    local _health="${14:-$_state}" _connect="${15:-}" _tls="${16:-}" _http="${17:-}"
    local _pop="${18:-}" _cache="${19:-}" _server="${20:-}"
    local _domains="${21:-}" _modes="${22:-}" _resolvers="${23:-}" _sources="${24:-}" _cname="${25:-}"
    local _dns_observed="${26:-0}" _curated_observed="${27:-0}"
    local _stability="${28:-$(_z2k_ow_tiktok_state_get stability_probe_count)}"
    local _failover_at="${29:-$(_z2k_ow_tiktok_state_get last_failover_epoch)}"
    local _failover_from="${30:-$(_z2k_ow_tiktok_state_get last_failover_from)}"
    local _failover_to="${31:-$(_z2k_ow_tiktok_state_get last_failover_to)}"
    local _failover_reason="${32:-$(_z2k_ow_tiktok_state_get last_failover_reason)}"
    local _candidate_pool="${_Z2K_TIKTOK_CANDIDATE_POOL_STATE:-$(_z2k_ow_tiktok_state_get candidate_pool)}"
    local _resolver_sources="${_Z2K_TIKTOK_RESOLVER_SOURCES_STATE:-$(_z2k_ow_tiktok_state_get resolver_sources)}"
    local _resolution_observations="${_Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE:-$(_z2k_ow_tiktok_state_get resolution_observations)}"
    local _probe_observations="${_Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE:-$(_z2k_ow_tiktok_state_get probe_observations)}"
    if [ "$_argc" -lt 21 ] && [ "$_state" != off ] && [ "$_state" != external ]; then
        _domains=$(_z2k_ow_tiktok_state_get selected_domains)
        _modes=$(_z2k_ow_tiktok_state_get selected_modes)
        _resolvers=$(_z2k_ow_tiktok_state_get selected_resolvers)
        _sources=$(_z2k_ow_tiktok_state_get selected_sources)
        _cname=$(_z2k_ow_tiktok_state_get selected_cname)
        _dns_observed=$(_z2k_ow_tiktok_state_get dns_observed)
        _curated_observed=$(_z2k_ow_tiktok_state_get curated_observed)
    fi
    local _tmp="${Z2K_TIKTOK_STATE_FILE}.new.$$"
    mkdir -p "$(dirname "$Z2K_TIKTOK_STATE_FILE")" 2>/dev/null || return 1
    {
        printf 'state=%s\n' "$_state"
        printf 'selected_ip=%s\n' "$_ip"
        printf 'latency_ms=%s\n' "$_lat"
        printf 'failure_count=%s\n' "$_fail"
        printf 'last_verified_epoch=%s\n' "$_verified"
        printf 'selected_at_epoch=%s\n' "$_selected_at"
        printf 'last_discovery_epoch=%s\n' "$_discovered"
        printf 'last_evaluation_epoch=%s\n' "$_evaluated"
        printf 'selected_source_domain=%s\n' "$_source_domain"
        printf 'selected_mode=%s\n' "$_mode"
        printf 'selected_provenance=%s\n' "$_provenance"
        printf 'selected_geo_hint=%s\n' "$_geo"
        printf 'health=%s\n' "$_health"
        printf 'connect_latency_ms=%s\n' "$_connect"
        printf 'tls_latency_ms=%s\n' "$_tls"
        printf 'http_status=%s\n' "$_http"
        printf 'x77_pop=%s\n' "$_pop"
        printf 'x77_cache=%s\n' "$_cache"
        printf 'server=%s\n' "$_server"
        printf 'selected_domains=%s\n' "$_domains"
        printf 'selected_modes=%s\n' "$_modes"
        printf 'selected_resolvers=%s\n' "$_resolvers"
        printf 'selected_sources=%s\n' "$_sources"
        printf 'selected_cname=%s\n' "$_cname"
        printf 'dns_observed=%s\n' "$_dns_observed"
        printf 'curated_observed=%s\n' "$_curated_observed"
        printf 'stability_probe_count=%s\n' "${_stability:-0}"
        printf 'recovery_count=0\n'
        printf 'last_failover_epoch=%s\n' "$_failover_at"
        printf 'last_failover_from=%s\n' "$_failover_from"
        printf 'last_failover_to=%s\n' "$_failover_to"
        printf 'last_failover_reason=%s\n' "$_failover_reason"
        printf 'candidate_pool=%s\n' "$_candidate_pool"
        printf 'resolver_sources=%s\n' "$_resolver_sources"
        printf 'resolution_observations=%s\n' "$_resolution_observations"
        printf 'probe_observations=%s\n' "$_probe_observations"
        printf 'reason=%s\n' "$_reason"
    } > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_STATE_FILE"
}

z2k_ow_tiktok_enabled() {
    local _enabled
    _enabled=$(awk -F= '$1 == "Z2K_TIKTOK_FEED_ENABLED" { v=$2; gsub(/[" '\''\r]/, "", v) } END { print v }' "$Z2K_TIKTOK_CONFIG" 2>/dev/null)
    [ "$_enabled" = 1 ]
}

# Periodic checks set this guard to core-ready. Interactive CLI calls leave it
# empty, so operators can still run a manual check. Re-check immediately before
# writes so a probe that overlapped service stop cannot resurrect a DNS pin.
_z2k_ow_tiktok_runtime_allowed() {
    [ -z "${Z2K_TIKTOK_REQUIRE_READY:-}" ] || [ -e "$Z2K_TIKTOK_REQUIRE_READY" ]
}

_z2k_ow_tiktok_apply_lock_acquire() {
    local _tries=0 _holder
    mkdir -p "$(dirname "$Z2K_TIKTOK_APPLY_LOCK")" 2>/dev/null || return 1
    while ! mkdir "$Z2K_TIKTOK_APPLY_LOCK" 2>/dev/null; do
        _holder=$(cat "$Z2K_TIKTOK_APPLY_LOCK/pid" 2>/dev/null)
        case "$_holder" in
            ''|*[!0-9]*) ;;
            *)
                if ! kill -0 "$_holder" 2>/dev/null; then
                    mv "$Z2K_TIKTOK_APPLY_LOCK" "$Z2K_TIKTOK_APPLY_LOCK.stale.$$" 2>/dev/null && \
                        rm -rf "$Z2K_TIKTOK_APPLY_LOCK.stale.$$"
                    continue
                fi
                ;;
        esac
        _tries=$((_tries + 1))
        [ "$_tries" -lt 60 ] || return 1
        sleep 1
    done
    printf '%s\n' "$$" > "$Z2K_TIKTOK_APPLY_LOCK/pid" || {
        rm -f "$Z2K_TIKTOK_APPLY_LOCK/pid"
        rmdir "$Z2K_TIKTOK_APPLY_LOCK" 2>/dev/null || true
        return 1
    }
}

_z2k_ow_tiktok_apply_lock_release() {
    [ "$(cat "$Z2K_TIKTOK_APPLY_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$Z2K_TIKTOK_APPLY_LOCK/pid"
    rmdir "$Z2K_TIKTOK_APPLY_LOCK" 2>/dev/null || true
}

_z2k_ow_tiktok_recheck_before_apply() {
    local _now
    if ! z2k_ow_tiktok_enabled; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _now=$(date +%s 2>/dev/null || echo 0)
        _Z2K_TIKTOK_CANDIDATE_POOL_STATE=""
        _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=""
        _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=""
        _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE=""
        _z2k_ow_tiktok_state_write off "" "" 0 0 disabled 0 0 "$_now" "" "" "" "" off
        return 2
    fi
    _z2k_ow_tiktok_runtime_allowed || return 2
    if z2k_ow_tiktok_external_override; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _now=$(date +%s 2>/dev/null || echo 0)
        _z2k_ow_tiktok_state_write external "" "" 0 0 external-dns-owner 0 0 "$_now" "" "" "" "" external
        return 2
    fi
    return 0
}

_z2k_ow_tiktok_registered() {
    "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | awk -F= -v path="$Z2K_TIKTOK_HOSTS_FILE" '
            $1 ~ /\.addnhosts$/ {
                count=split($2, values, /[[:space:]]+/)
                for (i=1; i<=count; i++) if (values[i] == path) found=1
            }
            END { exit !found }
        '
}

_z2k_ow_tiktok_owned() {
    [ -r "$Z2K_TIKTOK_UCI_MARKER" ] \
        && [ "$(cat "$Z2K_TIKTOK_UCI_MARKER" 2>/dev/null)" = "$Z2K_TIKTOK_HOSTS_FILE" ]
}

_z2k_ow_tiktok_hosts_content_owned() {
    [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] || return 0
    if [ ! -e "$Z2K_TIKTOK_CONTENT_MARKER" ]; then
        local _legacy_ip _expected=""
        _legacy_ip=$(_z2k_ow_tiktok_state_get selected_ip)
        _z2k_ow_tiktok_valid_ipv4 "$_legacy_ip" && _expected="$_legacy_ip $Z2K_TIKTOK_HOST"
        if [ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] || { [ -n "$_expected" ] && [ "$(cat "$Z2K_TIKTOK_HOSTS_FILE" 2>/dev/null)" = "$_expected" ]; }; then
            cp "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER" 2>/dev/null || return 1
        else
            return 1
        fi
    fi
    cmp -s "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_CONTENT_MARKER"
}

_z2k_ow_tiktok_content_marker_update() {
    local _source="$1" _tmp="${Z2K_TIKTOK_CONTENT_MARKER}.new.$$"
    cp "$_source" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_CONTENT_MARKER" || { rm -f "$_tmp"; return 1; }
}

_z2k_ow_tiktok_reload_dnsmasq() {
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_DNSMASQ_INIT" reload >/dev/null 2>&1
}

# A future upstream implementation or a user-defined DNS override wins.  We
# never replace/remove DNS state we do not own.
z2k_ow_tiktok_external_override() {
    local _path
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    if "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | awk -F= -v host="$Z2K_TIKTOK_HOST" '
            $1 ~ /\.(address|hostrecord|cname)$/ {
                value=substr($0, index($0, "=") + 1)
                sub(/^\/+/, "", value)
                n=split(value, fields, /[,\/=[:space:]]+/)
                for (i=1; i<=n; i++) if (tolower(fields[i]) == tolower(host)) found=1
            }
            END { exit !found }
        '; then
        return 0
    fi
    for _path in $("$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null | tr -d "'\"" \
        | sed -n 's/^[^=]*\.addnhosts=//p'); do
        [ -n "$_path" ] || continue
        [ "$_path" != "$Z2K_TIKTOK_HOSTS_FILE" ] || continue
        [ -r "$_path" ] || continue
        if awk -v h="$Z2K_TIKTOK_HOST" '
            /^[[:space:]]*#/ { next }
            { for (i=2; i<=NF; i++) if ($i == h) found=1 }
            END { exit !found }
        ' "$_path" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

z2k_ow_tiktok_prepare() {
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_UCI_BIN" -q show "$Z2K_TIKTOK_UCI_SECTION" >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$Z2K_TIKTOK_HOSTS_FILE")" 2>/dev/null || return 1
    if _z2k_ow_tiktok_registered; then
        _z2k_ow_tiktok_owned || {
            echo "z2k-openwrt: TikTok DNS include already exists without z2kOW ownership" >&2
            return 1
        }
        _z2k_ow_tiktok_hosts_content_owned || {
            echo "z2k-openwrt: TikTok hosts file contains entries not owned by z2kOW" >&2
            return 1
        }
        return 0
    fi
    if [ -e "$Z2K_TIKTOK_HOSTS_FILE" ]; then
        if ! _z2k_ow_tiktok_owned || ! _z2k_ow_tiktok_hosts_content_owned; then
            echo "z2k-openwrt: refusing to claim an existing TikTok hosts path" >&2
            return 1
        fi
    else
        : > "$Z2K_TIKTOK_HOSTS_FILE" || return 1
        _z2k_ow_tiktok_content_marker_update "$Z2K_TIKTOK_HOSTS_FILE" || return 1
    fi
    "$Z2K_TIKTOK_UCI_BIN" add_list \
        "$Z2K_TIKTOK_UCI_SECTION.addnhosts=$Z2K_TIKTOK_HOSTS_FILE" || return 1
    "$Z2K_TIKTOK_UCI_BIN" commit dhcp || return 1
    printf '%s\n' "$Z2K_TIKTOK_HOSTS_FILE" > "$Z2K_TIKTOK_UCI_MARKER" || return 1
    chmod 0600 "$Z2K_TIKTOK_UCI_MARKER" 2>/dev/null || return 1
    _z2k_ow_tiktok_reload_dnsmasq
}

_z2k_ow_tiktok_set_host() {
    local _ip="$1" _tmp="${Z2K_TIKTOK_HOSTS_FILE}.new.$$"
    _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
    _z2k_ow_tiktok_runtime_allowed || return 0
    z2k_ow_tiktok_prepare || return 1
    printf '%s %s\n' "$_ip" "$Z2K_TIKTOK_HOST" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    if ! _z2k_ow_tiktok_runtime_allowed; then
        rm -f "$_tmp"
        return 0
    fi
    _z2k_ow_tiktok_hosts_content_owned || { rm -f "$_tmp"; return 1; }
    if [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] && cmp -s "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE"; then
        rm -f "$_tmp"
        return 0
    fi
    mv -f "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    _z2k_ow_tiktok_content_marker_update "$Z2K_TIKTOK_HOSTS_FILE" || return 1
    _z2k_ow_tiktok_reload_dnsmasq
}

z2k_ow_tiktok_clear() {
    local _tmp="${Z2K_TIKTOK_HOSTS_FILE}.new.$$"
    [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] || return 0
    [ -s "$Z2K_TIKTOK_HOSTS_FILE" ] || return 0
    _z2k_ow_tiktok_owned && _z2k_ow_tiktok_registered || return 0
    _z2k_ow_tiktok_hosts_content_owned || return 0
    : > "$_tmp" || return 1
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    _z2k_ow_tiktok_content_marker_update "$Z2K_TIKTOK_HOSTS_FILE" || return 1
    _z2k_ow_tiktok_reload_dnsmasq
}

_z2k_ow_tiktok_resolvers() {
    local _f _limit="${Z2K_TIKTOK_RESOLVER_LIMIT:-16}"
    {
        for _f in "${Z2K_TIKTOK_RESOLVER_STATE:-/tmp/resolv.conf.d/resolv.conf.auto}" \
                  "${Z2K_TIKTOK_RESOLVER_FALLBACK:-/etc/resolv.conf}"; do
            [ -r "$_f" ] || continue
            awk '$1 == "nameserver" { print $2 }' "$_f" 2>/dev/null
        done
    } | awk -v limit="$_limit" '
        function valid_ip(ip, octets, i) {
            if (split(ip, octets, /[.]/) != 4) return 0
            for (i=1; i<=4; i++) if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) return 0
            return 1
        }
        valid_ip($1) && $1 !~ /^127\./ && !seen[$1]++ { print $1; n++ }
        n >= limit { exit }
    '
}

_z2k_ow_tiktok_domain_catalog() {
    cat <<'EOF_DOMAINS'
v77.tiktokcdn.com|direct|primary-target
v16-cla.tiktokcdn.com|cla|canonical-domain-source
v16-ies-music.tiktokcdn.com|ies|canonical-domain-source
sf16-music.tiktokcdn-eu.com|generic|canonical-domain-source
EOF_DOMAINS
}

_z2k_ow_tiktok_curated_candidates() {
    cat <<'EOF_CANDIDATES'
212.188.77.134|Moscow
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
87.245.200.24|RETN
EOF_CANDIDATES
}

_z2k_ow_tiktok_parse_nslookup() {
    local _resolver="$1"
    awk -v resolver="$_resolver" '
        $0 == "Non-authoritative answer:" || $0 ~ /^Name:[[:space:]]*/ { answer=1 }
        !answer { next }
        $0 ~ /^Address:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?[[:space:]]*$/ {
            value=$0
            sub(/^Address:[[:space:]]*/, "", value)
            sub(/:[0-9]+$/, "", value)
            split(value, octets, /[.]/)
            valid=(length(octets)==4)
            for (i=1; i<=4; i++) if (octets[i] > 255) valid=0
            if (valid && value != resolver && !seen[value]++) print value
        }
    '
}

_z2k_ow_tiktok_parse_cname() {
    awk '
        match($0, /canonical name[[:space:]]*=[[:space:]]*[a-zA-Z0-9][a-zA-Z0-9.-]*/) {
            value=substr($0, RSTART, RLENGTH); sub(/^.*=[[:space:]]*/, "", value); print tolower(value); exit
        }
        match($0, /is an alias for[[:space:]]+[a-zA-Z0-9][a-zA-Z0-9.-]*/) {
            value=substr($0, RSTART, RLENGTH); sub(/^.*for[[:space:]]+/, "", value); print tolower(value); exit
        }
    '
}

_z2k_ow_tiktok_record_probe() {
    local _ip="$1" _row="${2:-}" _record
    _record="${_row:-$_ip|failed}"
    if [ -n "${_Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE:-}" ]; then
        _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE="$_Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE;$_record"
    else
        _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE="$_record"
    fi
}

_z2k_ow_tiktok_serialize_lines() {
    awk 'NF { printf "%s%s", separator, $0; separator=";" } END { if (separator != "") print "" }'
}

# Input rows are IP|domain|mode|resolver|source|cname. Output rows retain the
# same merged candidate evidence as service-dns-tiktok-model.uc.
_z2k_ow_tiktok_candidate_pool() {
    {
        cat
        _z2k_ow_tiktok_curated_candidates | awk -F'|' '{ print $1 "|__CURATED__|" $2 }'
    } | awk -F'|' '
        function valid_ip(ip, octets, i) {
            if (split(ip, octets, /[.]/) != 4) return 0
            for (i=1; i<=4; i++) if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) return 0
            return 1
        }
        function append_unique(array, ip, value, key) {
            if (value == "") return
            key=ip SUBSEP value
            if (!seen[key]++) array[ip]=(array[ip] == "" ? value : array[ip] "," value)
        }
        function ensure(ip) {
            if (!ordered[ip]++) { order[++count]=ip; provenance[ip]="domain-resolution" }
        }
        valid_ip($1) {
            ip=$1; ensure(ip)
            if ($2 == "__CURATED__") {
                curated[ip]=1
                append_unique(geoHints, ip, $3)
                append_unique(modes, ip, "curated")
                append_unique(sources, ip, "curated-community-fallback")
                if (provenance[ip] == "domain-resolution") provenance[ip]="mixed"
                next
            }
            if ($2 !~ /^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$/) next
            dns[ip]=1
            append_unique(domains, ip, $2)
            append_unique(modes, ip, $3)
            append_unique(resolvers, ip, $4)
            append_unique(sources, ip, $5)
            append_unique(cnames, ip, $6)
        }
        END {
            for (i=1; i<=count; i++) {
                ip=order[i]
                if (!dns[ip]) provenance[ip]="curated-community-fallback"
                printf "%s|%s|%s|%s|%s|%s|%s|%s|%d|%d|0\n", ip, domains[ip], modes[ip], resolvers[ip], sources[ip], cnames[ip], geoHints[ip], provenance[ip], dns[ip] ? 1 : 0, curated[ip] ? 1 : 0
            }
        }
    '
}

_z2k_ow_tiktok_hysteresis() {
    local _current_health="$1" _current_ms="$2" _alternative_health="$3" _alternative_ms="$4"
    if [ "$_alternative_health" != healthy ]; then
        printf '%s\n' 'keep|alternative-unhealthy'
    elif [ "$_current_health" = none ] || [ -z "$_current_health" ]; then
        printf '%s\n' 'switch|no-current'
    elif [ "$_current_health" != healthy ]; then
        printf '%s\n' 'switch|current-unhealthy'
    elif awk -v current="$_current_ms" -v alternative="$_alternative_ms" \
        'BEGIN { exit !((current+0)>0 && (alternative+0)>0 && (alternative+0)<=(current+0)*0.75 && ((current+0)-(alternative+0))>=40) }'; then
        printf '%s\n' 'switch|material-latency-improvement'
    else
        printf '%s\n' 'keep|hysteresis-not-met'
    fi
}

_z2k_ow_tiktok_dns_query() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$Z2K_TIKTOK_DNS_TIMEOUT" "$Z2K_TIKTOK_NSLOOKUP_BIN" "$1" "$2" 2>/dev/null
    else
        "$Z2K_TIKTOK_NSLOOKUP_BIN" "$1" "$2" 2>/dev/null
    fi
}

_z2k_ow_tiktok_discover_candidates() {
    local _resolver _domain _mode _provenance _raw _cname _ip _ips _status
    command -v "$Z2K_TIKTOK_NSLOOKUP_BIN" >/dev/null 2>&1 || :
    while IFS='|' read -r _domain _mode _provenance; do
        [ -n "$_domain" ] || continue
        for _resolver in $(_z2k_ow_tiktok_resolvers); do
            _raw=$(_z2k_ow_tiktok_dns_query "$_domain" "$_resolver")
            _cname=$(printf '%s\n' "$_raw" | _z2k_ow_tiktok_parse_cname)
            _ips=$(printf '%s\n' "$_raw" | _z2k_ow_tiktok_parse_nslookup "$_resolver")
            if [ -n "$_ips" ]; then _status=resolved; else _status=no-a-record; fi
            while IFS= read -r _ip; do
                [ -n "$_ip" ] || continue
                printf '%s|%s|%s|%s|%s|%s\n' "$_ip" "$_domain" "$_mode" "$_resolver" system-wan "$_cname"
            done <<EOF_IPS
$_ips
EOF_IPS
            printf '__QUERY__|%s|%s|%s|system-wan|%s|%s\n' "$_domain" "$_mode" "$_resolver" "$_cname" "$_status"
        done
    done <<EOF_CATALOG
$(_z2k_ow_tiktok_domain_catalog)
EOF_CATALOG
}

# stdout: latency in milliseconds. curl validates the normal certificate for
# v77.tiktokcdn.com because --insecure is deliberately never used.
_z2k_ow_tiktok_probe() {
    local _ip="$1" _raw _metrics _http _connect _tls _total _ms _pop _cache _server
    _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
    command -v "$Z2K_TIKTOK_CURL_BIN" >/dev/null 2>&1 || return 1
    _raw=$("$Z2K_TIKTOK_CURL_BIN" --ipv4 --silent --show-error --dump-header - \
        --output /dev/null --stderr /dev/null --connect-timeout 4 --max-time 7 \
        --write-out '\nZ2M_TIKTOK_METRICS:%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}' \
        --resolve "$Z2K_TIKTOK_HOST:443:$_ip" "https://$Z2K_TIKTOK_HOST/" 2>/dev/null) || return 1
    _metrics=$(printf '%s\n' "$_raw" | sed -n 's/^Z2M_TIKTOK_METRICS://p' | tail -1)
    IFS='|' read -r _http _connect _tls _total <<EOF_METRICS
$_metrics
EOF_METRICS
    awk -v v="$_tls" 'BEGIN { exit !(v+0 > 0) }' || return 1
    _ms=$(awk -v v="$_total" 'BEGIN { printf "%d", (v+0)*1000 }') || return 1
    _connect=$(awk -v v="$_connect" 'BEGIN { printf "%d", (v+0)*1000 }') || _connect=0
    _tls=$(awk -v v="$_tls" 'BEGIN { printf "%d", (v+0)*1000 }') || _tls=0
    _pop=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^x-77-pop:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    _cache=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^x-77-cache:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    _server=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^server:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    case "$_ms" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_ip" "$_ms" "$_connect" "$_tls" "${_http:-}" "${_pop:-}" "${_cache:-}" "${_server:-}"
}

z2k_ow_tiktok_check() {
    local _mode="${1:-automatic}" _force=0 _scheduled=0 _now _current _current_latency _current_verified _selected_at _discovered _evaluated
    local _fail _current_row="" _current_ms="" _current_ok=0 _current_probed=0 _pool _resolution _ip _row _best_row="" _best_ms="" _probes=0 _success=0 _candidate_index=0 _stable_row _reason
    local _domains _modes _resolvers _sources _cnames _geo _provenance _dns _curated _decision _stable_at
    local _best_domain="" _best_domains="" _best_mode="" _best_modes="" _best_provenance="" _best_geo="" _best_resolvers="" _best_sources="" _best_cname="" _best_dns=0 _best_curated=0
    local _failover_from="" _failover_to="" _failover_reason="" _stability=0
    local _sel_domain="" _sel_mode="" _sel_provenance="" _sel_geo="" _sel_domains="" _sel_modes="" _sel_resolvers="" _sel_sources="" _sel_cname="" _sel_dns=0 _sel_curated=0
    _now=$(date +%s 2>/dev/null) || _now=0
    case "$_mode" in
        automatic) ;;
        explicit) _force=1 ;;
        scheduled) _scheduled=1 ;;
        *) return 2 ;;
    esac
    _Z2K_TIKTOK_CANDIDATE_POOL_STATE=$(_z2k_ow_tiktok_state_get candidate_pool)
    _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=$(_z2k_ow_tiktok_state_get resolver_sources)
    _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=$(_z2k_ow_tiktok_state_get resolution_observations)
    _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE=""
    _z2k_ow_tiktok_runtime_allowed || return 0
    if ! z2k_ow_tiktok_enabled; then
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        _z2k_ow_tiktok_recheck_before_apply || :
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi
    if z2k_ow_tiktok_external_override; then
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if _z2k_ow_tiktok_recheck_before_apply; then
            _z2k_ow_tiktok_apply_lock_release
        else
            _z2k_ow_tiktok_apply_lock_release
            return 0
        fi
    fi
    z2k_ow_tiktok_prepare || {
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if _z2k_ow_tiktok_recheck_before_apply; then
            _z2k_ow_tiktok_state_write degraded "" "" 0 0 dnsmasq-prepare-failed 0 0 "$_now"
        fi
        _z2k_ow_tiktok_apply_lock_release
        return 1
    }
    _current=$(_z2k_ow_tiktok_state_get selected_ip)
    _current_latency=$(_z2k_ow_tiktok_state_get latency_ms)
    _current_verified=$(_z2k_ow_tiktok_state_get last_verified_epoch)
    _selected_at=$(_z2k_ow_tiktok_state_get selected_at_epoch)
    _discovered=$(_z2k_ow_tiktok_state_get last_discovery_epoch)
    _sel_domain=$(_z2k_ow_tiktok_state_get selected_source_domain)
    _sel_mode=$(_z2k_ow_tiktok_state_get selected_mode)
    _sel_provenance=$(_z2k_ow_tiktok_state_get selected_provenance)
    _sel_geo=$(_z2k_ow_tiktok_state_get selected_geo_hint)
    _sel_domains=$(_z2k_ow_tiktok_state_get selected_domains)
    _sel_modes=$(_z2k_ow_tiktok_state_get selected_modes)
    _sel_resolvers=$(_z2k_ow_tiktok_state_get selected_resolvers)
    _sel_sources=$(_z2k_ow_tiktok_state_get selected_sources)
    _sel_cname=$(_z2k_ow_tiktok_state_get selected_cname)
    _sel_dns=$(_z2k_ow_tiktok_state_get dns_observed); [ -n "$_sel_dns" ] || _sel_dns=0
    _sel_curated=$(_z2k_ow_tiktok_state_get curated_observed); [ -n "$_sel_curated" ] || _sel_curated=0
    if _z2k_ow_tiktok_valid_ipv4 "$_current" && [ -z "$_sel_mode" ]; then
        _sel_domain="$Z2K_TIKTOK_HOST"
        _sel_mode=legacy
        _sel_provenance=legacy
        _sel_domains="$Z2K_TIKTOK_HOST"
        _sel_modes=legacy
        _sel_sources=legacy
    fi
    _fail=$(_z2k_ow_tiktok_state_get failure_count)
    case "$_fail" in ''|*[!0-9]*) _fail=0 ;; esac
    _evaluated=$(_z2k_ow_tiktok_state_get last_evaluation_epoch)
    if [ "$_force" = 0 ] && [ "$_scheduled" = 0 ] \
        && [ "$(_z2k_ow_tiktok_state_get state)" = healthy ] \
        && [ "$_current_verified" -gt 0 ] 2>/dev/null \
        && [ $((_now - _current_verified)) -le "$Z2K_TIKTOK_SELECTED_LEASE_SECONDS" ] 2>/dev/null; then
        _current_probed=1
        if _current_row=$(_z2k_ow_tiktok_probe "$_current"); then
            _z2k_ow_tiktok_record_probe "$_current" "$_current_row"
            _z2k_ow_tiktok_apply_lock_acquire || return 1
            if ! _z2k_ow_tiktok_recheck_before_apply; then
                _z2k_ow_tiktok_apply_lock_release
                return 0
            fi
            _z2k_ow_tiktok_state_write healthy "$_current" "$(printf '%s' "$_current_row" | cut -d'|' -f2)" 0 "$_now" current-ip-fast-path "${_selected_at:-$_now}" "${_discovered:-0}" "$_now" \
                "$_sel_domain" "$_sel_mode" \
                "$_sel_provenance" "$_sel_geo" \
                healthy "$(printf '%s' "$_current_row" | cut -d'|' -f3)" "$(printf '%s' "$_current_row" | cut -d'|' -f4)" \
                "$(printf '%s' "$_current_row" | cut -d'|' -f5)" "$(printf '%s' "$_current_row" | cut -d'|' -f6)" \
                "$(printf '%s' "$_current_row" | cut -d'|' -f7)" "$(printf '%s' "$_current_row" | cut -d'|' -f8)"
            _z2k_ow_tiktok_apply_lock_release
            return 0
        fi
        _z2k_ow_tiktok_record_probe "$_current" ""
        _fail=$((_fail + 1))
    fi
    if _z2k_ow_tiktok_valid_ipv4 "$_current"; then
        if [ "$_current_probed" = 0 ]; then
            _current_probed=1
            if _current_row=$(_z2k_ow_tiktok_probe "$_current"); then
                _current_ok=1
                _fail=0
                _z2k_ow_tiktok_record_probe "$_current" "$_current_row"
            else
                _fail=$((_fail + 1))
                _z2k_ow_tiktok_record_probe "$_current" ""
            fi
        fi
        [ -n "$_current_row" ] && _current_ok=1
        _current_ms=$(printf '%s' "$_current_row" | cut -d'|' -f2)
    fi
    _evaluated="$_now"
    if [ "$_current_ok" = 0 ] && [ -n "$_current" ] && [ "$_fail" -lt "$Z2K_TIKTOK_FAILOVER_THRESHOLD" ]; then
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if ! _z2k_ow_tiktok_recheck_before_apply; then
            _z2k_ow_tiktok_apply_lock_release
            return 0
        fi
        _z2k_ow_tiktok_state_write degraded "$_current" "$_current_latency" "$_fail" "$_current_verified" transient-probe-failure \
            "${_selected_at:-$_current_verified}" "${_discovered:-0}" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" \
            "$_sel_provenance" "$_sel_geo" dead
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi

    _resolution=$(_z2k_ow_tiktok_discover_candidates)
    _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=$(printf '%s\n' "$_resolution" | _z2k_ow_tiktok_serialize_lines)
    _pool=$(printf '%s\n' "$_resolution" | _z2k_ow_tiktok_candidate_pool)
    _Z2K_TIKTOK_CANDIDATE_POOL_STATE=$(printf '%s\n' "$_pool" | _z2k_ow_tiktok_serialize_lines)
    _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=$(_z2k_ow_tiktok_resolvers | _z2k_ow_tiktok_serialize_lines)
    _discovered="$_now"
    while IFS='|' read -r _ip _domains _modes _resolvers _sources _cnames _geo _provenance _dns _curated _verified; do
        [ -n "$_ip" ] || continue
        _candidate_index=$((_candidate_index + 1))
        [ "$_candidate_index" -le "$Z2K_TIKTOK_MAX_PROBES" ] || break
        [ "$_ip" != "$_current" ] || continue
        [ "$_probes" -lt "$Z2K_TIKTOK_MAX_PROBES" ] || break
        _probes=$((_probes + 1))
        if _row=$(_z2k_ow_tiktok_probe "$_ip"); then
            _z2k_ow_tiktok_record_probe "$_ip" "$_row"
            _success=$((_success + 1))
            _ms=$(printf '%s' "$_row" | cut -d'|' -f2)
            if [ -z "$_best_ms" ] || [ "$_ms" -lt "$_best_ms" ]; then
                _best_row="$_row"; _best_ms="$_ms"
                _best_domain="${_domains%%,*}"; _best_domains="$_domains"; _best_mode="${_modes%%,*}"; _best_modes="$_modes"
                _best_provenance="$_provenance"; _best_geo="${_geo%%,*}"
                _best_resolvers="$_resolvers"; _best_sources="$_sources"; _best_cname="$_cnames"
                _best_dns="$_dns"; _best_curated="$_curated"
            fi
            [ "$_success" -lt "$Z2K_TIKTOK_SUCCESS_TARGET" ] || break
        else
            _z2k_ow_tiktok_record_probe "$_ip" ""
        fi
    done <<EOF_POOL
$_pool
EOF_POOL
    _best_ip=$(printf '%s' "$_best_row" | cut -d'|' -f1)
    if [ -n "$_best_ip" ]; then
        _stable_row=$(_z2k_ow_tiktok_probe "$_best_ip") || _stable_row=""
        _z2k_ow_tiktok_record_probe "$_best_ip" "$_stable_row"
        [ -n "$_stable_row" ] || _best_row=""
        [ -z "$_stable_row" ] || _best_row="$_stable_row"
        _best_ip=$(printf '%s' "$_best_row" | cut -d'|' -f1)
        _best_ms=$(printf '%s' "$_best_row" | cut -d'|' -f2)
    fi
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    if ! _z2k_ow_tiktok_recheck_before_apply; then
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi
    if [ "$_current_ok" = 1 ]; then
        _reason=$(_z2k_ow_tiktok_hysteresis healthy "$_current_ms" healthy "$_best_ms")
        if [ -n "$_best_ip" ] && [ "${_reason%%|*}" = switch ]; then
            _failover_from="$_current"; _failover_to="$_best_ip"; _failover_reason="${_reason#*|}"
            _current="$_best_ip"; _current_row="$_best_row"; _current_ms="$_best_ms"
            _selected_at="$_now"; _stability="$Z2K_TIKTOK_STABILITY_PROBES"
            _sel_domain="$_best_domain"; _sel_mode="$_best_mode"; _sel_provenance="$_best_provenance"; _sel_geo="$_best_geo"
            _sel_domains="$_best_domains"; _sel_modes="$_best_modes"; _sel_resolvers="$_best_resolvers"; _sel_sources="$_best_sources"
            _sel_cname="$_best_cname"; _sel_dns="$_best_dns"; _sel_curated="$_best_curated"
        fi
        _z2k_ow_tiktok_set_host "$_current" || { _z2k_ow_tiktok_apply_lock_release; return 1; }
        _z2k_ow_tiktok_state_write healthy "$_current" "$_current_ms" 0 "$_now" "${_reason#*|}" "${_selected_at:-$_now}" "$_discovered" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" "$_sel_provenance" "$_sel_geo" healthy \
            "$(printf '%s' "$_current_row" | cut -d'|' -f3)" "$(printf '%s' "$_current_row" | cut -d'|' -f4)" \
            "$(printf '%s' "$_current_row" | cut -d'|' -f5)" "$(printf '%s' "$_current_row" | cut -d'|' -f6)" \
            "$(printf '%s' "$_current_row" | cut -d'|' -f7)" "$(printf '%s' "$_current_row" | cut -d'|' -f8)" \
            "$_sel_domains" "$_sel_modes" "$_sel_resolvers" "$_sel_sources" \
            "$_sel_cname" "$_sel_dns" "$_sel_curated" "$_stability" \
            "${_failover_from:+$_now}" "$_failover_from" "$_failover_to" "$_failover_reason"
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi

    if [ -n "$_best_ip" ]; then
        _sel_domain="$_best_domain"; _sel_mode="$_best_mode"; _sel_provenance="$_best_provenance"; _sel_geo="$_best_geo"
        _sel_domains="$_best_domains"; _sel_modes="$_best_modes"; _sel_resolvers="$_best_resolvers"; _sel_sources="$_best_sources"
        _sel_cname="$_best_cname"; _sel_dns="$_best_dns"; _sel_curated="$_best_curated"
        _z2k_ow_tiktok_set_host "$_best_ip" || { _z2k_ow_tiktok_apply_lock_release; return 1; }
        _z2k_ow_tiktok_state_write healthy "$_best_ip" "$_best_ms" 0 "$_now" "${_current:+consecutive-probe-failures}" "$_now" "$_discovered" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" "$_sel_provenance" "$_sel_geo" healthy \
            "$(printf '%s' "$_best_row" | cut -d'|' -f3)" "$(printf '%s' "$_best_row" | cut -d'|' -f4)" \
            "$(printf '%s' "$_best_row" | cut -d'|' -f5)" "$(printf '%s' "$_best_row" | cut -d'|' -f6)" \
            "$(printf '%s' "$_best_row" | cut -d'|' -f7)" "$(printf '%s' "$_best_row" | cut -d'|' -f8)" \
            "$_sel_domains" "$_sel_modes" "$_sel_resolvers" "$_sel_sources" "$_sel_cname" "$_sel_dns" "$_sel_curated" \
            "$Z2K_TIKTOK_STABILITY_PROBES" "$_now" "$_current" "$_best_ip" "consecutive-probe-failures"
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi

    if _z2k_ow_tiktok_valid_ipv4 "$_current"; then
        _z2k_ow_tiktok_set_host "$_current" || { _z2k_ow_tiktok_apply_lock_release; return 1; }
        _z2k_ow_tiktok_state_write degraded "$_current" "$_current_latency" "$_fail" "$_current_verified" no-verified-alternative \
            "${_selected_at:-$_current_verified}" "$_discovered" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" \
            "$_sel_provenance" "$_sel_geo" dead
    else
        z2k_ow_tiktok_clear || { _z2k_ow_tiktok_apply_lock_release; return 1; }
        _z2k_ow_tiktok_state_write degraded "" "" "$_fail" 0 no-verified-cdn-fail-open 0 "$_discovered" "$_evaluated" "" "" "" "" dead
    fi
    _z2k_ow_tiktok_apply_lock_release
    return 0
}

z2k_ow_tiktok_status() {
    local _state _ip _lat _verified _fail _mode
    _state=$(_z2k_ow_tiktok_state_get state); [ -n "$_state" ] || _state=unknown
    _ip=$(_z2k_ow_tiktok_state_get selected_ip)
    _lat=$(_z2k_ow_tiktok_state_get latency_ms)
    _verified=$(_z2k_ow_tiktok_state_get last_verified_epoch)
    _fail=$(_z2k_ow_tiktok_state_get failure_count); [ -n "$_fail" ] || _fail=0
    z2k_ow_tiktok_enabled && _mode=enabled || _mode=disabled
    printf 'enabled=%s\n' "$_mode"
    printf 'state=%s\n' "$_state"
    printf 'host=%s\n' "$Z2K_TIKTOK_HOST"
    printf 'selected_ip=%s\n' "$_ip"
    printf 'latency_ms=%s\n' "$_lat"
    printf 'last_verified_epoch=%s\n' "$_verified"
    printf 'failure_count=%s\n' "$_fail"
    printf 'reason=%s\n' "$(_z2k_ow_tiktok_state_get reason)"
    printf 'selected_source_domain=%s\n' "$(_z2k_ow_tiktok_state_get selected_source_domain)"
    printf 'selected_mode=%s\n' "$(_z2k_ow_tiktok_state_get selected_mode)"
    printf 'selected_provenance=%s\n' "$(_z2k_ow_tiktok_state_get selected_provenance)"
    printf 'selected_geo_hint=%s\n' "$(_z2k_ow_tiktok_state_get selected_geo_hint)"
    printf 'selected_cname=%s\n' "$(_z2k_ow_tiktok_state_get selected_cname)"
    printf 'health=%s\n' "$(_z2k_ow_tiktok_state_get health)"
    printf 'connect_latency_ms=%s\n' "$(_z2k_ow_tiktok_state_get connect_latency_ms)"
    printf 'tls_latency_ms=%s\n' "$(_z2k_ow_tiktok_state_get tls_latency_ms)"
    printf 'http_status=%s\n' "$(_z2k_ow_tiktok_state_get http_status)"
    printf 'x77_pop=%s\n' "$(_z2k_ow_tiktok_state_get x77_pop)"
    printf 'x77_cache=%s\n' "$(_z2k_ow_tiktok_state_get x77_cache)"
    printf 'server=%s\n' "$(_z2k_ow_tiktok_state_get server)"
    printf 'dns_observed=%s\n' "$(_z2k_ow_tiktok_state_get dns_observed)"
    printf 'curated_observed=%s\n' "$(_z2k_ow_tiktok_state_get curated_observed)"
    printf 'stability_probe_count=%s\n' "$(_z2k_ow_tiktok_state_get stability_probe_count)"
    printf 'last_failover_epoch=%s\n' "$(_z2k_ow_tiktok_state_get last_failover_epoch)"
    printf 'last_failover_from=%s\n' "$(_z2k_ow_tiktok_state_get last_failover_from)"
    printf 'last_failover_to=%s\n' "$(_z2k_ow_tiktok_state_get last_failover_to)"
    printf 'last_failover_reason=%s\n' "$(_z2k_ow_tiktok_state_get last_failover_reason)"
}

z2k_ow_tiktok_enable() {
    z2k_ow_tiktok_check explicit
}

z2k_ow_tiktok_disable() {
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    z2k_ow_tiktok_clear || { _z2k_ow_tiktok_apply_lock_release; return 1; }
    _Z2K_TIKTOK_CANDIDATE_POOL_STATE=""
    _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=""
    _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=""
    _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE=""
    _z2k_ow_tiktok_state_write off "" "" 0 0 disabled 0 0 "$(date +%s 2>/dev/null || echo 0)" "" "" "" "" off
    local _rc=$?
    _z2k_ow_tiktok_apply_lock_release
    return "$_rc"
}

z2k_ow_tiktok_stop() {
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    z2k_ow_tiktok_clear
    local _rc=$?
    _z2k_ow_tiktok_apply_lock_release
    return "$_rc"
}

_z2k_ow_tiktok_uninstall_locked() {
    local _owned="" _remove_file=0
    if [ -r "$Z2K_TIKTOK_UCI_MARKER" ]; then
        _owned=$(cat "$Z2K_TIKTOK_UCI_MARKER" 2>/dev/null)
        if [ "$_owned" = "$Z2K_TIKTOK_HOSTS_FILE" ]; then
            # The registered addnhosts file is shared with dnsmasq. If another
            # package changed it, keep its registration and our ownership marker
            # so a later cleanup can be reviewed safely.
            if ! _z2k_ow_tiktok_hosts_content_owned; then
                echo "z2k-openwrt: preserving externally modified TikTok addnhosts file" >&2
                return 1
            fi
            if _z2k_ow_tiktok_registered; then
                "$Z2K_TIKTOK_UCI_BIN" del_list \
                    "$Z2K_TIKTOK_UCI_SECTION.addnhosts=$Z2K_TIKTOK_HOSTS_FILE" || return 1
                "$Z2K_TIKTOK_UCI_BIN" commit dhcp || return 1
                _z2k_ow_tiktok_reload_dnsmasq || return 1
            fi
            _remove_file=1
        fi
    fi
    if [ "$_remove_file" = 1 ]; then
        rm -f "$Z2K_TIKTOK_HOSTS_FILE" || return 1
    fi
    rm -f "$Z2K_TIKTOK_UCI_MARKER" "$Z2K_TIKTOK_CONTENT_MARKER" "$Z2K_TIKTOK_STATE_FILE"
}

z2k_ow_tiktok_uninstall() {
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    _z2k_ow_tiktok_uninstall_locked
    local _rc=$?
    _z2k_ow_tiktok_apply_lock_release
    return "$_rc"
}
