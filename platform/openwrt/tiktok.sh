#!/bin/sh
# OpenWrt-only TikTok CDN feed repair.
#
# This is intentionally isolated from upstream z2k strategy/config logic.  It
# owns dnsmasq address overrides for TikTok's two managed CDN hostnames,
# discovers candidate addresses, verifies each hostname over TLS, and keeps
# the last known-good address. External DNS overrides always win.

Z2K_TIKTOK_HOST="${Z2K_TIKTOK_HOST:-v77.tiktokcdn.com}"
Z2K_TIKTOK_EU_HOST="${Z2K_TIKTOK_EU_HOST:-v77.tiktokcdn-eu.com}"
Z2K_TIKTOK_CHECKHOST_API="${Z2K_TIKTOK_CHECKHOST_API:-https://check-host.net}"
Z2K_TIKTOK_CHECKHOST_TTL="${Z2K_TIKTOK_CHECKHOST_TTL:-21600}"
Z2K_TIKTOK_CHECKHOST_NODE_LIMIT="${Z2K_TIKTOK_CHECKHOST_NODE_LIMIT:-8}"
Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS="${Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS:-2}"
Z2K_TIKTOK_CHECKHOST_POLL_SECONDS="${Z2K_TIKTOK_CHECKHOST_POLL_SECONDS:-1}"
Z2K_TIKTOK_JSHN="${Z2K_TIKTOK_JSHN:-/usr/share/libubox/jshn.sh}"
Z2K_TIKTOK_HOSTS_FILE="${Z2K_TIKTOK_HOSTS_FILE:-${Z2K_STATE:-/etc/z2k/state}/tiktok-cdn-hosts}"
Z2K_TIKTOK_UCI_MARKER="${Z2K_TIKTOK_UCI_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-addnhosts-owned}"
Z2K_TIKTOK_CONTENT_MARKER="${Z2K_TIKTOK_CONTENT_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-host-content-owned}"
Z2K_TIKTOK_ADDRESS_MARKER="${Z2K_TIKTOK_ADDRESS_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-address-owned}"
Z2K_TIKTOK_STATE_FILE="${Z2K_TIKTOK_STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/tiktok-cdn.state}"
Z2K_TIKTOK_CONFIG="${Z2K_TIKTOK_CONFIG:-${CONFIG_FILE:-${Z2K_CONFIG:-/etc/z2k/config}}}"
Z2K_TIKTOK_UCI_SECTION="${Z2K_TIKTOK_UCI_SECTION:-dhcp.@dnsmasq[0]}"
Z2K_TIKTOK_UCI_BIN="${Z2K_TIKTOK_UCI_BIN:-uci}"
Z2K_TIKTOK_DNSMASQ_INIT="${Z2K_TIKTOK_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
Z2K_TIKTOK_EFFECTIVE_CONFIG="${Z2K_TIKTOK_EFFECTIVE_CONFIG:-}"
Z2K_TIKTOK_APPLY_LOCK="${Z2K_TIKTOK_APPLY_LOCK:-${Z2K_LOCKS:-${Z2K_TMP:-/tmp/z2k}/locks}/tiktok-apply.lock}"
Z2K_TIKTOK_CURL_BIN="${Z2K_TIKTOK_CURL_BIN:-curl}"
Z2K_TIKTOK_PING_BIN="${Z2K_TIKTOK_PING_BIN:-ping}"
Z2K_TIKTOK_NSLOOKUP_BIN="${Z2K_TIKTOK_NSLOOKUP_BIN:-nslookup}"
Z2K_TIKTOK_MAX_PROBES="${Z2K_TIKTOK_MAX_PROBES:-12}"
Z2K_TIKTOK_CANDIDATE_PARALLELISM="${Z2K_TIKTOK_CANDIDATE_PARALLELISM:-4}"
Z2K_TIKTOK_CANDIDATE_LIMIT="${Z2K_TIKTOK_CANDIDATE_LIMIT:-64}"
Z2K_TIKTOK_SUCCESS_TARGET="${Z2K_TIKTOK_SUCCESS_TARGET:-4}"
Z2K_TIKTOK_RESOLVER_LIMIT=16
Z2K_TIKTOK_DNS_TIMEOUT="${Z2K_TIKTOK_DNS_TIMEOUT:-3}"
Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES="${Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES:-3}"
Z2K_TIKTOK_FAILOVER_THRESHOLD=2
Z2K_TIKTOK_SELECTED_LEASE_SECONDS=3600
Z2K_TIKTOK_HYSTERESIS_RELATIVE=0.75
Z2K_TIKTOK_HYSTERESIS_ABSOLUTE_MS=40
Z2K_TIKTOK_STABILITY_PROBES=2

# WebPanel job output is captured by svc_action_async. Send progress to stderr:
# discovery and probe helpers often run in command substitutions, where stdout
# is reserved for their machine-readable return values.
_z2k_ow_tiktok_job_progress() {
    [ -n "${Z2K_JOB_ID:-}" ] || return 0
    if command -v job_progress >/dev/null 2>&1; then
        job_progress "$*"
        return $?
    fi
    _epoch=$(date +%s 2>/dev/null) || _epoch=
    case "$_epoch" in ''|*[!0-9]*) printf '%s\n' "$*" >&2 ;; *) printf '@z2k-ts:%s|%s\n' "$_epoch" "$*" >&2 ;; esac
}

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
    local _candidates_checked="${_Z2K_TIKTOK_CANDIDATES_CHECKED_EPOCH_STATE:-$(_z2k_ow_tiktok_state_get candidates_checked_epoch)}"
    local _candidate_verified="${_Z2K_TIKTOK_CANDIDATE_VERIFIED_OVERRIDE:-${33:-$(_z2k_ow_tiktok_state_get candidate_verified)}}"
    local _dns_override_applied="${_Z2K_TIKTOK_DNS_OVERRIDE_APPLIED_OVERRIDE:-${34:-$(_z2k_ow_tiktok_state_get dns_override_applied)}}"
    local _candidate_pool="${_Z2K_TIKTOK_CANDIDATE_POOL_STATE:-$(_z2k_ow_tiktok_state_get candidate_pool)}"
    local _resolver_sources="${_Z2K_TIKTOK_RESOLVER_SOURCES_STATE:-$(_z2k_ow_tiktok_state_get resolver_sources)}"
    local _resolution_observations="${_Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE:-$(_z2k_ow_tiktok_state_get resolution_observations)}"
    local _probe_observations="${_Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE:-$(_z2k_ow_tiktok_state_get probe_observations)}"
    local _checkhost_observations="${_Z2K_TIKTOK_CHECKHOST_OBSERVATIONS_STATE:-$(_z2k_ow_tiktok_state_get checkhost_observations)}"
    local _checkhost_cache_epoch="${_Z2K_TIKTOK_CHECKHOST_CACHE_EPOCH_STATE:-$(_z2k_ow_tiktok_state_get checkhost_cache_epoch)}"
    if [ "$_argc" -lt 21 ] && [ "$_state" != off ] && [ "$_state" != external ]; then
        _domains=$(_z2k_ow_tiktok_state_get selected_domains)
        _modes=$(_z2k_ow_tiktok_state_get selected_modes)
        _resolvers=$(_z2k_ow_tiktok_state_get selected_resolvers)
        _sources=$(_z2k_ow_tiktok_state_get selected_sources)
        _cname=$(_z2k_ow_tiktok_state_get selected_cname)
        _dns_observed=$(_z2k_ow_tiktok_state_get dns_observed)
        _curated_observed=$(_z2k_ow_tiktok_state_get curated_observed)
    fi
    if [ "$_argc" -lt 14 ]; then _health=$(_z2k_ow_tiktok_state_get health); fi
    if [ "$_argc" -lt 21 ]; then
        _connect=$(_z2k_ow_tiktok_state_get connect_latency_ms)
        _tls=$(_z2k_ow_tiktok_state_get tls_latency_ms)
        _http=$(_z2k_ow_tiktok_state_get http_status)
        _pop=$(_z2k_ow_tiktok_state_get x77_pop)
        _cache=$(_z2k_ow_tiktok_state_get x77_cache)
        _server=$(_z2k_ow_tiktok_state_get server)
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
        printf 'candidates_checked_epoch=%s\n' "$_candidates_checked"
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
        printf 'checkhost_observations=%s\n' "$_checkhost_observations"
        printf 'checkhost_cache_epoch=%s\n' "$_checkhost_cache_epoch"
        printf 'reason=%s\n' "$_reason"
        printf 'candidate_verified=%s\n' "${_candidate_verified:-0}"
        printf 'dns_override_applied=%s\n' "${_dns_override_applied:-0}"
    } > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_STATE_FILE"
}

_z2k_ow_tiktok_state_write_apply() {
    local _candidate="$1" _dns="$2"
    shift 2
    _Z2K_TIKTOK_CANDIDATE_VERIFIED_OVERRIDE="$_candidate"
    _Z2K_TIKTOK_DNS_OVERRIDE_APPLIED_OVERRIDE="$_dns"
    _z2k_ow_tiktok_state_write "$@"
    local _rc=$?
    unset _Z2K_TIKTOK_CANDIDATE_VERIFIED_OVERRIDE _Z2K_TIKTOK_DNS_OVERRIDE_APPLIED_OVERRIDE
    return "$_rc"
}

z2k_ow_tiktok_enabled() {
    local _enabled
    _enabled=$(awk -F= '$1 == "Z2K_TIKTOK_FEED_ENABLED" { v=$2; gsub(/[" '\''\r]/, "", v) } END { print v }' "$Z2K_TIKTOK_CONFIG" 2>/dev/null)
    [ "$_enabled" = 1 ]
}

z2k_ow_tiktok_mode() {
    local _mode
    _mode=$(awk -F= '$1 == "Z2K_TIKTOK_MODE" { v=$2; gsub(/[" '\''\r]/, "", v) } END { print v }' "$Z2K_TIKTOK_CONFIG" 2>/dev/null)
    [ "$_mode" = manual ] && printf 'manual\n' || printf 'auto\n'
}

_z2k_ow_tiktok_manual_ip() {
    awk -F= '$1 == "Z2K_TIKTOK_MANUAL_IP" { v=$2; gsub(/[" '\''\r]/, "", v) } END { print v }' "$Z2K_TIKTOK_CONFIG" 2>/dev/null
}

_z2k_ow_tiktok_config_set() {
    local _key="$1" _value="$2"
    if command -v set_flag >/dev/null 2>&1; then
        set_flag "$_key" "$_value" "$Z2K_TIKTOK_CONFIG"
    elif grep -q "^${_key}=" "$Z2K_TIKTOK_CONFIG" 2>/dev/null; then
        sed -i "s/^${_key}=.*/${_key}=${_value}/" "$Z2K_TIKTOK_CONFIG"
    else
        printf '%s=%s\n' "$_key" "$_value" >> "$Z2K_TIKTOK_CONFIG"
    fi
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
    local _now _expected_mode="${1:-}"
    if ! z2k_ow_tiktok_enabled; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _now=$(date +%s 2>/dev/null || echo 0)
        _Z2K_TIKTOK_CANDIDATE_POOL_STATE=""
        _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=""
        _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=""
        _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE=""
        _z2k_ow_tiktok_state_write_apply 0 0 off "" "" 0 0 disabled 0 0 "$_now" "" "" "" "" off
        return 2
    fi
    _z2k_ow_tiktok_runtime_allowed || return 2
    if [ -n "$_expected_mode" ] && [ "$(z2k_ow_tiktok_mode)" != "$_expected_mode" ]; then
        return 2
    fi
    if z2k_ow_tiktok_external_override; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _now=$(date +%s 2>/dev/null || echo 0)
        _z2k_ow_tiktok_state_write_apply 0 0 external "" "" 0 0 external-dns-owner 0 0 "$_now" "" "" "" "" external
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

_z2k_ow_tiktok_restart_dnsmasq() {
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_DNSMASQ_INIT" restart >/dev/null 2>&1
}

_z2k_ow_tiktok_address_entry() {
    printf '/%s/%s' "${2:-$Z2K_TIKTOK_HOST}" "$1"
}

_z2k_ow_tiktok_address_registered() {
    local _entry="$1"
    "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | awk -F= -v entry="$_entry" '
            $1 ~ /\.address$/ {
                count=split($2, values, /[[:space:]]+/)
                for (i=1; i<=count; i++) if (values[i] == entry) found=1
            }
            END { exit !found }
        '
}

_z2k_ow_tiktok_owned_address() {
    local _entry _ip _host _marker
    [ -r "$Z2K_TIKTOK_ADDRESS_MARKER" ] || return 1
    _marker=$(cat "$Z2K_TIKTOK_ADDRESS_MARKER" 2>/dev/null)
    [ -n "$_marker" ] || return 1
    for _entry in $(printf '%s' "$_marker" | tr ';' ' '); do
        case "$_entry" in
            "/$Z2K_TIKTOK_HOST/"*) _host="$Z2K_TIKTOK_HOST" ;;
            "/$Z2K_TIKTOK_EU_HOST/"*) _host="$Z2K_TIKTOK_EU_HOST" ;;
            *) return 1 ;;
        esac
        _ip=${_entry#"/$_host/"}
        _z2k_ow_tiktok_valid_ipv4 "$_ip" && _z2k_ow_tiktok_address_registered "$_entry" || return 1
    done
    return 0
}

_z2k_ow_tiktok_write_address_marker() {
    local _entry="$1" _tmp="${Z2K_TIKTOK_ADDRESS_MARKER}.new.$$"
    mkdir -p "$(dirname "$Z2K_TIKTOK_ADDRESS_MARKER")" 2>/dev/null || return 1
    printf '%s\n' "$_entry" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_ADDRESS_MARKER"
}

_z2k_ow_tiktok_effective_config_has() {
    local _entry="$1" _config
    if [ -n "$Z2K_TIKTOK_EFFECTIVE_CONFIG" ]; then
        [ -r "$Z2K_TIKTOK_EFFECTIVE_CONFIG" ] \
            && grep -Fxq "address=$_entry" "$Z2K_TIKTOK_EFFECTIVE_CONFIG"
        return $?
    fi
    for _config in /var/etc/dnsmasq.conf.*; do
        [ -r "$_config" ] || continue
        grep -Fxq "address=$_entry" "$_config" && return 0
    done
    return 1
}

_z2k_ow_tiktok_dns_answer_has() {
    local _ip="$1" _host="${2:-$Z2K_TIKTOK_HOST}" _raw
    _raw=$("$Z2K_TIKTOK_NSLOOKUP_BIN" "$_host" 127.0.0.1 2>/dev/null) || return 1
    printf '%s\n' "$_raw" | _z2k_ow_tiktok_parse_nslookup 127.0.0.1 | grep -Fxq "$_ip"
}

_z2k_ow_tiktok_verify_override() {
    local _ip="$1" _host _entry _tries
    for _host in "$Z2K_TIKTOK_HOST" "$Z2K_TIKTOK_EU_HOST"; do
        _entry=$(_z2k_ow_tiktok_address_entry "$_ip" "$_host")
        _z2k_ow_tiktok_address_registered "$_entry" || return 1
        _z2k_ow_tiktok_effective_config_has "$_entry" || return 1
        _tries=0
        while [ "$_tries" -lt "$Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES" ]; do
            _z2k_ow_tiktok_dns_answer_has "$_ip" "$_host" && break
            _tries=$((_tries + 1))
            [ "$_tries" -lt "$Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES" ] && sleep 1
        done
        [ "$_tries" -lt "$Z2K_TIKTOK_DNSMASQ_VERIFY_RETRIES" ] || return 1
    done
    return 0
}

# A future upstream implementation or a user-defined DNS override wins. We
# ignore only the exact address entry carrying our ownership marker.
z2k_ow_tiktok_external_override() {
    local _path _owned_address="" _host
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    if _z2k_ow_tiktok_owned_address; then
        _owned_address=$(cat "$Z2K_TIKTOK_ADDRESS_MARKER" 2>/dev/null)
    fi
    for _host in "$Z2K_TIKTOK_HOST" "$Z2K_TIKTOK_EU_HOST"; do
      if "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | awk -F= -v host="$_host" -v own="$_owned_address" '
            $1 ~ /\.(hostrecord|cname)$/ {
                value=substr($0, index($0, "=") + 1)
                n=split(value, fields, /[,\/=[:space:]]+/)
                for (i=1; i<=n; i++) if (tolower(fields[i]) == tolower(host)) found=1
            }
            $1 ~ /\.address$/ {
                n=split($2, entries, /[[:space:]]+/)
                for (i=1; i<=n; i++) {
                    m=split(entries[i], fields, /\//)
                    owned=0; own_count=split(own, own_entries, /;/)
                    for (j=1; j<=own_count; j++) if (entries[i] == own_entries[j]) owned=1
                    if (m >= 3 && tolower(fields[2]) == tolower(host) && !owned) found=1
                }
            }
            END { exit !found }
        '; then
        return 0
      fi
    done
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

_z2k_ow_tiktok_update_override() {
    local _ip="${1:-}" _entry="" _entries="" _old_entries="" _old_entry _host _changed=0 _legacy=0 _tries=0
    local _legacy_safe=0
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_UCI_BIN" -q show "$Z2K_TIKTOK_UCI_SECTION" >/dev/null 2>&1 || return 1
    if [ -n "$_ip" ]; then
        _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
        z2k_ow_tiktok_external_override && return 1
        for _host in "$Z2K_TIKTOK_HOST" "$Z2K_TIKTOK_EU_HOST"; do
            _entry=$(_z2k_ow_tiktok_address_entry "$_ip" "$_host")
            [ -n "$_entries" ] && _entries="$_entries;"
            _entries="$_entries$_entry"
        done
    fi

    if _z2k_ow_tiktok_owned_address; then
        _old_entries=$(cat "$Z2K_TIKTOK_ADDRESS_MARKER" 2>/dev/null)
    fi
    if _z2k_ow_tiktok_registered; then
        _z2k_ow_tiktok_owned && _z2k_ow_tiktok_hosts_content_owned || {
            echo "z2k-openwrt: preserving unowned TikTok addnhosts data" >&2
            return 1
        }
        _legacy=1
        _legacy_safe=1
    elif [ -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _z2k_ow_tiktok_owned; then
        _z2k_ow_tiktok_hosts_content_owned || return 1
        _legacy_safe=1
    fi

    if [ -n "$_old_entries" ]; then
        for _old_entry in $(printf '%s' "$_old_entries" | tr ';' ' '); do
            _tries=0
            while _z2k_ow_tiktok_address_registered "$_old_entry"; do
                "$Z2K_TIKTOK_UCI_BIN" del_list \
                    "$Z2K_TIKTOK_UCI_SECTION.address=$_old_entry" || return 1
                _changed=1
                _tries=$((_tries + 1))
                [ "$_tries" -lt 64 ] || return 1
            done
        done
    fi
    if [ "$_legacy" = 1 ]; then
        _tries=0
        while _z2k_ow_tiktok_registered; do
            "$Z2K_TIKTOK_UCI_BIN" del_list \
                "$Z2K_TIKTOK_UCI_SECTION.addnhosts=$Z2K_TIKTOK_HOSTS_FILE" || return 1
            _changed=1
            _tries=$((_tries + 1))
            [ "$_tries" -lt 64 ] || return 1
        done
    fi
    if [ -n "$_entries" ]; then
        for _entry in $(printf '%s' "$_entries" | tr ';' ' '); do
            if ! _z2k_ow_tiktok_address_registered "$_entry"; then
                "$Z2K_TIKTOK_UCI_BIN" add_list \
                    "$Z2K_TIKTOK_UCI_SECTION.address=$_entry" || return 1
                _changed=1
            fi
        done
    fi
    if [ "$_changed" = 1 ]; then
        "$Z2K_TIKTOK_UCI_BIN" commit dhcp || return 1
    fi
    if [ -n "$_entries" ]; then
        _z2k_ow_tiktok_write_address_marker "$_entries" || return 1
    elif [ -n "$_old_entries" ]; then
        rm -f "$Z2K_TIKTOK_ADDRESS_MARKER" || return 1
    fi

    if [ "$_changed" = 1 ] || { [ -n "$_ip" ] && ! _z2k_ow_tiktok_verify_override "$_ip"; }; then
        _z2k_ow_tiktok_runtime_allowed || return 0
        _z2k_ow_tiktok_restart_dnsmasq || return 1
    fi
    if [ -n "$_ip" ]; then
        _z2k_ow_tiktok_verify_override "$_ip" || return 1
    fi
    if [ "$_legacy_safe" = 1 ]; then
        rm -f "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_UCI_MARKER" \
            "$Z2K_TIKTOK_CONTENT_MARKER" || return 1
    fi
    return 0
}

z2k_ow_tiktok_prepare() {
    local _current
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_UCI_BIN" -q show "$Z2K_TIKTOK_UCI_SECTION" >/dev/null 2>&1 || return 1
    if _z2k_ow_tiktok_registered || { [ -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _z2k_ow_tiktok_owned; }; then
        _current=$(_z2k_ow_tiktok_state_get selected_ip)
        _z2k_ow_tiktok_update_override "$_current" || return 1
    fi
}

_z2k_ow_tiktok_set_host() {
    _z2k_ow_tiktok_runtime_allowed || return 0
    _z2k_ow_tiktok_update_override "$1"
}

z2k_ow_tiktok_clear() {
    local _had_owned=0
    _z2k_ow_tiktok_owned_address && _had_owned=1
    if _z2k_ow_tiktok_registered && _z2k_ow_tiktok_owned; then _had_owned=1; fi
    if [ -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _z2k_ow_tiktok_owned \
        && _z2k_ow_tiktok_hosts_content_owned; then _had_owned=1; fi
    [ "$_had_owned" = 1 ] || return 0
    _z2k_ow_tiktok_update_override ""
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
v77.tiktokcdn-eu.com|direct|managed-target
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

# Input rows are IP|domain|mode|resolver|source|cname, optionally followed by
# Check-Host city|country|ASN|TTL. Output rows merge both source families.
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
        function append_unique(array, ip, value, namespace, key) {
            if (value == "") return
            key=namespace SUBSEP ip SUBSEP value
            if (!seen[key]++) array[ip]=(array[ip] == "" ? value : array[ip] "," value)
        }
        function count_values(value, parts) {
            return value == "" ? 0 : split(value, parts, /,/)
        }
        function ensure(ip) {
            if (!ordered[ip]++) { order[++count]=ip; provenance[ip]="domain-resolution" }
        }
        valid_ip($1) {
            ip=$1; ensure(ip)
            if ($2 == "__CURATED__") {
                curated[ip]=1
                append_unique(geoHints, ip, $3, "geo")
                append_unique(modes, ip, "curated", "mode")
                append_unique(sources, ip, "curated-community-fallback", "source")
                next
            }
            if ($2 !~ /^[a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]*$/) next
            dns[ip]=1
            append_unique(domains, ip, $2, "domain")
            append_unique(modes, ip, $3, "mode")
            if ($3 == "check-host") {
                checkhost[ip]=1
                append_unique(checkNodes, ip, $4, "check-node")
                append_unique(checkCities, ip, $6, "check-city")
                append_unique(checkCountries, ip, $7, "check-country")
                append_unique(checkAsns, ip, $8, "check-asn")
                append_unique(checkTtls, ip, $9, "check-ttl")
                geo=($6 != "" && $7 != "" ? $6 ", " $7 : ($7 != "" ? $7 : $6))
                append_unique(geoHints, ip, geo, "geo")
            } else {
                localdns[ip]=1
                append_unique(resolvers, ip, $4, "resolver")
                append_unique(geoHints, ip, $7, "geo")
            }
            append_unique(sources, ip, $5, "source")
            if ($3 != "check-host") append_unique(cnames, ip, $6, "cname")
        }
        END {
            for (i=1; i<=count; i++) {
                ip=order[i]
                if ((localdns[ip] && checkhost[ip]) || (curated[ip] && (localdns[ip] || checkhost[ip]))) provenance[ip]="mixed"
                else if (checkhost[ip]) provenance[ip]="check-host-distributed-discovery"
                else if (!dns[ip]) provenance[ip]="curated-community-fallback"
                printf "%s|%s|%s|%s|%s|%s|%s|%s|%d|%d|0|%d|%d|%d|%s|%s|%s|%s|%s\n", \
                    ip, domains[ip], modes[ip], resolvers[ip], sources[ip], cnames[ip], geoHints[ip], provenance[ip], \
                    dns[ip] ? 1 : 0, curated[ip] ? 1 : 0, count_values(checkNodes[ip]), \
                    count_values(checkCountries[ip]), count_values(checkAsns[ip]), checkNodes[ip], \
                    checkCountries[ip], checkAsns[ip], checkCities[ip], checkTtls[ip]
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

_z2k_ow_tiktok_jshn_load() {
    # OpenWrt jshn's json_cleanup reads JSON_UNSET while json_load initializes it.
    # Keep that library's parsing inside the Check-Host helper subshells below.
    set +u
    JSON_PREFIX="${JSON_PREFIX:-}"
    . "$Z2K_TIKTOK_JSHN"
}

_z2k_ow_tiktok_checkhost_node_catalog() (
    local _json _node _asn _ip _location _country _city _rows="" _limit="${Z2K_TIKTOK_CHECKHOST_NODE_LIMIT:-8}"
    [ "${Z2K_TIKTOK_CHECKHOST_ENABLED:-1}" = 1 ] || return 1
    [ -r "$Z2K_TIKTOK_JSHN" ] || return 1
    command -v "$Z2K_TIKTOK_CURL_BIN" >/dev/null 2>&1 || return 1
    case "$_limit" in ''|*[!0-9]*|0) _limit=8 ;; esac
    [ "$_limit" -le 12 ] 2>/dev/null || _limit=12
    _z2k_ow_tiktok_jshn_load || return 1
    _json=$("$Z2K_TIKTOK_CURL_BIN" --fail --silent --show-error --connect-timeout 3 --max-time 6 \
        -H 'Accept: application/json' "$Z2K_TIKTOK_CHECKHOST_API/nodes/ips" 2>/dev/null) || return 1
    json_load "$_json" || return 1
    json_select nodes || return 1
    json_get_keys _node_keys || return 1
    for _node in $_node_keys; do
        case "$_node" in *[!a-zA-Z0-9.-]*) continue ;; esac
        case "$_node" in *.node.check-host.net) ;; *) continue ;; esac
        json_select "$_node" || continue
        json_get_var _asn asn
        json_get_var _ip ip
        json_get_values _location location
        json_select ..
        _z2k_ow_tiktok_valid_ipv4 "$_ip" || continue
        set -- $_location
        _country_name=$(printf '%s' "${2:-}" | tr '|;\r\n' '    ')
        _city=$(printf '%s' "${3:-}" | tr '|;\r\n' '    ')
        _asn=$(printf '%s' "$_asn" | tr '|;\r\n' '    ')
        [ -n "$_country_name" ] || continue
        [ -n "$_city" ] || continue
        [ -n "$_asn" ] || continue
        [ -n "$_rows" ] && _rows="$_rows\n"
        _rows="$_rows$_node|$_country_name|$_city|$_asn"
    done
    [ -n "$_rows" ] || return 1
    printf '%b\n' "$_rows" | awk -F'|' -v limit="$_limit" '
        function emit(row, parts, key) {
            split(row, parts, /\|/); key=parts[1]
            if (key == "" || seen[key] || n >= limit) return
            seen[key]=1; print row; n++
        }
        { rows[NR]=$0; countries[$2]=1; asns[$4]=1 }
        END {
            for (i=1; i<=NR && n<limit; i++) { split(rows[i], f, /\|/); if (!country_seen[f[2]]++) emit(rows[i]) }
            for (i=1; i<=NR && n<limit; i++) { split(rows[i], f, /\|/); if (!asn_seen[f[4]]++) emit(rows[i]) }
            for (i=1; i<=NR && n<limit; i++) emit(rows[i])
        }
    '
)

_z2k_ow_tiktok_checkhost_request_id() (
    local _json="$1"
    [ -r "$Z2K_TIKTOK_JSHN" ] || return 1
    _z2k_ow_tiktok_jshn_load || return 1
    json_load "$_json" || return 1
    json_get_var _request_id request_id
    case "$_request_id" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    printf '%s\n' "$_request_id"
)

_z2k_ow_tiktok_checkhost_parse_results() (
    local _json="$1" _domain="$2" _node_rows="$3" _node _index _ip _ttl _meta
    [ -r "$Z2K_TIKTOK_JSHN" ] || return 1
    _z2k_ow_tiktok_jshn_load || return 1
    json_load "$_json" || return 1
    json_get_keys _result_nodes || return 1
    for _node in $_result_nodes; do
        case "$_node" in *[!a-zA-Z0-9.-]*) continue ;; esac
        case "$_node" in *.node.check-host.net) ;; *) continue ;; esac
        _meta=$(printf '%s\n' "$_node_rows" | awk -F'|' -v node="$_node" '$1 == node { print $2 "|" $3 "|" $4; exit }')
        [ -n "$_meta" ] || continue
        json_select "$_node" || continue
        json_get_keys _records || { json_select ..; continue; }
        for _index in $_records; do
            json_select "$_index" || continue
            json_get_values _ips A
            json_get_var _ttl TTL
            json_select ..
            for _ip in $_ips; do
                _z2k_ow_tiktok_valid_ipv4 "$_ip" || continue
                case "$_ttl" in ''|*[!0-9]*) _ttl="" ;; esac
                printf '%s|%s|%s|%s|%s|%s|%s\n' "$_ip" "$_node" \
                    "${_meta%%|*}" "$(printf '%s' "$_meta" | cut -d'|' -f2)" \
                    "$(printf '%s' "$_meta" | cut -d'|' -f3)" "$_domain" "$_ttl"
            done
        done
        json_select ..
    done
)

_z2k_ow_tiktok_checkhost_discover() {
    local _nodes _node_rows _domain _node _json _request_id _results _attempt _rows="" _part=""
    local _domain_index=0 _domain_total _node_count _observation_count _domain_rows _poll_index
    if ! _node_rows=$(_z2k_ow_tiktok_checkhost_node_catalog); then
        _z2k_ow_tiktok_job_progress "Check-Host недоступен; использую локальный DNS, cache и curated pool"
        return 1
    fi
    _nodes=$(printf '%s\n' "$_node_rows" | cut -d'|' -f1 | tr '\n' ' ')
    _node_count=$(printf '%s\n' "$_node_rows" | awk 'NF { n++ } END { print n+0 }')
    _domain_total=$(_z2k_ow_tiktok_domain_catalog | awk 'NF { n++ } END { print n+0 }')
    _z2k_ow_tiktok_job_progress "Check-Host: распределённое DNS-обнаружение через узлов: $_node_count"
    while IFS='|' read -r _domain _mode _provenance; do
        [ -n "$_domain" ] || continue
        _part=""; _domain_rows=""
        _domain_index=$((_domain_index + 1))
        _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total] $_domain: запрашиваю DNS-наблюдения"
        set -- --fail --silent --show-error --connect-timeout 3 --max-time 6 \
            -H 'Accept: application/json' --get "$Z2K_TIKTOK_CHECKHOST_API/check-dns" \
            --data-urlencode "host=$_domain"
        for _node in $_nodes; do set -- "$@" --data-urlencode "node=$_node"; done
        if ! _json=$("$Z2K_TIKTOK_CURL_BIN" "$@" 2>/dev/null); then
            _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total]: запрос не удался, использую fallback"
            continue
        fi
        if ! _request_id=$(_z2k_ow_tiktok_checkhost_request_id "$_json"); then
            _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total]: API не вернул request_id, использую fallback"
            continue
        fi
        _attempt=0
        while [ "$_attempt" -lt "${Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS:-3}" ]; do
            _poll_index=$((_attempt + 1))
            _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total] $_domain: опрос результата ($_poll_index/${Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS:-3})"
            _results=$("$Z2K_TIKTOK_CURL_BIN" --fail --silent --show-error --connect-timeout 3 --max-time 5 \
                -H 'Accept: application/json' "$Z2K_TIKTOK_CHECKHOST_API/check-result/$_request_id" 2>/dev/null) || _results=""
            if [ -n "$_results" ]; then
                _part=$(_z2k_ow_tiktok_checkhost_parse_results "$_results" "$_domain" "$_node_rows")
                if [ -n "$_part" ]; then
                    [ -n "$_domain_rows" ] && _domain_rows="$_domain_rows\n"
                    _domain_rows="$_domain_rows$_part"
                fi
            fi
            _attempt=$((_attempt + 1))
            [ "$_attempt" -lt "${Z2K_TIKTOK_CHECKHOST_POLL_ATTEMPTS:-3}" ] \
                && sleep "${Z2K_TIKTOK_CHECKHOST_POLL_SECONDS:-1}"
        done
        if [ -n "$_domain_rows" ]; then
            _domain_rows=$(printf '%b\n' "$_domain_rows" | awk -F'|' '!seen[$0]++')
            _observation_count=$(printf '%s\n' "$_domain_rows" | awk 'NF { n++ } END { print n+0 }')
            _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total] $_domain: получено уникальных IPv4-наблюдений: $_observation_count"
            [ -n "$_rows" ] && _rows="$_rows\n"
            _rows="$_rows$_domain_rows"
        else
            _z2k_ow_tiktok_job_progress "Check-Host [$_domain_index/$_domain_total] $_domain: IPv4-ответов нет; сохраняю fallback"
        fi
        _part=""
    done <<EOF_CHECKHOST_DOMAINS
$(_z2k_ow_tiktok_domain_catalog)
EOF_CHECKHOST_DOMAINS
    [ -n "$_rows" ] || return 1
    printf '%b\n' "$_rows" | awk -F'|' '!seen[$0]++'
}

_z2k_ow_tiktok_checkhost_cache_write() {
    local _observations="$1" _epoch="$2" _tmp="${Z2K_TIKTOK_STATE_FILE}.new.$$"
    mkdir -p "$(dirname "$Z2K_TIKTOK_STATE_FILE")" 2>/dev/null || return 1
    if [ -r "$Z2K_TIKTOK_STATE_FILE" ]; then
        awk -v observations="$_observations" -v epoch="$_epoch" '
            /^checkhost_observations=/ { print "checkhost_observations=" observations; have_observations=1; next }
            /^checkhost_cache_epoch=/ { print "checkhost_cache_epoch=" epoch; have_epoch=1; next }
            { print }
            END {
                if (!have_observations) print "checkhost_observations=" observations
                if (!have_epoch) print "checkhost_cache_epoch=" epoch
            }
        ' "$Z2K_TIKTOK_STATE_FILE" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    else
        printf 'checkhost_observations=%s\ncheckhost_cache_epoch=%s\n' "$_observations" "$_epoch" > "$_tmp" || return 1
    fi
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_STATE_FILE"
}

_z2k_ow_tiktok_checkhost_cache_expired() {
    local _epoch="$(_z2k_ow_tiktok_state_get checkhost_cache_epoch)" _now
    case "$_epoch" in ''|*[!0-9]*) return 0 ;; esac
    _now=$(date +%s 2>/dev/null) || _now=0
    [ $((_now - _epoch)) -ge "${Z2K_TIKTOK_CHECKHOST_TTL:-21600}" ]
}

_z2k_ow_tiktok_discover_combined() {
    local _force="${1:-0}" _local_rows _check_rows _cached _epoch
    _local_rows=$(_z2k_ow_tiktok_discover_candidates)
    if [ "${Z2K_TIKTOK_CHECKHOST_ENABLED:-1}" = 1 ] \
        && { [ "$_force" = 1 ] || [ -z "$(_z2k_ow_tiktok_state_get checkhost_observations)" ] || _z2k_ow_tiktok_checkhost_cache_expired; }; then
        if _check_rows=$(_z2k_ow_tiktok_checkhost_discover); then
            _epoch=$(date +%s 2>/dev/null) || _epoch=0
            _check_rows=$(printf '%s\n' "$_check_rows" | _z2k_ow_tiktok_serialize_lines)
            _z2k_ow_tiktok_checkhost_cache_write "$_check_rows" "$_epoch" || :
        fi
    fi
    _cached=$(_z2k_ow_tiktok_state_get checkhost_observations)
    {
        printf '%s' "$_cached" | tr ';' '\n' | while IFS='|' read -r _ip _node _country _city _asn _domain _ttl; do
            [ -n "$_ip" ] || continue
            printf '%s|%s|check-host|%s|check-host|%s|%s|%s|%s\n' \
                "$_ip" "$_domain" "$_node" "$_city" "$_country" "$_asn" "$_ttl"
        done
        printf '%s\n' "$_local_rows"
    }
}

# stdout: detailed target probe result. curl validates the normal certificate
# for the managed hostname because --insecure is deliberately never used.
_z2k_ow_tiktok_probe_report() {
    local _ip="$1" _host="${2:-$Z2K_TIKTOK_HOST}" _raw _metrics _http _connect _tls _total _ms _connect_ms _tls_ms _pop _cache _server _curl_rc _tcp _tls_ok _verified
    _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
    case "$_host" in "$Z2K_TIKTOK_HOST"|"$Z2K_TIKTOK_EU_HOST") ;; *) return 1 ;; esac
    command -v "$Z2K_TIKTOK_CURL_BIN" >/dev/null 2>&1 || return 1
    if _raw=$("$Z2K_TIKTOK_CURL_BIN" --ipv4 --silent --show-error --dump-header - \
        --output /dev/null --stderr /dev/null --connect-timeout 4 --max-time 7 \
        --write-out '\nZ2M_TIKTOK_METRICS:%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}' \
        --resolve "$_host:443:$_ip" "https://$_host/" 2>/dev/null); then
        _curl_rc=0
    else
        _curl_rc=$?
    fi
    _metrics=$(printf '%s\n' "$_raw" | sed -n 's/^Z2M_TIKTOK_METRICS://p' | tail -1)
    IFS='|' read -r _http _connect _tls _total <<EOF_METRICS
$_metrics
EOF_METRICS
    _ms=$(awk -v v="$_total" 'BEGIN { if (v+0 > 0) printf "%d", (v+0)*1000 }') || _ms=""
    _connect_ms=$(awk -v v="$_connect" 'BEGIN { if (v+0 > 0) printf "%d", (v+0)*1000 }') || _connect_ms=""
    _tls_ms=$(awk -v v="$_tls" 'BEGIN { if (v+0 > 0) printf "%d", (v+0)*1000 }') || _tls_ms=""
    _tcp=failed; [ -n "$_connect_ms" ] && _tcp=ok
    _tls_ok=failed; [ -n "$_tls_ms" ] && _tls_ok=ok
    _verified=failed
    if [ "$_curl_rc" = 0 ] && [ "$_tls_ok" = ok ]; then _verified=verified; fi
    _pop=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^x-77-pop:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    _cache=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^x-77-cache:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    _server=$(printf '%s\n' "$_raw" | awk 'tolower($0) ~ /^server:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[\r]/, ""); print; exit}')
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$_ip" "$_ms" "$_connect_ms" "$_tls_ms" "${_http:-}" "${_pop:-}" \
        "${_cache:-}" "${_server:-}" "$_tcp" "$_tls_ok" "$_verified"
    [ "$_verified" = verified ]
}

# stdout is a target compatibility row. Both hostnames are independently
# pinned with curl --resolve; the first eight columns preserve legacy state.
_z2k_ow_tiktok_probe_matrix() {
    local _ip="$1" _v77 _eu _v77_rc=0 _eu_rc=0
    _v77=$(_z2k_ow_tiktok_probe_report "$_ip" "$Z2K_TIKTOK_HOST") || _v77_rc=$?
    _eu=$(_z2k_ow_tiktok_probe_report "$_ip" "$Z2K_TIKTOK_EU_HOST") || _eu_rc=$?
    [ -n "$_v77" ] || _v77="$_ip||||||||failed|failed|failed"
    [ -n "$_eu" ] || _eu="$_ip||||||||failed|failed|failed"
    printf '%s|%s|%s\n' \
        "$(printf '%s' "$_v77" | cut -d'|' -f1-11)" \
        "$(printf '%s' "$_eu" | cut -d'|' -f2-11)" \
        "$([ "$_v77_rc" = 0 ] && [ "$_eu_rc" = 0 ] && printf compatible || printf incompatible)"
    [ "$_v77_rc" = 0 ] && [ "$_eu_rc" = 0 ]
}

# ICMP is presentation-only. Missing ping support, packet loss, or a CDN that
# blocks echo requests leaves this field empty and never affects verification.
_z2k_ow_tiktok_icmp_latency_ms() {
    local _raw _value
    command -v "$Z2K_TIKTOK_PING_BIN" >/dev/null 2>&1 || return 0
    _raw=$("$Z2K_TIKTOK_PING_BIN" -n -c 1 -W 1 "$1" 2>/dev/null) || return 0
    _value=$(printf '%s\n' "$_raw" | sed -n 's/.*time[=<]\([0-9][0-9.]*\)[[:space:]]*ms.*/\1/p' | head -1)
    [ -n "$_value" ] || return 0
    awk -v value="$_value" 'BEGIN {
        if (value !~ /^[0-9]+([.][0-9]+)?$/) exit
        ms=int(value+0.5); if (ms < 1) ms=1; print ms
    }'
}

# Auto-selection and manual apply both require a fresh successful probe for
# each managed target. HTTP status remains diagnostic; curl/TLS success is the gate.
_z2k_ow_tiktok_probe() {
    local _row
    _row=$(_z2k_ow_tiktok_probe_matrix "$1") || return 1
    printf '%s\n' "$_row"
}

z2k_ow_tiktok_manual_check() {
    local _ip _row="${1:-}" _now _dns_applied=0 _fail=0
    _ip=$(_z2k_ow_tiktok_manual_ip)
    _now=$(date +%s 2>/dev/null) || _now=0
    if ! _z2k_ow_tiktok_valid_ipv4 "$_ip"; then
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if _z2k_ow_tiktok_recheck_before_apply manual; then
            z2k_ow_tiktok_clear || { _z2k_ow_tiktok_apply_lock_release; return 1; }
            _z2k_ow_tiktok_state_write_apply 0 0 manual-unavailable "" "" 0 0 manual-ip-missing 0 0 "$_now"
        fi
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi

    if [ -z "$_row" ]; then
        _z2k_ow_tiktok_job_progress "TikTok manual: перепроверяю $_ip для $Z2K_TIKTOK_HOST и $Z2K_TIKTOK_EU_HOST"
    fi
    if [ -z "$_row" ] && ! _row=$(_z2k_ow_tiktok_probe "$_ip"); then
        _z2k_ow_tiktok_job_progress "TikTok manual: $_ip не прошёл TCP/TLS/SNI; выбранный адрес сохранён"
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if _z2k_ow_tiktok_recheck_before_apply manual \
            && [ "$(z2k_ow_tiktok_mode)" = manual ] \
            && [ "$(_z2k_ow_tiktok_manual_ip)" = "$_ip" ]; then
            _z2k_ow_tiktok_verify_override "$_ip" && _dns_applied=1
            _fail=$(_z2k_ow_tiktok_state_get failure_count); case "$_fail" in ''|*[!0-9]*) _fail=0 ;; esac
            _fail=$((_fail + 1))
            _z2k_ow_tiktok_state_write_apply 0 "$_dns_applied" manual-unavailable "$_ip" \
                "$(_z2k_ow_tiktok_state_get latency_ms)" "$_fail" "$(_z2k_ow_tiktok_state_get last_verified_epoch)" \
                manual-cdn-unavailable
        fi
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi

    _z2k_ow_tiktok_job_progress "TikTok manual: $_ip прошёл проверку обоих доменов; применяю owned dnsmasq override"
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    if ! _z2k_ow_tiktok_recheck_before_apply manual \
        || [ "$(z2k_ow_tiktok_mode)" != manual ] \
        || [ "$(_z2k_ow_tiktok_manual_ip)" != "$_ip" ]; then
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi
    if ! _z2k_ow_tiktok_set_host "$_ip"; then
        _z2k_ow_tiktok_job_progress "TikTok manual: dnsmasq не подтвердил override для $_ip"
        _z2k_ow_tiktok_state_write_apply 1 0 dns-apply-error "$_ip" "$(printf '%s' "$_row" | cut -d'|' -f2)" \
            0 "$_now" dns-apply-failed
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi
    _z2k_ow_tiktok_job_progress "TikTok manual: effective DNS подтверждает $_ip; сохраняю результат"
    _Z2K_TIKTOK_PROBE_OBSERVATIONS_STATE="$(_z2k_ow_tiktok_state_get probe_observations)"
    _z2k_ow_tiktok_state_write_apply 1 1 healthy "$_ip" "$(printf '%s' "$_row" | cut -d'|' -f2)" 0 "$_now" \
        manual-selection "$_now" "$(_z2k_ow_tiktok_state_get last_discovery_epoch)" "$_now" \
        manual manual manual-selection "" healthy "$(printf '%s' "$_row" | cut -d'|' -f3)" \
        "$(printf '%s' "$_row" | cut -d'|' -f4)" "$(printf '%s' "$_row" | cut -d'|' -f5)" \
        "$(printf '%s' "$_row" | cut -d'|' -f6)" "$(printf '%s' "$_row" | cut -d'|' -f7)" \
        "$(printf '%s' "$_row" | cut -d'|' -f8)" manual manual "" manual-selection "" 0 0 1
    _z2k_ow_tiktok_apply_lock_release
    return 0
}

z2k_ow_tiktok_manual_select() {
    local _ip="$1" _row
    _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
    z2k_ow_tiktok_enabled || return 1
    # The candidate list is only a discovery snapshot. Re-probe the exact
    # managed hostname immediately before persisting and applying a choice.
    _z2k_ow_tiktok_job_progress "TikTok manual: перепроверяю выбранный $_ip для обоих managed targets"
    if ! _row=$(_z2k_ow_tiktok_probe "$_ip"); then
        _z2k_ow_tiktok_job_progress "TikTok manual: $_ip не проходит TLS/SNI probe; выбор и DNS override не изменены"
        if [ "$(z2k_ow_tiktok_mode)" = manual ] && [ "$(_z2k_ow_tiktok_manual_ip)" = "$_ip" ]; then
            z2k_ow_tiktok_manual_check >/dev/null 2>&1 || true
        fi
        return 1
    fi
    _z2k_ow_tiktok_job_progress "TikTok manual: $_ip подтверждён; сохраняю manual mode и применяю DNS override"
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    if ! z2k_ow_tiktok_enabled; then
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi
    if ! _z2k_ow_tiktok_config_set Z2K_TIKTOK_MANUAL_IP "$_ip"; then
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi
    if ! _z2k_ow_tiktok_config_set Z2K_TIKTOK_MODE manual; then
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi
    _z2k_ow_tiktok_apply_lock_release
    z2k_ow_tiktok_manual_check "$_row"
}

z2k_ow_tiktok_use_auto() {
    _z2k_ow_tiktok_job_progress "TikTok: возвращаю режим auto и очищаю ручной IP"
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    if ! _z2k_ow_tiktok_config_set Z2K_TIKTOK_MODE auto \
        || ! _z2k_ow_tiktok_config_set Z2K_TIKTOK_MANUAL_IP ""; then
        _z2k_ow_tiktok_apply_lock_release
        return 1
    fi
    _z2k_ow_tiktok_apply_lock_release
    _z2k_ow_tiktok_job_progress "TikTok: запускаю штатный discovery и автоматический выбор"
    z2k_ow_tiktok_check explicit
}

_z2k_ow_tiktok_state_update_candidates() {
    local _pool="$1" _observations="$2" _now _tmp="${Z2K_TIKTOK_STATE_FILE}.new.$$"
    _now=$(date +%s 2>/dev/null) || _now=0
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    mkdir -p "$(dirname "$Z2K_TIKTOK_STATE_FILE")" 2>/dev/null || return 1
    if [ -r "$Z2K_TIKTOK_STATE_FILE" ]; then
        awk -v pool="$_pool" -v observations="$_observations" -v checked="$_now" '
            /^candidate_pool=/ { print "candidate_pool=" pool; have_pool=1; next }
            /^probe_observations=/ { print "probe_observations=" observations; have_observations=1; next }
            /^candidates_checked_epoch=/ { print "candidates_checked_epoch=" checked; have_checked=1; next }
            { print }
            END {
                if (!have_pool) print "candidate_pool=" pool
                if (!have_observations) print "probe_observations=" observations
                if (!have_checked) print "candidates_checked_epoch=" checked
            }
        ' "$Z2K_TIKTOK_STATE_FILE" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    else
        printf 'candidate_pool=%s\nprobe_observations=%s\ncandidates_checked_epoch=%s\n' "$_pool" "$_observations" "$_now" > "$_tmp" || return 1
    fi
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_STATE_FILE"
}

_z2k_ow_tiktok_probe_progress_line() {
    local _index="$1" _total="$2" _pool="$3" _row="$4"
    local _ip _v77 _eu _v77_ms _eu_ms _icmp _source _geo _v77_display _eu_display
    _ip=$(printf '%s' "$_row" | cut -d'|' -f1)
    _v77=$(printf '%s' "$_row" | cut -d'|' -f11)
    _eu=$(printf '%s' "$_row" | cut -d'|' -f21)
    _v77_ms=$(printf '%s' "$_row" | cut -d'|' -f2)
    _eu_ms=$(printf '%s' "$_row" | cut -d'|' -f12)
    _icmp=$(printf '%s' "$_row" | cut -d'|' -f23)
    _source=$(printf '%s\n' "$_pool" | tr ';' '\n' | awk -F'|' -v ip="$_ip" '$1 == ip { print $5; exit }')
    _geo=$(printf '%s\n' "$_pool" | tr ';' '\n' | awk -F'|' -v ip="$_ip" '$1 == ip { print $7; exit }')
    _v77_display="✕ timeout"
    [ "$_v77" = verified ] && _v77_display="✓ ${_v77_ms:-?} мс"
    _eu_display="✕ timeout"
    [ "$_eu" = verified ] && _eu_display="✓ ${_eu_ms:-?} мс"
    printf '[%s/%s] %s — v77 %s; v77-eu %s' "$_index" "$_total" "$_ip" "$_v77_display" "$_eu_display"
    [ -z "$_geo" ] || printf ' — %s' "$_geo"
    [ -z "$_source" ] || printf ' (%s)' "$_source"
    [ -z "$_icmp" ] || printf '; ICMP %s мс' "$_icmp"
    printf '\n'
}

z2k_ow_tiktok_probe_all() {
    local _pool _ip _row _icmp _idx=0 _batch=0 _parallel="${Z2K_TIKTOK_CANDIDATE_PARALLELISM:-4}"
    local _limit="${Z2K_TIKTOK_CANDIDATE_LIMIT:-64}"
    local _tmp="${Z2K_TMP:-/tmp/z2k}/tiktok-probes.$$" _pids="" _pid _obs="" _result
    local _total=0 _batch_start=0 _batch_end=0 _batch_index _stats _saved_ifs _checked=0 _compatible=0 _incompatible=0 _best_ip="" _best_ms=""
    case "$_parallel" in ''|*[!0-9]*|0) _parallel=4 ;; esac
    [ "$_parallel" -le 8 ] 2>/dev/null || _parallel=8
    case "$_limit" in ''|*[!0-9]*|0) _limit=64 ;; esac
    [ "$_limit" -le 64 ] 2>/dev/null || _limit=64
    _z2k_ow_tiktok_job_progress "Обнаружение CDN-кандидатов: Check-Host, локальный DNS, cache и curated pool"
    _row=$(_z2k_ow_tiktok_discover_combined 1)
    _pool=$(printf '%s\n' "$_row" | _z2k_ow_tiktok_candidate_pool | _z2k_ow_tiktok_serialize_lines)
    _total=$(printf '%s\n' "$_pool" | tr ';' '\n' | awk -v limit="$_limit" 'NF && n < limit { n++ } END { print n+0 }')
    if [ "$_total" -eq 0 ]; then
        _z2k_ow_tiktok_job_progress "Кандидаты не найдены; текущий выбор CDN не изменён"
    else
        _z2k_ow_tiktok_job_progress "Найдено кандидатов: $_total; проверяю TCP/TLS/SNI для $Z2K_TIKTOK_HOST и $Z2K_TIKTOK_EU_HOST (параллельно: $_parallel)"
    fi
    mkdir -p "$_tmp" 2>/dev/null || return 1
    while IFS='|' read -r _ip _; do
        _z2k_ow_tiktok_valid_ipv4 "$_ip" || continue
        _idx=$((_idx + 1))
        [ "$_idx" -le "$_limit" ] || break
        [ "$_batch" -gt 0 ] || _batch_start=$_idx
        (
            if _row=$(_z2k_ow_tiktok_probe_matrix "$_ip"); then _result=0; else _result=1; fi
            _icmp=$(_z2k_ow_tiktok_icmp_latency_ms "$_ip")
            printf '%s|%s|%s\n' "$_row" "$_icmp" "$_result" > "$_tmp/$_idx.result"
        ) &
        _pids="$_pids $!"
        _batch=$((_batch + 1))
        if [ "$_batch" -ge "$_parallel" ]; then
            for _pid in $_pids; do wait "$_pid" || true; done
            _batch_end=$_idx
            _batch_index=$_batch_start
            while [ "$_batch_index" -le "$_batch_end" ]; do
                _row=$(cat "$_tmp/$_batch_index.result" 2>/dev/null)
                [ -z "$_row" ] || _z2k_ow_tiktok_job_progress "$(_z2k_ow_tiktok_probe_progress_line "$_batch_index" "$_total" "$_pool" "$_row")"
                _batch_index=$((_batch_index + 1))
            done
            _batch_start=$((_batch_end + 1))
            _pids=""; _batch=0
        fi
    done <<EOF_TIKTOK_CANDIDATES
$(printf '%s' "$_pool" | tr ';' '\n')
EOF_TIKTOK_CANDIDATES
    if [ -n "$_pids" ]; then
        for _pid in $_pids; do wait "$_pid" || true; done
        _batch_end=$_idx
        _batch_index=$_batch_start
        while [ "$_batch_index" -le "$_batch_end" ]; do
            _row=$(cat "$_tmp/$_batch_index.result" 2>/dev/null)
            [ -z "$_row" ] || _z2k_ow_tiktok_job_progress "$(_z2k_ow_tiktok_probe_progress_line "$_batch_index" "$_total" "$_pool" "$_row")"
            _batch_index=$((_batch_index + 1))
        done
    fi

    _idx=0
    while [ "$_idx" -lt "$_limit" ]; do
        _idx=$((_idx + 1))
        [ -r "$_tmp/$_idx.result" ] || continue
        _row=$(cat "$_tmp/$_idx.result")
        [ -n "$_obs" ] && _obs="$_obs;"
        _obs="$_obs$(printf '%s' "$_row" | cut -d'|' -f1-23)"
    done
    _stats=$(for _result_file in "$_tmp"/*.result; do [ -f "$_result_file" ] && cat "$_result_file"; done \
        | awk -F'|' '
            NF >= 22 {
                total++
                if ($22 == "compatible") {
                    compatible++
                    if ($2 ~ /^[0-9]+$/ && (!best_ms || $2 < best_ms)) { best_ms=$2; best_ip=$1 }
                } else incompatible++
            }
            END { printf "%d|%d|%d|%s|%s\n", total+0, compatible+0, incompatible+0, best_ip, best_ms }
        ')
    _saved_ifs=$IFS
    IFS='|' read -r _checked _compatible _incompatible _best_ip _best_ms <<EOF_TIKTOK_STATS
$_stats
EOF_TIKTOK_STATS
    IFS=$_saved_ifs
    _z2k_ow_tiktok_apply_lock_acquire || { rm -rf "$_tmp"; return 1; }
    _z2k_ow_tiktok_state_update_candidates "$_pool" "$_obs"
    local _rc=$?
    _z2k_ow_tiktok_apply_lock_release
    rm -rf "$_tmp"
    if [ "$_rc" = 0 ]; then
        _summary="Итог: проверено $_checked кандидата — совместимы с обоими доменами: $_compatible, недоступны хотя бы для одного: $_incompatible. Результаты сохранены; текущий CDN не переключался."
        [ -z "$_best_ip" ] || _summary="$_summary Лучший проверенный v77: $_best_ip, ${_best_ms} мс."
        _z2k_ow_tiktok_job_progress "$_summary"
    else
        _z2k_ow_tiktok_job_progress "Результаты проб не удалось сохранить в runtime state"
    fi
    return "$_rc"
}

z2k_ow_tiktok_check() {
    local _mode="${1:-automatic}" _force=0 _scheduled=0 _now _current _current_latency _current_verified _selected_at _discovered _evaluated
    local _fail _current_row="" _current_ms="" _current_ok=0 _current_probed=0 _pool _resolution _ip _row _best_row="" _best_ms="" _probes=0 _success=0 _candidate_index=0 _stable_row _reason
    local _domains _modes _resolvers _sources _cnames _geo _provenance _dns _curated _decision _stable_at
    local _candidate_ch_nodes _candidate_ch_countries _candidate_ch_asns _candidate_ch_node_names
    local _candidate_ch_country_names _candidate_ch_asn_names _candidate_ch_cities _candidate_ch_ttls
    local _best_domain="" _best_domains="" _best_mode="" _best_modes="" _best_provenance="" _best_geo="" _best_resolvers="" _best_sources="" _best_cname="" _best_dns=0 _best_curated=0 _best_ch_nodes=0
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
        if _z2k_ow_tiktok_recheck_before_apply auto; then
            _z2k_ow_tiktok_apply_lock_release
        else
            _z2k_ow_tiktok_apply_lock_release
            return 0
        fi
    fi
    z2k_ow_tiktok_prepare || {
        _z2k_ow_tiktok_apply_lock_acquire || return 1
        if _z2k_ow_tiktok_recheck_before_apply auto; then
            _z2k_ow_tiktok_state_write_apply 0 0 degraded "" "" 0 0 dnsmasq-prepare-failed 0 0 "$_now"
        fi
        _z2k_ow_tiktok_apply_lock_release
        return 1
    }
    if [ "$(z2k_ow_tiktok_mode)" = manual ]; then
        if z2k_ow_tiktok_manual_check; then return 0; fi
        # An unavailable strict manual choice is valid runtime state, not a
        # failed cron/check invocation. The selected address remains pinned;
        # manual_select still returns failure to the interactive caller.
        [ "$(_z2k_ow_tiktok_state_get state)" = manual-unavailable ] && return 0
        return 1
    fi
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
            if ! _z2k_ow_tiktok_recheck_before_apply auto; then
                _z2k_ow_tiktok_apply_lock_release
                return 0
            fi
            if ! _z2k_ow_tiktok_set_host "$_current"; then
                _z2k_ow_tiktok_state_write_apply 1 0 dns-apply-error "$_current" "$(printf '%s' "$_current_row" | cut -d'|' -f2)" 0 "$_now" dns-apply-failed
                _z2k_ow_tiktok_apply_lock_release
                return 1
            fi
            _z2k_ow_tiktok_state_write_apply 1 1 healthy "$_current" "$(printf '%s' "$_current_row" | cut -d'|' -f2)" 0 "$_now" current-ip-fast-path "${_selected_at:-$_now}" "${_discovered:-0}" "$_now" \
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
        if ! _z2k_ow_tiktok_recheck_before_apply auto; then
            _z2k_ow_tiktok_apply_lock_release
            return 0
        fi
        local _dns_applied=0
        _z2k_ow_tiktok_verify_override "$_current" && _dns_applied=1
        _z2k_ow_tiktok_state_write_apply 0 "$_dns_applied" degraded "$_current" "$_current_latency" "$_fail" "$_current_verified" transient-probe-failure \
            "${_selected_at:-$_current_verified}" "${_discovered:-0}" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" \
            "$_sel_provenance" "$_sel_geo" dead
        _z2k_ow_tiktok_apply_lock_release
        return 0
    fi

    _resolution=$(_z2k_ow_tiktok_discover_combined 0)
    _Z2K_TIKTOK_RESOLUTION_OBSERVATIONS_STATE=$(printf '%s\n' "$_resolution" | _z2k_ow_tiktok_serialize_lines)
    _pool=$(printf '%s\n' "$_resolution" | _z2k_ow_tiktok_candidate_pool)
    _Z2K_TIKTOK_CANDIDATE_POOL_STATE=$(printf '%s\n' "$_pool" | _z2k_ow_tiktok_serialize_lines)
    _Z2K_TIKTOK_RESOLVER_SOURCES_STATE=$(_z2k_ow_tiktok_resolvers | _z2k_ow_tiktok_serialize_lines)
    _discovered="$_now"
    while IFS='|' read -r _ip _domains _modes _resolvers _sources _cnames _geo _provenance _dns _curated _verified \
        _candidate_ch_nodes _candidate_ch_countries _candidate_ch_asns _candidate_ch_node_names \
        _candidate_ch_country_names _candidate_ch_asn_names _candidate_ch_cities _candidate_ch_ttls; do
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
            case "$_candidate_ch_nodes" in ''|*[!0-9]*) _candidate_ch_nodes=0 ;; esac
            if [ -z "$_best_ms" ] || [ "$_ms" -lt "$_best_ms" ] \
                || { [ "$_ms" -eq "$_best_ms" ] 2>/dev/null && [ "$_candidate_ch_nodes" -gt "$_best_ch_nodes" ]; }; then
                _best_row="$_row"; _best_ms="$_ms"
                _best_domain="${_domains%%,*}"; _best_domains="$_domains"; _best_mode="${_modes%%,*}"; _best_modes="$_modes"
                _best_provenance="$_provenance"; _best_geo="${_geo%%,*}"
                _best_resolvers="$_resolvers"; _best_sources="$_sources"; _best_cname="$_cnames"
                _best_dns="$_dns"; _best_curated="$_curated"
                _best_ch_nodes="$_candidate_ch_nodes"
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
    if ! _z2k_ow_tiktok_recheck_before_apply auto; then
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
        if ! _z2k_ow_tiktok_set_host "$_current"; then
            _z2k_ow_tiktok_state_write_apply 1 0 dns-apply-error "$_current" "$_current_ms" 0 "$_now" dns-apply-failed
            _z2k_ow_tiktok_apply_lock_release
            return 1
        fi
        _z2k_ow_tiktok_state_write_apply 1 1 healthy "$_current" "$_current_ms" 0 "$_now" "${_reason#*|}" "${_selected_at:-$_now}" "$_discovered" "$_evaluated" \
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
        if ! _z2k_ow_tiktok_set_host "$_best_ip"; then
            _z2k_ow_tiktok_state_write_apply 1 0 dns-apply-error "$_best_ip" "$_best_ms" 0 "$_now" dns-apply-failed
            _z2k_ow_tiktok_apply_lock_release
            return 1
        fi
        _z2k_ow_tiktok_state_write_apply 1 1 healthy "$_best_ip" "$_best_ms" 0 "$_now" "${_current:+consecutive-probe-failures}" "$_now" "$_discovered" "$_evaluated" \
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
        if ! _z2k_ow_tiktok_set_host "$_current"; then
            _z2k_ow_tiktok_state_write_apply 0 0 dns-apply-error "$_current" "$_current_latency" "$_fail" "$_current_verified" dns-apply-failed
            _z2k_ow_tiktok_apply_lock_release
            return 1
        fi
        _z2k_ow_tiktok_state_write_apply 0 1 degraded "$_current" "$_current_latency" "$_fail" "$_current_verified" no-verified-alternative \
            "${_selected_at:-$_current_verified}" "$_discovered" "$_evaluated" \
            "$_sel_domain" "$_sel_mode" \
            "$_sel_provenance" "$_sel_geo" dead
    else
        z2k_ow_tiktok_clear || { _z2k_ow_tiktok_apply_lock_release; return 1; }
        _z2k_ow_tiktok_state_write_apply 0 0 degraded "" "" "$_fail" 0 no-verified-cdn-fail-open 0 "$_discovered" "$_evaluated" "" "" "" "" dead
    fi
    _z2k_ow_tiktok_apply_lock_release
    return 0
}

z2k_ow_tiktok_status() {
    local _state _ip _lat _verified _fail _enabled _mode _candidate_verified _dns_override_applied
    _state=$(_z2k_ow_tiktok_state_get state); [ -n "$_state" ] || _state=unknown
    _ip=$(_z2k_ow_tiktok_state_get selected_ip)
    _lat=$(_z2k_ow_tiktok_state_get latency_ms)
    _verified=$(_z2k_ow_tiktok_state_get last_verified_epoch)
    _fail=$(_z2k_ow_tiktok_state_get failure_count); [ -n "$_fail" ] || _fail=0
    _candidate_verified=$(_z2k_ow_tiktok_state_get candidate_verified); [ -n "$_candidate_verified" ] || _candidate_verified=0
    _dns_override_applied=$(_z2k_ow_tiktok_state_get dns_override_applied); [ -n "$_dns_override_applied" ] || _dns_override_applied=0
    z2k_ow_tiktok_enabled && _enabled=enabled || _enabled=disabled
    _mode=$(z2k_ow_tiktok_mode)
    printf 'enabled=%s\n' "$_enabled"
    printf 'mode=%s\n' "$_mode"
    printf 'manual_ip=%s\n' "$(_z2k_ow_tiktok_manual_ip)"
    printf 'state=%s\n' "$_state"
    printf 'host=%s\n' "$Z2K_TIKTOK_HOST"
    printf 'managed_targets=%s,%s\n' "$Z2K_TIKTOK_HOST" "$Z2K_TIKTOK_EU_HOST"
    printf 'checkhost_cache_epoch=%s\n' "$(_z2k_ow_tiktok_state_get checkhost_cache_epoch)"
    printf 'selected_ip=%s\n' "$_ip"
    printf 'latency_ms=%s\n' "$_lat"
    printf 'last_verified_epoch=%s\n' "$_verified"
    printf 'candidates_checked_epoch=%s\n' "$(_z2k_ow_tiktok_state_get candidates_checked_epoch)"
    printf 'selected_at_epoch=%s\n' "$(_z2k_ow_tiktok_state_get selected_at_epoch)"
    printf 'failure_count=%s\n' "$_fail"
    printf 'candidate_verified=%s\n' "$_candidate_verified"
    printf 'dns_override_applied=%s\n' "$_dns_override_applied"
    printf 'candidate_pool=%s\n' "$(_z2k_ow_tiktok_state_get candidate_pool)"
    printf 'probe_observations=%s\n' "$(_z2k_ow_tiktok_state_get probe_observations)"
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
    _z2k_ow_tiktok_state_write_apply 0 0 off "" "" 0 0 disabled 0 0 "$(date +%s 2>/dev/null || echo 0)" "" "" "" "" off
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
    if _z2k_ow_tiktok_registered || { [ -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _z2k_ow_tiktok_owned; }; then
        if ! _z2k_ow_tiktok_owned || ! _z2k_ow_tiktok_hosts_content_owned; then
            echo "z2k-openwrt: preserving externally modified TikTok addnhosts data" >&2
            return 1
        fi
    fi
    z2k_ow_tiktok_clear || return 1
    rm -f "$Z2K_TIKTOK_UCI_MARKER" "$Z2K_TIKTOK_CONTENT_MARKER" \
        "$Z2K_TIKTOK_ADDRESS_MARKER" "$Z2K_TIKTOK_STATE_FILE"
}

z2k_ow_tiktok_uninstall() {
    _z2k_ow_tiktok_apply_lock_acquire || return 1
    _z2k_ow_tiktok_uninstall_locked
    local _rc=$?
    _z2k_ow_tiktok_apply_lock_release
    return "$_rc"
}
