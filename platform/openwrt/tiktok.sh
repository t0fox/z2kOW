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
Z2K_TIKTOK_STATE_FILE="${Z2K_TIKTOK_STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/tiktok-cdn.state}"
Z2K_TIKTOK_DISABLED_FILE="${Z2K_TIKTOK_DISABLED_FILE:-${Z2K_STATE:-/etc/z2k/state}/.tiktok-cdn-disabled}"
Z2K_TIKTOK_UCI_SECTION="${Z2K_TIKTOK_UCI_SECTION:-dhcp.@dnsmasq[0]}"
Z2K_TIKTOK_UCI_BIN="${Z2K_TIKTOK_UCI_BIN:-uci}"
Z2K_TIKTOK_DNSMASQ_INIT="${Z2K_TIKTOK_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
Z2K_TIKTOK_CURL_BIN="${Z2K_TIKTOK_CURL_BIN:-curl}"
Z2K_TIKTOK_NSLOOKUP_BIN="${Z2K_TIKTOK_NSLOOKUP_BIN:-nslookup}"
Z2K_TIKTOK_MAX_PROBES="${Z2K_TIKTOK_MAX_PROBES:-12}"
Z2K_TIKTOK_SUCCESS_TARGET="${Z2K_TIKTOK_SUCCESS_TARGET:-4}"
Z2K_TIKTOK_LEASE_SECONDS="${Z2K_TIKTOK_LEASE_SECONDS:-3600}"
Z2K_TIKTOK_RESOLVER_LIMIT="${Z2K_TIKTOK_RESOLVER_LIMIT:-6}"
Z2K_TIKTOK_DNS_TIMEOUT="${Z2K_TIKTOK_DNS_TIMEOUT:-3}"
Z2K_TIKTOK_FAIL_THRESHOLD="${Z2K_TIKTOK_FAIL_THRESHOLD:-2}"

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
    local _state="$1" _ip="${2:-}" _lat="${3:-}" _fail="${4:-0}" _verified="${5:-0}" _reason="${6:-}"
    local _tmp="${Z2K_TIKTOK_STATE_FILE}.new.$$"
    mkdir -p "$(dirname "$Z2K_TIKTOK_STATE_FILE")" 2>/dev/null || return 1
    {
        printf 'state=%s\n' "$_state"
        printf 'selected_ip=%s\n' "$_ip"
        printf 'latency_ms=%s\n' "$_lat"
        printf 'failure_count=%s\n' "$_fail"
        printf 'last_verified_epoch=%s\n' "$_verified"
        printf 'reason=%s\n' "$_reason"
    } > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_STATE_FILE"
}

z2k_ow_tiktok_enabled() {
    [ ! -e "$Z2K_TIKTOK_DISABLED_FILE" ]
}

_z2k_ow_tiktok_registered() {
    "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | grep -F ".addnhosts=$Z2K_TIKTOK_HOSTS_FILE" >/dev/null 2>&1
}

_z2k_ow_tiktok_owned() {
    [ -r "$Z2K_TIKTOK_UCI_MARKER" ] \
        && [ "$(cat "$Z2K_TIKTOK_UCI_MARKER" 2>/dev/null)" = "$Z2K_TIKTOK_HOSTS_FILE" ]
}

_z2k_ow_tiktok_reload_dnsmasq() {
    [ -x "$Z2K_TIKTOK_DNSMASQ_INIT" ] || return 1
    "$Z2K_TIKTOK_DNSMASQ_INIT" reload >/dev/null 2>&1
}

# A future upstream implementation or a user-defined DNS override wins.  We
# never replace/remove DNS state we do not own.
z2k_ow_tiktok_external_override() {
    local _line _path
    command -v "$Z2K_TIKTOK_UCI_BIN" >/dev/null 2>&1 || return 1
    if "$Z2K_TIKTOK_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | grep -E '\.(address|hostrecord|cname)=' \
        | grep -F "$Z2K_TIKTOK_HOST" >/dev/null 2>&1; then
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
    [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] || : > "$Z2K_TIKTOK_HOSTS_FILE" || return 1
    if _z2k_ow_tiktok_registered; then
        _z2k_ow_tiktok_owned || {
            echo "z2k-openwrt: TikTok DNS include already exists without z2kOW ownership" >&2
            return 1
        }
        return 0
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
    z2k_ow_tiktok_prepare || return 1
    printf '%s %s\n' "$_ip" "$Z2K_TIKTOK_HOST" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    if [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] && cmp -s "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE"; then
        rm -f "$_tmp"
        return 0
    fi
    mv -f "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    _z2k_ow_tiktok_reload_dnsmasq
}

z2k_ow_tiktok_clear() {
    local _tmp="${Z2K_TIKTOK_HOSTS_FILE}.new.$$"
    [ -f "$Z2K_TIKTOK_HOSTS_FILE" ] || return 0
    [ -s "$Z2K_TIKTOK_HOSTS_FILE" ] || return 0
    : > "$_tmp" || return 1
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_TIKTOK_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    _z2k_ow_tiktok_reload_dnsmasq
}

_z2k_ow_tiktok_resolvers() {
    {
        for _f in /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf; do
            [ -r "$_f" ] || continue
            awk '$1 == "nameserver" { print $2 }' "$_f" 2>/dev/null
        done
        printf '%s\n' 1.1.1.1 8.8.8.8 9.9.9.9 94.140.14.14 208.67.222.222
    } | awk -v limit="$Z2K_TIKTOK_RESOLVER_LIMIT" '
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !seen[$0]++ { print; n++ }
        n >= limit { exit }
    '
}

_z2k_ow_tiktok_fallback_candidates() {
    cat <<'EOF_CANDIDATES'
212.188.77.134
212.188.77.135
212.188.77.140
212.188.77.136
185.11.78.47
143.244.42.18
143.244.42.29
143.244.42.21
143.244.42.36
143.244.42.15
143.244.42.26
143.244.42.17
143.244.42.23
37.19.202.33
37.19.202.53
37.19.202.47
37.19.202.54
37.19.202.46
37.19.202.50
37.19.202.51
37.19.202.49
37.19.202.52
37.19.202.48
37.19.203.36
169.150.237.34
87.245.200.8
87.245.200.66
87.245.200.10
87.245.200.35
87.245.200.64
87.245.200.34
87.245.200.56
87.245.200.32
87.245.200.57
87.245.200.9
87.245.200.24
EOF_CANDIDATES
}

_z2k_ow_tiktok_dns_query() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$Z2K_TIKTOK_DNS_TIMEOUT" "$Z2K_TIKTOK_NSLOOKUP_BIN" "$1" "$2" 2>/dev/null
    else
        "$Z2K_TIKTOK_NSLOOKUP_BIN" "$1" "$2" 2>/dev/null
    fi
}

_z2k_ow_tiktok_discover_candidates() {
    local _resolver _domain
    command -v "$Z2K_TIKTOK_NSLOOKUP_BIN" >/dev/null 2>&1 || {
        _z2k_ow_tiktok_fallback_candidates
        return 0
    }
    {
        for _resolver in $(_z2k_ow_tiktok_resolvers); do
            for _domain in \
                v77.tiktokcdn.com \
                v16-cla.tiktokcdn.com \
                v16-ies-music.tiktokcdn.com \
                sf16-music.tiktokcdn-eu.com; do
                _z2k_ow_tiktok_dns_query "$_domain" "$_resolver" \
                    | awk -v r="$_resolver" '
                        {
                            for (i=1; i<=NF; i++) {
                                token=$i
                                gsub(/^[^0-9]*/, "", token)
                                gsub(/[^0-9.].*$/, "", token)
                                if (token ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && token != r) print token
                            }
                        }
                    '
            done
        done
        _z2k_ow_tiktok_fallback_candidates
    } | awk '!seen[$0]++'
}

# stdout: latency in milliseconds. curl validates the normal certificate for
# v77.tiktokcdn.com because --insecure is deliberately never used.
_z2k_ow_tiktok_probe() {
    local _ip="$1" _metrics _tls _total _ms
    _z2k_ow_tiktok_valid_ipv4 "$_ip" || return 1
    command -v "$Z2K_TIKTOK_CURL_BIN" >/dev/null 2>&1 || return 1
    _metrics=$("$Z2K_TIKTOK_CURL_BIN" --ipv4 --silent --show-error \
        --output /dev/null --connect-timeout 4 --max-time 7 \
        --write-out '%{time_appconnect} %{time_total}' \
        --resolve "$Z2K_TIKTOK_HOST:443:$_ip" "https://$Z2K_TIKTOK_HOST/" 2>/dev/null) || return 1
    set -- $_metrics
    _tls="${1:-0}"; _total="${2:-0}"
    awk -v v="$_tls" 'BEGIN { exit !(v+0 > 0) }' || return 1
    _ms=$(awk -v v="$_total" 'BEGIN { printf "%d", (v+0)*1000 }') || return 1
    case "$_ms" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_ms"
}

z2k_ow_tiktok_check() {
    local _now _current _current_latency _current_verified _fail _current_ms="" _current_ok=0
    local _candidates _ip _ms _best_ip="" _best_ms="" _probes=0 _success=0 _stable_ms _reason
    _now=$(date +%s 2>/dev/null) || _now=0
    if ! z2k_ow_tiktok_enabled; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _z2k_ow_tiktok_state_write off "" "" 0 0 disabled
        return 0
    fi
    if z2k_ow_tiktok_external_override; then
        z2k_ow_tiktok_clear >/dev/null 2>&1 || true
        _z2k_ow_tiktok_state_write external "" "" 0 0 external-dns-owner
        return 0
    fi
    z2k_ow_tiktok_prepare || {
        _z2k_ow_tiktok_state_write degraded "" "" 0 0 dnsmasq-prepare-failed
        return 1
    }
    _current=$(_z2k_ow_tiktok_state_get selected_ip)
    _current_latency=$(_z2k_ow_tiktok_state_get latency_ms)
    _current_verified=$(_z2k_ow_tiktok_state_get last_verified_epoch)
    _fail=$(_z2k_ow_tiktok_state_get failure_count)
    case "$_fail" in ''|*[!0-9]*) _fail=0 ;; esac
    if _z2k_ow_tiktok_valid_ipv4 "$_current"; then
        if _current_ms=$(_z2k_ow_tiktok_probe "$_current"); then
            _current_ok=1
            _fail=0
        else
            _fail=$((_fail + 1))
        fi
    fi

    _candidates=$(_z2k_ow_tiktok_discover_candidates)
    for _ip in $_candidates; do
        _z2k_ow_tiktok_valid_ipv4 "$_ip" || continue
        [ "$_ip" != "$_current" ] || continue
        [ "$_probes" -lt "$Z2K_TIKTOK_MAX_PROBES" ] || break
        _probes=$((_probes + 1))
        if _ms=$(_z2k_ow_tiktok_probe "$_ip"); then
            _success=$((_success + 1))
            if [ -z "$_best_ms" ] || [ "$_ms" -lt "$_best_ms" ]; then
                _best_ip="$_ip"; _best_ms="$_ms"
            fi
            [ "$_success" -lt "$Z2K_TIKTOK_SUCCESS_TARGET" ] || break
        fi
    done

    if [ -n "$_best_ip" ]; then
        _stable_ms=$(_z2k_ow_tiktok_probe "$_best_ip") || _best_ip=""
        [ -z "$_best_ip" ] || _best_ms="$_stable_ms"
    fi

    if [ "$_current_ok" = 1 ]; then
        # Same hysteresis as zapret2-manager: switch only when the alternative
        # is <=75% of current latency and at least 40 ms faster.
        if [ -n "$_best_ip" ] && awk -v c="$_current_ms" -v a="$_best_ms" \
            'BEGIN { exit !((a <= c*0.75) && (c-a >= 40)) }'; then
            _reason=better-verified-cdn
            _z2k_ow_tiktok_set_host "$_best_ip" || return 1
            _z2k_ow_tiktok_state_write healthy "$_best_ip" "$_best_ms" 0 "$_now" "$_reason"
        else
            _reason=current-verified
            _z2k_ow_tiktok_set_host "$_current" || return 1
            _z2k_ow_tiktok_state_write healthy "$_current" "$_current_ms" 0 "$_now" "$_reason"
        fi
        return 0
    fi

    if [ -n "$_best_ip" ]; then
        _z2k_ow_tiktok_set_host "$_best_ip" || return 1
        _z2k_ow_tiktok_state_write healthy "$_best_ip" "$_best_ms" 0 "$_now" verified-failover
        return 0
    fi

    # Preserve the last known-good address through one transient failure, then
    # fail open to normal DNS rather than pinning a repeatedly dead CDN forever.
    if _z2k_ow_tiktok_valid_ipv4 "$_current" && [ "$_fail" -lt "$Z2K_TIKTOK_FAIL_THRESHOLD" ]; then
        _z2k_ow_tiktok_set_host "$_current" || return 1
        _z2k_ow_tiktok_state_write degraded "$_current" "$_current_latency" "$_fail" "$_current_verified" transient-probe-failure
    else
        z2k_ow_tiktok_clear || return 1
        _z2k_ow_tiktok_state_write degraded "" "" "$_fail" 0 no-verified-cdn-fail-open
    fi
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
}

z2k_ow_tiktok_enable() {
    rm -f "$Z2K_TIKTOK_DISABLED_FILE" || return 1
    z2k_ow_tiktok_check
}

z2k_ow_tiktok_disable() {
    mkdir -p "$(dirname "$Z2K_TIKTOK_DISABLED_FILE")" 2>/dev/null || return 1
    : > "$Z2K_TIKTOK_DISABLED_FILE" || return 1
    z2k_ow_tiktok_clear || return 1
    _z2k_ow_tiktok_state_write off "" "" 0 0 disabled
}

z2k_ow_tiktok_stop() {
    z2k_ow_tiktok_clear
}

z2k_ow_tiktok_uninstall() {
    local _owned=""
    if [ -r "$Z2K_TIKTOK_UCI_MARKER" ]; then
        _owned=$(cat "$Z2K_TIKTOK_UCI_MARKER" 2>/dev/null)
        if [ "$_owned" = "$Z2K_TIKTOK_HOSTS_FILE" ] && _z2k_ow_tiktok_registered; then
            "$Z2K_TIKTOK_UCI_BIN" del_list \
                "$Z2K_TIKTOK_UCI_SECTION.addnhosts=$Z2K_TIKTOK_HOSTS_FILE" || return 1
            "$Z2K_TIKTOK_UCI_BIN" commit dhcp || return 1
            _z2k_ow_tiktok_reload_dnsmasq || return 1
        fi
    fi
    rm -f "$Z2K_TIKTOK_HOSTS_FILE" "$Z2K_TIKTOK_UCI_MARKER" \
        "$Z2K_TIKTOK_STATE_FILE" "$Z2K_TIKTOK_DISABLED_FILE"
}
