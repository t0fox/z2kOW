#!/bin/sh
# Optional provider-neutral DoH integration through OpenWrt's https-dns-proxy package.
# This adapter owns one named resolver section and the exact dnsmasq fields it
# changes; package, init, UCI, and path commands remain platform-local here.

Z2K_DOH_PACKAGE="https-dns-proxy"
Z2K_DOH_SECTION="${Z2K_DOH_SECTION:-z2kow_doh}"
Z2K_DOH_LEGACY_SECTION="z2kow_xbox"
Z2K_DOH_PROVIDER="xbox"
Z2K_DOH_PROVIDER_LABEL="Xbox DNS"
Z2K_DOH_ENDPOINT="https://xbox-dns.ru/dns-query"
Z2K_DOH_BOOTSTRAP="111.88.96.50,111.88.96.51"
Z2K_DOH_LISTEN_ADDR="127.0.0.1"
Z2K_DOH_PORT_BASE="${Z2K_DOH_PORT_BASE:-5053}"
Z2K_DOH_UCI_BIN="${Z2K_DOH_UCI_BIN:-uci}"
Z2K_DOH_APK_BIN="${Z2K_DOH_APK_BIN:-apk}"
Z2K_DOH_DNSMASQ_INIT="${Z2K_DOH_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
Z2K_DOH_PROC_NET_UDP_FILE="${Z2K_DOH_PROC_NET_UDP_FILE:-/proc/net/udp}"
Z2K_DOH_STATE_FILE="${Z2K_DOH_STATE_FILE:-${Z2K_STATE:-/etc/z2k/state}/doh.state}"
Z2K_DOH_PROFILE_FILE="${Z2K_DOH_PROFILE_FILE:-${Z2K_STATE:-/etc/z2k/state}/doh.provider}"
Z2K_DOH_ERROR_FILE="${Z2K_DOH_ERROR_FILE:-${Z2K_STATE:-/etc/z2k/state}/.doh-error}"
Z2K_DOH_CONFIG_OWNED_FILE="${Z2K_DOH_CONFIG_OWNED_FILE:-${Z2K_STATE:-/etc/z2k/state}/.doh-uci-owned}"
Z2K_DOH_PACKAGE_OWNED_FILE="${Z2K_DOH_PACKAGE_OWNED_FILE:-${Z2K_STATE:-/etc/z2k/state}/.doh-package-owned}"
Z2K_DOH_INSTALL_SNAPSHOT="${Z2K_DOH_INSTALL_SNAPSHOT:-${Z2K_STATE:-/etc/z2k/state}/.doh-install-snapshot}"
Z2K_DOH_MAIN_SNAPSHOT="${Z2K_DOH_MAIN_SNAPSHOT:-${Z2K_STATE:-/etc/z2k/state}/.doh-main-snapshot}"
Z2K_DOH_DHCP_SNAPSHOT="${Z2K_DOH_DHCP_SNAPSHOT:-${Z2K_STATE:-/etc/z2k/state}/.doh-dnsmasq-snapshot}"
Z2K_DOH_PROXY_INIT="${Z2K_DOH_PROXY_INIT:-/etc/init.d/https-dns-proxy}"
Z2K_DOH_FAILURE_REASON=""

# Keep installations made by the first DoH release operable. New installs use
# a neutral section name; the old section is selected only when its ownership
# marker proves that it belongs to z2kOW.
if [ "$(cat "$Z2K_DOH_CONFIG_OWNED_FILE" 2>/dev/null)" = "$Z2K_DOH_LEGACY_SECTION" ]; then
    Z2K_DOH_SECTION="$Z2K_DOH_LEGACY_SECTION"
fi

_z2k_ow_doh_progress() {
    command -v job_progress >/dev/null 2>&1 || return 0
    job_progress "DoH: $*"
}

_z2k_ow_doh_uci() { "$Z2K_DOH_UCI_BIN" "$@"; }
_z2k_ow_doh_get() { _z2k_ow_doh_uci -q get "$1" 2>/dev/null; }

_z2k_ow_doh_write_atomic() {
    _doh_file="$1"
    _doh_tmp="${_doh_file}.new.$$"
    mkdir -p "$(dirname "$_doh_file")" 2>/dev/null || return 1
    cat > "$_doh_tmp" || { rm -f "$_doh_tmp"; return 1; }
    chmod 600 "$_doh_tmp" 2>/dev/null || true
    mv -f "$_doh_tmp" "$_doh_file"
}

_z2k_ow_doh_file_value() {
    local _doh_key="$1" _doh_file="$2"
    awk -F= -v k="$_doh_key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$_doh_file" 2>/dev/null
}

_z2k_ow_doh_file_set() {
    _doh_file="$1" _doh_key="$2" _doh_value="$3"
    _doh_tmp="${_doh_file}.new.$$"
    awk -F= -v k="$_doh_key" -v v="$_doh_value" '
        BEGIN { found=0 }
        $1 == k { if (!found) print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$_doh_file" > "$_doh_tmp" || { rm -f "$_doh_tmp"; return 1; }
    chmod 600 "$_doh_tmp" 2>/dev/null || true
    mv -f "$_doh_tmp" "$_doh_file"
}

_z2k_ow_doh_preset() {
    Z2K_DOH_PROVIDER="$1"
    case "$1" in
        xbox)
            Z2K_DOH_PROVIDER_LABEL="Xbox DNS"
            Z2K_DOH_ENDPOINT="https://xbox-dns.ru/dns-query"
            Z2K_DOH_BOOTSTRAP="111.88.96.50,111.88.96.51"
            ;;
        cloudflare)
            Z2K_DOH_PROVIDER_LABEL="Cloudflare"
            Z2K_DOH_ENDPOINT="https://cloudflare-dns.com/dns-query"
            Z2K_DOH_BOOTSTRAP="1.1.1.1,1.0.0.1"
            ;;
        google)
            Z2K_DOH_PROVIDER_LABEL="Google"
            Z2K_DOH_ENDPOINT="https://dns.google/dns-query"
            Z2K_DOH_BOOTSTRAP="8.8.8.8,8.8.4.4"
            ;;
        *) return 1 ;;
    esac
}

_z2k_ow_doh_valid_bootstrap() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | awk -F, '
        function valid_ipv4(value, parts, count, i) {
            count = split(value, parts, ".")
            if (count != 4) return 0
            for (i = 1; i <= 4; i++) {
                if (parts[i] !~ /^[0-9]+$/ || length(parts[i]) > 3) return 0
                if (length(parts[i]) > 1 && substr(parts[i], 1, 1) == "0") return 0
                if (parts[i] + 0 > 255) return 0
            }
            return 1
        }
        NR != 1 || NF < 1 || NF > 8 { valid = 0; next }
        {
            valid = 1
            for (i = 1; i <= NF; i++)
                if (!valid_ipv4($i)) valid = 0
        }
        END { exit !(NR == 1 && valid) }
    '
}

_z2k_ow_doh_valid_custom_endpoint() {
    local _url="$1" _rest _authority _host _port _path _length
    case "$_url" in https://*) ;; *) return 1 ;; esac
    _length=$(printf '%s' "$_url" | wc -c | tr -d ' ')
    case "$_length" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_length" -le 2048 ] || return 1
    _rest=${_url#https://}
    case "$_rest" in */*) _authority=${_rest%%/*}; _path=/${_rest#*/} ;; *) return 1 ;; esac
    [ -n "$_authority" ] && [ -n "$_path" ] || return 1
    case "$_authority" in
        *:*) _host=${_authority%:*}; _port=${_authority##*:}
            case "$_port" in ''|*[!0-9]*) return 1 ;; esac
            [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1
            ;;
        *) _host=$_authority ;;
    esac
    case "$_host" in ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;; esac
    printf '%s' "$_path" | LC_ALL=C grep -Eq '^[A-Za-z0-9._~/?%&=+-]+$' || return 1
    return 0
}

_z2k_ow_doh_profile_load() {
    local _provider
    _provider=$(_z2k_ow_doh_file_value provider "$Z2K_DOH_PROFILE_FILE")
    [ -n "$_provider" ] || _provider=xbox
    case "$_provider" in
        xbox|cloudflare|google) _z2k_ow_doh_preset "$_provider" ;;
        custom)
            Z2K_DOH_PROVIDER=custom
            Z2K_DOH_PROVIDER_LABEL="Свой endpoint"
            Z2K_DOH_ENDPOINT=$(_z2k_ow_doh_file_value endpoint "$Z2K_DOH_PROFILE_FILE")
            Z2K_DOH_BOOTSTRAP=$(_z2k_ow_doh_file_value bootstrap "$Z2K_DOH_PROFILE_FILE")
            _z2k_ow_doh_valid_custom_endpoint "$Z2K_DOH_ENDPOINT" \
                && _z2k_ow_doh_valid_bootstrap "$Z2K_DOH_BOOTSTRAP"
            ;;
        *) return 1 ;;
    esac
}

_z2k_ow_doh_profile_save() {
    local _provider="$1" _endpoint="${2:-}" _bootstrap="${3:-}"
    case "$_provider" in
        xbox|cloudflare|google)
            _z2k_ow_doh_preset "$_provider" || return 1
            printf 'provider=%s\n' "$Z2K_DOH_PROVIDER" \
                | _z2k_ow_doh_write_atomic "$Z2K_DOH_PROFILE_FILE"
            ;;
        custom)
            _z2k_ow_doh_valid_custom_endpoint "$_endpoint" \
                && _z2k_ow_doh_valid_bootstrap "$_bootstrap" || return 1
            Z2K_DOH_PROVIDER=custom
            Z2K_DOH_PROVIDER_LABEL="Свой endpoint"
            Z2K_DOH_ENDPOINT=$_endpoint
            Z2K_DOH_BOOTSTRAP=$_bootstrap
            {
                printf 'provider=custom\nendpoint=%s\nbootstrap=%s\n' \
                    "$Z2K_DOH_ENDPOINT" "$Z2K_DOH_BOOTSTRAP"
            } | _z2k_ow_doh_write_atomic "$Z2K_DOH_PROFILE_FILE"
            ;;
        *) return 1 ;;
    esac
}

_z2k_ow_doh_config_type() { _z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}"; }

_z2k_ow_doh_section_names() {
    _z2k_ow_doh_uci -q show "$Z2K_DOH_PACKAGE" 2>/dev/null | awk -F= '
        $1 ~ /^https-dns-proxy\.[^.=]+$/ {
            name=$1; sub(/^https-dns-proxy\./, "", name)
            value=substr($0, index($0, "=")+1); gsub(/^\047|\047$/, "", value)
            if (name != "config" && value == "https-dns-proxy") print name
        }
    '
}

_z2k_ow_doh_section_inventory() {
    _z2k_ow_doh_section_names | sort -u
}

_z2k_ow_doh_external_resolver_state() {
    local _all
    _all=$(_z2k_ow_doh_uci -q show "$Z2K_DOH_PACKAGE" 2>/dev/null) || return 1
    printf '%s\n' "$_all" | awk -F= -v p="$Z2K_DOH_PACKAGE." -v own="$Z2K_DOH_SECTION" '
        {
            key=$1
            if (index(key, p) != 1) next
            rest=substr(key, length(p) + 1)
            section=rest
            sub(/\..*$/, "", section)
            value=substr($0, index($0, "=") + 1)
            gsub(/^\047|\047$/, "", value)
            line[NR]=$0
            names[NR]=section
            if (section != "config" && section != own && key == p section \
                && value == "https-dns-proxy") resolver[section]=1
        }
        END {
            for (i=1; i<=NR; i++) if (resolver[names[i]]) print line[i]
        }
    ' | LC_ALL=C sort
}

_z2k_ow_doh_package_installed() { "$Z2K_DOH_APK_BIN" info -e "$Z2K_DOH_PACKAGE" >/dev/null 2>&1; }

_z2k_ow_doh_active_port() {
    local _port
    _port=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.listen_port") || return 1
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$_port"
}

_z2k_ow_doh_other_section_uses_port() {
    local _wanted="$1" _section _configured _port _index=0
    for _section in $(_z2k_ow_doh_section_names); do
        _configured=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${_section}.listen_port") || _configured=""
        case "$_configured" in
            ''|*[!0-9]*) _port=$((Z2K_DOH_PORT_BASE + _index)) ;;
            *) _port="$_configured" ;;
        esac
        if [ "$_section" != "$Z2K_DOH_SECTION" ] && [ "$_port" = "$_wanted" ]; then
            return 0
        fi
        _index=$((_index + 1))
    done
    return 1
}

_z2k_ow_doh_choose_port() {
    local _section _current _count=0 _port
    _current=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.listen_port") || _current=""
    case "$_current" in ''|*[!0-9]*) _current="" ;; esac
    if [ -n "$_current" ] && [ "$_current" -ge 1 ] && [ "$_current" -le 65535 ] \
        && ! _z2k_ow_doh_other_section_uses_port "$_current"; then
        printf '%s' "$_current"
        return 0
    fi
    for _section in $(_z2k_ow_doh_section_names); do
        [ "$_section" = "$Z2K_DOH_SECTION" ] || _count=$((_count + 1))
    done
    _port=$((Z2K_DOH_PORT_BASE + _count))
    while [ "$_port" -le 65535 ]; do
        if ! _z2k_ow_doh_other_section_uses_port "$_port"; then
            printf '%s' "$_port"
            return 0
        fi
        _port=$((_port + 1))
    done
    echo "DoH: свободный локальный DNS порт не найден" >&2
    return 1
}

_z2k_ow_doh_proxy_running() {
    local _pidof="${Z2K_DOH_PIDOF_BIN:-pidof}" _p
    _p=$("$_pidof" https-dns-proxy 2>/dev/null) || return 1
    [ -n "$_p" ]
}

_z2k_ow_doh_listener_ready() {
    local _port _port_hex
    _port=$(_z2k_ow_doh_active_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    _port_hex=$(printf '%04X' "$_port" 2>/dev/null) || return 1
    [ -r "$Z2K_DOH_PROC_NET_UDP_FILE" ] || return 1
    awk -v port="$_port_hex" '$2 == "0100007F:" port && $4 == "07" { found=1 } END { exit !found }' \
        "$Z2K_DOH_PROC_NET_UDP_FILE" 2>/dev/null
}

_z2k_ow_doh_dnsmasq_sections() {
    _z2k_ow_doh_uci -q show dhcp 2>/dev/null | awk -F= '
        $1 ~ /^dhcp\.[^.=]+$/ {
            value=substr($0, index($0, "=")+1); gsub(/^\047|\047$/, "", value)
            if (value == "dnsmasq") { name=$1; sub(/^dhcp\./, "", name); print name }
        }
    '
}

_z2k_ow_doh_dnsmasq_state() {
    local _section="$1" _all _key _value
    _all=$(_z2k_ow_doh_uci -q show dhcp 2>/dev/null) || return 1
    printf '%s\n' "$_all" | awk -F= -v p="dhcp.${_section}.server" '
        $1 == p {
            value=substr($0, index($0, "=")+1); gsub(/^\047|\047$/, "", value)
            print "server=" value
        }
    '
    _key="dhcp.${_section}.noresolv"
    if _value=$(_z2k_ow_doh_get "$_key"); then
        printf 'noresolv=1:%s\n' "$_value"
    else
        printf 'noresolv=0:\n'
    fi
}

_z2k_ow_doh_route_active() {
    local _sections _section _all _servers=0 _port
    _port=$(_z2k_ow_doh_active_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    _sections=$(_z2k_ow_doh_dnsmasq_sections)
    [ -n "$_sections" ] || return 1
    _all=$(_z2k_ow_doh_uci -q show dhcp 2>/dev/null) || return 1
    for _section in $_sections; do
        printf '%s\n' "$_all" | grep -qF "dhcp.${_section}.server='/#/${Z2K_DOH_LISTEN_ADDR}#${_port}'" || return 1
        [ "$(_z2k_ow_doh_get "dhcp.${_section}.noresolv")" = 1 ] || return 1
        _servers=$((_servers + 1))
    done
    [ "$_servers" -gt 0 ]
}

_z2k_ow_doh_dnsmasq_running() {
    local _pidof="${Z2K_DOH_PIDOF_BIN:-pidof}" _p
    _p=$("$_pidof" dnsmasq 2>/dev/null) || return 1
    [ -n "$_p" ]
}

_z2k_ow_doh_dns_answer() {
    printf '%s\n' "$1" | awk '
        /Address([[:space:]]+[0-9]+)?:/ {
            a=$NF
            if (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && a != "127.0.0.1") found=1
        }
        END { exit !found }
    '
}

_z2k_ow_doh_listener_dns_check() {
    local _lookup="${Z2K_DOH_NSLOOKUP_BIN:-nslookup}" _port _out
    _port=$(_z2k_ow_doh_active_port) || return 1
    _out=$("$_lookup" "-port=$_port" "${Z2K_DOH_HEALTH_HOST:-example.com}" "$Z2K_DOH_LISTEN_ADDR" 2>/dev/null) || return 1
    _z2k_ow_doh_dns_answer "$_out"
}

_z2k_ow_doh_router_dns_check() {
    local _lookup="${Z2K_DOH_NSLOOKUP_BIN:-nslookup}" _out
    _out=$("$_lookup" "${Z2K_DOH_HEALTH_HOST:-example.com}" 127.0.0.1 2>/dev/null) || return 1
    _z2k_ow_doh_dns_answer "$_out"
}

_z2k_ow_doh_dns_check() {
    _z2k_ow_doh_listener_dns_check && _z2k_ow_doh_router_dns_check
}

_z2k_ow_doh_main_snapshot() {
    [ -s "$Z2K_DOH_MAIN_SNAPSHOT" ] && return 0
    local _type _force_present=0 _force_value="" _update_present=0 _update_value="" _created=0
    _type=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config") || _type=""
    [ -n "$_type" ] || _created=1
    if _z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.force_dns" >/dev/null 2>&1; then
        _force_present=1; _force_value=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.force_dns")
    fi
    if _z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.dnsmasq_config_update" >/dev/null 2>&1; then
        _update_present=1; _update_value=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.dnsmasq_config_update")
    fi
    [ -z "$_type" ] || [ "$_type" = main ] || {
        echo "DoH: https-dns-proxy.config уже занят секцией другого типа" >&2
        return 1
    }
    {
        printf 'main_created=%s\n' "$_created"
        printf 'force_before_present=%s\nforce_before_value=%s\nforce_expected=0\n' "$_force_present" "$_force_value"
        printf 'update_before_present=%s\nupdate_before_value=%s\nupdate_expected=-\n' "$_update_present" "$_update_value"
    } | _z2k_ow_doh_write_atomic "$Z2K_DOH_MAIN_SNAPSHOT"
}

_z2k_ow_doh_set_main() {
    local _option="$1" _value="$2" _expected_key
    if [ "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config")" != main ]; then
        _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config=main" || return 1
    fi
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config.${_option}=${_value}" || return 1
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
    case "$_option" in force_dns) _expected_key=force_expected ;; dnsmasq_config_update) _expected_key=update_expected ;; *) return 1 ;; esac
    _z2k_ow_doh_file_set "$Z2K_DOH_MAIN_SNAPSHOT" "$_expected_key" "$_value"
}

_z2k_ow_doh_restore_main() {
    [ -s "$Z2K_DOH_MAIN_SNAPSHOT" ] || return 0
    local _rc=0 _option _present _before _expected _current _created
    for _option in force_dns dnsmasq_config_update; do
        case "$_option" in
            force_dns) _present=force_before_present; _before=force_before_value; _expected=force_expected ;;
            *) _present=update_before_present; _before=update_before_value; _expected=update_expected ;;
        esac
        _current=$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.${_option}") || _current=""
        if [ "$_current" = "$(_z2k_ow_doh_file_value "$_expected" "$Z2K_DOH_MAIN_SNAPSHOT")" ]; then
            if [ "$(_z2k_ow_doh_file_value "$_present" "$Z2K_DOH_MAIN_SNAPSHOT")" = 1 ]; then
                _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config.${_option}=$(_z2k_ow_doh_file_value "$_before" "$Z2K_DOH_MAIN_SNAPSHOT")" || _rc=1
            else
                _z2k_ow_doh_uci delete "${Z2K_DOH_PACKAGE}.config.${_option}" || _rc=1
            fi
        fi
    done
    _created=$(_z2k_ow_doh_file_value main_created "$Z2K_DOH_MAIN_SNAPSHOT")
    if [ "$_created" = 1 ] && [ -z "$(_z2k_ow_doh_uci -q show "${Z2K_DOH_PACKAGE}.config" 2>/dev/null | grep -v "^${Z2K_DOH_PACKAGE}\.config='")" ]; then
        _z2k_ow_doh_uci delete "${Z2K_DOH_PACKAGE}.config" || _rc=1
    fi
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || _rc=1
    [ "$_rc" = 0 ] && rm -f "$Z2K_DOH_MAIN_SNAPSHOT"
    return "$_rc"
}

_z2k_ow_doh_dnsmasq_snapshot() {
    [ -s "$Z2K_DOH_DHCP_SNAPSHOT" ] && return 0
    local _section _sections _state _state_dump _value _line _port
    _port=$(_z2k_ow_doh_active_port) || return 1
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1
    _sections=$(_z2k_ow_doh_dnsmasq_sections)
    [ -n "$_sections" ] || { echo "DoH: dnsmasq section is missing" >&2; return 1; }
    _state="${Z2K_DOH_DHCP_SNAPSHOT}.new.$$"
    : > "$_state" || return 1
    for _section in $_sections; do
        _state_dump=$(_z2k_ow_doh_dnsmasq_state "$_section") || { rm -f "$_state"; return 1; }
        while IFS= read -r _line; do
            case "$_line" in
                noresolv=*) printf 'noresolv|%s|%s\n' "$_section" "${_line#noresolv=}" >> "$_state" ;;
                server=*)
                    _value=${_line#server=}
                    case "$_value" in
                        /#/*|/./*) echo "DoH: пользовательская DNS-маршрутизация уже использует catch-all; безопасное сосуществование невозможно" >&2; rm -f "$_state"; return 1 ;;
                        */*) ;;
                        *) printf 'server|%s|%s\n' "$_section" "$_value" >> "$_state" ;;
                    esac
                    ;;
            esac
        done <<EOF_DOH_STATE
$_state_dump
EOF_DOH_STATE
    done
    printf 'route_port||%s\n' "$_port" >> "$_state"
    chmod 600 "$_state" 2>/dev/null || true
    mv -f "$_state" "$Z2K_DOH_DHCP_SNAPSHOT"
}

_z2k_ow_doh_dnsmasq_apply() {
    local _section _line _kind _server _rc=0 _port
    _port=$(_z2k_ow_doh_active_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    _z2k_ow_doh_dnsmasq_snapshot || return 1
    while IFS='|' read -r _kind _section _server; do
        case "$_kind" in
            server) _z2k_ow_doh_uci del_list "dhcp.${_section}.server=${_server}" || _rc=1 ;;
            noresolv) _z2k_ow_doh_uci set "dhcp.${_section}.noresolv=1" || _rc=1 ;;
        esac
    done < "$Z2K_DOH_DHCP_SNAPSHOT"
    for _section in $(_z2k_ow_doh_dnsmasq_sections); do
        _z2k_ow_doh_uci add_list "dhcp.${_section}.server=/#/${Z2K_DOH_LISTEN_ADDR}#${_port}" || _rc=1
    done
    _z2k_ow_doh_uci commit dhcp || _rc=1
    [ "$_rc" = 0 ]
}

_z2k_ow_doh_dnsmasq_restore() {
    [ -s "$Z2K_DOH_DHCP_SNAPSHOT" ] || return 0
    local _kind _section _value _current _rc=0 _port
    _port=$(_z2k_ow_doh_file_value route_port "$Z2K_DOH_DHCP_SNAPSHOT")
    [ -n "$_port" ] || _port=$(_z2k_ow_doh_active_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    for _section in $(_z2k_ow_doh_dnsmasq_sections); do
        _z2k_ow_doh_uci del_list "dhcp.${_section}.server=/#/${Z2K_DOH_LISTEN_ADDR}#${_port}" || _rc=1
    done
    while IFS='|' read -r _kind _section _value; do
        case "$_kind" in
            server)
                _z2k_ow_doh_uci add_list "dhcp.${_section}.server=${_value}" || _rc=1
                ;;
            noresolv)
                _current=$(_z2k_ow_doh_get "dhcp.${_section}.noresolv") || _current=""
                if [ "$_current" = 1 ]; then
                    case "$_value" in
                        0:) _z2k_ow_doh_uci delete "dhcp.${_section}.noresolv" || _rc=1 ;;
                        1:*) _z2k_ow_doh_uci set "dhcp.${_section}.noresolv=${_value#1:}" || _rc=1 ;;
                    esac
                fi
                ;;
            route_port) ;;
        esac
    done < "$Z2K_DOH_DHCP_SNAPSHOT"
    _z2k_ow_doh_uci commit dhcp || _rc=1
    if [ "$_rc" = 0 ]; then
        "$Z2K_DOH_DNSMASQ_INIT" restart >/dev/null 2>&1 || _rc=1
    fi
    [ "$_rc" = 0 ] && rm -f "$Z2K_DOH_DHCP_SNAPSHOT"
    return "$_rc"
}

_z2k_ow_doh_dnsmasq_verify() {
    _z2k_ow_doh_route_active && _z2k_ow_doh_dnsmasq_running \
        && _z2k_ow_doh_listener_dns_check && _z2k_ow_doh_router_dns_check
}

_z2k_ow_doh_set_enabled_state() {
    local _enabled _at
    _enabled="$1"
    _at=$(date +%s 2>/dev/null || echo 0)
    _z2k_ow_doh_profile_load || return 1
    printf 'enabled=%s\nchanged_at=%s\nprovider=%s\n' "$_enabled" "$_at" "$Z2K_DOH_PROVIDER" \
        | _z2k_ow_doh_write_atomic "$Z2K_DOH_STATE_FILE"
}

_z2k_ow_doh_enabled() { [ "$(_z2k_ow_doh_file_value enabled "$Z2K_DOH_STATE_FILE")" = 1 ]; }

_z2k_ow_doh_owned_config_valid() {
    [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] || return 1
    _z2k_ow_doh_profile_load || return 1
    [ "$(_z2k_ow_doh_config_type)" = https-dns-proxy ] || return 1
    [ "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.resolver_url")" = "$Z2K_DOH_ENDPOINT" ] || return 1
    [ "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.bootstrap_dns")" = "$Z2K_DOH_BOOTSTRAP" ] || return 1
    [ "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.listen_addr")" = "$Z2K_DOH_LISTEN_ADDR" ] || return 1
    local _port
    _port=$(_z2k_ow_doh_active_port)
    case "$_port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ]
}

_z2k_ow_doh_capture_install_state() {
    local _enabled=0 _running=0 _pidof="${Z2K_DOH_PIDOF_BIN:-pidof}" _resolver_state
    "$Z2K_DOH_PROXY_INIT" enabled >/dev/null 2>&1 && _enabled=1
    "$_pidof" https-dns-proxy >/dev/null 2>&1 && _running=1
    _resolver_state=$(_z2k_ow_doh_external_resolver_state) || return 1
    {
        printf 'enabled_before=%s\nrunning_before=%s\n' "$_enabled" "$_running"
        printf 'baseline_resolver_state<<EOF\n%s\nEOF\n' "$_resolver_state"
    } | _z2k_ow_doh_write_atomic "$Z2K_DOH_INSTALL_SNAPSHOT"
}

_z2k_ow_doh_capture_runtime_service_state() {
    local _enabled=0 _running=0 _pidof="${Z2K_DOH_PIDOF_BIN:-pidof}"
    [ -s "$Z2K_DOH_INSTALL_SNAPSHOT" ] || return 1
    "$Z2K_DOH_PROXY_INIT" enabled >/dev/null 2>&1 && _enabled=1
    "$_pidof" https-dns-proxy >/dev/null 2>&1 && _running=1
    _z2k_ow_doh_file_set "$Z2K_DOH_INSTALL_SNAPSHOT" enabled_before "$_enabled" || return 1
    _z2k_ow_doh_file_set "$Z2K_DOH_INSTALL_SNAPSHOT" running_before "$_running"
}

_z2k_ow_doh_remove_owned_section() {
    local _type
    _type=$(_z2k_ow_doh_config_type) || _type=""
    [ -n "$_type" ] || return 0
    [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] && [ "$_type" = https-dns-proxy ] || {
        echo "DoH: refusing to remove a resolver section that is not owned by z2kOW" >&2
        return 1
    }
    _z2k_ow_doh_owned_config_valid || return 1
    _z2k_ow_doh_uci delete "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}" || return 1
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE"
}

_z2k_ow_doh_has_new_external_sections() {
    [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] || return 1
    local _baseline _current
    if grep -q '^baseline_resolver_state<<EOF$' "$Z2K_DOH_INSTALL_SNAPSHOT" 2>/dev/null; then
        _baseline=$(sed -n '/^baseline_resolver_state<<EOF$/,/^EOF$/p' \
            "$Z2K_DOH_INSTALL_SNAPSHOT" 2>/dev/null | sed '1d;$d')
        _current=$(_z2k_ow_doh_external_resolver_state) || return 0
        [ "$_baseline" = "$_current" ] && return 1
        return 0
    fi
    # Older snapshots kept names only. With no value baseline, retain the
    # package if any non-z2kOW resolver section exists.
    local _section
    for _section in $(_z2k_ow_doh_section_inventory); do
        [ "$_section" = "$Z2K_DOH_SECTION" ] && continue
        return 0
    done
    return 1
}

_z2k_ow_doh_should_preserve_package() {
    [ ! -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && return 0
    _z2k_ow_doh_has_new_external_sections
}

_z2k_ow_doh_restore_install_service_state() {
    local _enabled _running
    _enabled=$(_z2k_ow_doh_file_value enabled_before "$Z2K_DOH_INSTALL_SNAPSHOT")
    _running=$(_z2k_ow_doh_file_value running_before "$Z2K_DOH_INSTALL_SNAPSHOT")
    if [ "$_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || return 1
    else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || return 1; fi
    if [ "$_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || return 1
    elif _z2k_ow_doh_proxy_running; then "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || return 1
    fi
    return 0
}

_z2k_ow_doh_prepare_config() {
    local _type _port
    Z2K_DOH_FAILURE_REASON=""
    _z2k_ow_doh_profile_load || return 1
    _type=$(_z2k_ow_doh_config_type) || _type=""
    if [ -n "$_type" ] && [ ! -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        Z2K_DOH_FAILURE_REASON=resolver-section-not-owned
        echo "DoH: секция ${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION} уже существует и не принадлежит z2kOW" >&2
        return 1
    fi
    _z2k_ow_doh_main_snapshot || return 1
    _port=$(_z2k_ow_doh_choose_port) || return 1
    printf '%s\n' "$Z2K_DOH_SECTION" > "$Z2K_DOH_CONFIG_OWNED_FILE" || return 1
    chmod 600 "$Z2K_DOH_CONFIG_OWNED_FILE" 2>/dev/null || true
    if [ -z "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config")" ]; then
        _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config=main" || return 1
    fi
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}=https-dns-proxy" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.resolver_url=${Z2K_DOH_ENDPOINT}" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.bootstrap_dns=${Z2K_DOH_BOOTSTRAP}" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.listen_addr=${Z2K_DOH_LISTEN_ADDR}" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.listen_port=${_port}" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config.force_dns=0" || return 1
    _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.config.dnsmasq_config_update=-" || return 1
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
    _z2k_ow_doh_file_set "$Z2K_DOH_MAIN_SNAPSHOT" force_expected 0 || return 1
    _z2k_ow_doh_file_set "$Z2K_DOH_MAIN_SNAPSHOT" update_expected - || return 1
    return 0
}

z2k_ow_doh_status() {
    local _state=not-installed _reason= _force=0 _enabled=0 _package=0 _installed=0 _owner=external
    if ! _z2k_ow_doh_profile_load; then
        _reason=provider-config-invalid
    fi
    _z2k_ow_doh_package_installed && _package=1
    [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && _owner=z2kow
    _z2k_ow_doh_enabled && _enabled=1
    if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] && [ "$_package" = 1 ]; then
        _installed=1
    fi
    if [ ! -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        if [ -n "$_reason" ]; then
            _state=error
        elif [ -s "$Z2K_DOH_ERROR_FILE" ]; then
            _state=error; _reason=$(_z2k_ow_doh_file_value reason "$Z2K_DOH_ERROR_FILE")
        elif [ "$_package" = 1 ] && [ "$(_z2k_ow_doh_config_type)" = https-dns-proxy ]; then
            _state=error; _reason=resolver-section-not-owned
        fi
    elif [ "$_package" != 1 ]; then
        _state=error; _reason=package-missing
    elif [ -z "$_reason" ] && [ "$_enabled" != 1 ] && _z2k_ow_doh_should_preserve_package \
        && [ -z "$(_z2k_ow_doh_config_type)" ]; then
        _installed=1
        _state=installed-disabled
    elif ! _z2k_ow_doh_owned_config_valid; then
        _state=error; _reason=resolver-config-changed
    elif [ "$_enabled" != 1 ]; then
        _installed=1
        _state=installed-disabled
        [ -s "$Z2K_DOH_ERROR_FILE" ] \
            && _reason=$(_z2k_ow_doh_file_value reason "$Z2K_DOH_ERROR_FILE")
    elif ! _z2k_ow_doh_proxy_running; then
        _installed=1
        _state=error; _reason=proxy-not-running
    elif _z2k_ow_doh_other_section_uses_port "$(_z2k_ow_doh_active_port)"; then
        _installed=1
        _state=error; _reason=listener-conflict
    elif ! _z2k_ow_doh_listener_ready; then
        _installed=1
        _state=starting; _reason=listener-not-ready
    elif ! _z2k_ow_doh_route_active; then
        _installed=1
        _state=degraded; _reason=dnsmasq-not-routed
    elif ! _z2k_ow_doh_dnsmasq_running; then
        _installed=1
        _state=degraded; _reason=dnsmasq-not-running
    elif ! _z2k_ow_doh_listener_dns_check; then
        _installed=1
        _state=degraded; _reason=listener-query-failed
    elif ! _z2k_ow_doh_router_dns_check; then
        _installed=1
        _state=degraded; _reason=router-dns-check-failed
    else
        _installed=1
        _state=healthy
    fi
    [ "$(_z2k_ow_doh_get "${Z2K_DOH_PACKAGE}.config.force_dns")" = 1 ] && _force=1
    printf 'state=%s installed=%s enabled=%s provider=%s endpoint=%s bootstrap=%s package_owner=%s proxy=%s dnsmasq=%s force_lan_dns=%s reason=%s\n' \
        "$_state" "$_installed" "$_enabled" "$Z2K_DOH_PROVIDER" "$Z2K_DOH_ENDPOINT" "$Z2K_DOH_BOOTSTRAP" "$_owner" \
        "$([ "$_state" = healthy ] && echo ready || echo unavailable)" \
        "$([ "$_state" = healthy ] && echo routed || echo unavailable)" "$_force" "$_reason"
}

_z2k_ow_doh_record_error() {
    printf 'reason=%s\n' "$1" | _z2k_ow_doh_write_atomic "$Z2K_DOH_ERROR_FILE"
}

_z2k_ow_doh_install_rollback() {
    local _reason="$1" _rc=0 _external=0 _cleanup_reason
    _z2k_ow_doh_dnsmasq_restore || _rc=1
    _z2k_ow_doh_set_enabled_state 0 || _rc=1
    if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        if [ "$(_z2k_ow_doh_config_type)" = https-dns-proxy ]; then
            _z2k_ow_doh_uci delete "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}" || _rc=1
            _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || _rc=1
        fi
    fi
    _z2k_ow_doh_restore_main || _rc=1
    if [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] \
        && [ ! -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] \
        && [ "$(_z2k_ow_doh_config_type)" = https-dns-proxy ]; then
        _external=1
    fi
    _z2k_ow_doh_has_new_external_sections && _external=1
    if [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && [ "$_external" = 0 ]; then
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || _rc=1
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || _rc=1
        "$Z2K_DOH_APK_BIN" del "$Z2K_DOH_PACKAGE" || _rc=1
        [ "$_rc" != 0 ] || rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_INSTALL_SNAPSHOT"
    elif [ -s "$Z2K_DOH_INSTALL_SNAPSHOT" ]; then
        _z2k_ow_doh_restore_install_service_state || _rc=1
    fi
    rm -f "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_STATE_FILE" "$Z2K_DOH_DHCP_SNAPSHOT"
    _cleanup_reason="$_reason"
    [ "$_rc" = 0 ] || _cleanup_reason=rollback-failed
    _z2k_ow_doh_record_error "$_cleanup_reason" || return 1
    return "$_rc"
}

z2k_ow_doh_install() {
    local _reason= _status
    _z2k_ow_doh_profile_load || { _z2k_ow_doh_record_error provider-config-invalid; return 1; }
    _z2k_ow_doh_progress "проверяю https-dns-proxy"
    if _z2k_ow_doh_package_installed && [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        _z2k_ow_doh_owned_config_valid || {
            echo "DoH: принадлежащая z2kOW конфигурация изменена; сохраняю её" >&2
            return 1
        }
        _status=$(z2k_ow_doh_status)
        case "$_status" in
            state=healthy\ *|state=installed-disabled\ *) ;;
            *) echo "DoH: текущая конфигурация не прошла runtime-проверку: ${_status#*reason=}" >&2; return 1 ;;
        esac
        _z2k_ow_doh_progress "уже установлен; текущее состояние сохранено"
        return 0
    fi
    if ! _z2k_ow_doh_package_installed; then
        _z2k_ow_doh_progress "устанавливаю необязательный пакет"
        if ! "$Z2K_DOH_APK_BIN" add "$Z2K_DOH_PACKAGE"; then
            _z2k_ow_doh_record_error package-install-failed || true
            return 1
        fi
        if ! _z2k_ow_doh_package_installed; then
            _z2k_ow_doh_record_error package-install-failed || true
            echo "DoH: apk не подтвердил установку https-dns-proxy" >&2
            return 1
        fi
        printf '%s\n' "$Z2K_DOH_PACKAGE" > "$Z2K_DOH_PACKAGE_OWNED_FILE" || return 1
        chmod 600 "$Z2K_DOH_PACKAGE_OWNED_FILE" 2>/dev/null || true
    fi
    if [ ! -s "$Z2K_DOH_INSTALL_SNAPSHOT" ] && ! _z2k_ow_doh_capture_install_state; then
        _z2k_ow_doh_install_rollback install-snapshot-failed || true
        return 1
    fi
    if ! _z2k_ow_doh_prepare_config; then
        _reason=${Z2K_DOH_FAILURE_REASON:-resolver-config-failed}
        _z2k_ow_doh_install_rollback "$_reason" || true
        return 1
    fi
    if ! _z2k_ow_doh_set_enabled_state 0; then
        _z2k_ow_doh_install_rollback state-save-failed || true
        return 1
    fi
    _z2k_ow_doh_progress "запускаю provider и проверяю его локальный DNS listener"
    if ! _z2k_ow_doh_set_enabled_state 1 \
        || ! "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 \
        || ! "$Z2K_DOH_PROXY_INIT" restart; then
        _reason=proxy-start-failed
    elif ! _z2k_ow_doh_listener_ready || ! _z2k_ow_doh_listener_dns_check; then
        _reason=listener-query-failed
    else
        _z2k_ow_doh_progress "маршрутизирую обычный DNS через dnsmasq"
        if ! _z2k_ow_doh_dnsmasq_apply || ! "$Z2K_DOH_DNSMASQ_INIT" restart; then
            _reason=dnsmasq-restart-failed
        elif ! _z2k_ow_doh_router_dns_check; then
            _reason=router-dns-check-failed
        else
            _status=$(z2k_ow_doh_status)
            case "$_status" in state=healthy\ *) ;;
                *) _reason=$(printf '%s\n' "$_status" | sed -n 's/.*reason=\([^ ]*\).*/\1/p')
                    [ -n "$_reason" ] || _reason=runtime-check-failed ;;
            esac
        fi
    fi
    if [ -n "$_reason" ]; then
        echo "DoH: runtime-проверка не пройдена (${_reason}); откатываю изменения z2kOW" >&2
        _z2k_ow_doh_install_rollback "$_reason" || true
        return 1
    fi
    if ! _z2k_ow_doh_dnsmasq_restore; then
        _z2k_ow_doh_install_rollback dnsmasq-restore-failed || true
        return 1
    fi
    if ! _z2k_ow_doh_set_enabled_state 0; then
        _z2k_ow_doh_install_rollback service-restore-failed || true
        return 1
    fi
    if _z2k_ow_doh_should_preserve_package; then
        if ! _z2k_ow_doh_remove_owned_section || ! _z2k_ow_doh_restore_main \
            || ! _z2k_ow_doh_restore_install_service_state; then
            _z2k_ow_doh_install_rollback service-restore-failed || true
            return 1
        fi
    elif ! _z2k_ow_doh_restore_install_service_state; then
        _z2k_ow_doh_install_rollback service-restore-failed || true
        return 1
    fi
    rm -f "$Z2K_DOH_ERROR_FILE"
    _z2k_ow_doh_progress "установлен; DoH оставлен выключенным, принудительный DNS выключен"
    return 0
}

z2k_ow_doh_select_provider() {
    local _provider="${1:-}" _endpoint="${2:-}" _bootstrap="${3:-}"
    local _old_provider _old_endpoint _old_bootstrap _rc=0
    _z2k_ow_doh_profile_load || return 1
    _old_provider=$Z2K_DOH_PROVIDER
    _old_endpoint=$Z2K_DOH_ENDPOINT
    _old_bootstrap=$Z2K_DOH_BOOTSTRAP
    if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        if [ -n "$(_z2k_ow_doh_config_type)" ]; then
            _z2k_ow_doh_owned_config_valid || { echo "DoH: сначала проверьте текущую resolver section" >&2; return 1; }
        elif _z2k_ow_doh_enabled; then
            echo "DoH: включённый resolver section отсутствует" >&2
            return 1
        fi
    fi
    _z2k_ow_doh_profile_save "$_provider" "$_endpoint" "$_bootstrap" || {
        echo "DoH: неизвестный provider или некорректный HTTPS endpoint/bootstrap DNS" >&2
        return 1
    }
    if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] && [ -n "$(_z2k_ow_doh_config_type)" ]; then
        _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.resolver_url=${Z2K_DOH_ENDPOINT}" || _rc=1
        _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.bootstrap_dns=${Z2K_DOH_BOOTSTRAP}" || _rc=1
        _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || _rc=1
        if [ "$_rc" = 0 ] && _z2k_ow_doh_enabled; then
            "$Z2K_DOH_PROXY_INIT" restart || _rc=1
            _z2k_ow_doh_dnsmasq_verify || _rc=1
        fi
    fi
    if [ "$_rc" != 0 ]; then
        _z2k_ow_doh_profile_save "$_old_provider" "$_old_endpoint" "$_old_bootstrap" || true
        if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
            _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.resolver_url=${_old_endpoint}" || true
            _z2k_ow_doh_uci set "${Z2K_DOH_PACKAGE}.${Z2K_DOH_SECTION}.bootstrap_dns=${_old_bootstrap}" || true
            _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || true
            _z2k_ow_doh_enabled && "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || true
        fi
        _z2k_ow_doh_record_error provider-update-failed || true
        return 1
    fi
    rm -f "$Z2K_DOH_ERROR_FILE"
    _z2k_ow_doh_progress "provider $Z2K_DOH_PROVIDER_LABEL сохранён"
    return 0
}

_z2k_ow_doh_enable_rollback() {
    local _reason="$1" _rc=0
    _z2k_ow_doh_dnsmasq_restore || _rc=1
    _z2k_ow_doh_set_enabled_state 0 || _rc=1
    if _z2k_ow_doh_should_preserve_package; then
        _z2k_ow_doh_remove_owned_section || _rc=1
        _z2k_ow_doh_restore_main || _rc=1
        _z2k_ow_doh_restore_install_service_state || _rc=1
    else
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || _rc=1
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || _rc=1
    fi
    [ "$_rc" = 0 ] || _reason=rollback-failed
    _z2k_ow_doh_record_error "$_reason" || return 1
    return "$_rc"
}

z2k_ow_doh_enable() {
    local _reason= _type
    _z2k_ow_doh_package_installed && [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] || {
        echo "DoH: сначала установите принадлежащую z2kOW конфигурацию" >&2; return 1;
    }
    if _z2k_ow_doh_should_preserve_package; then
        _z2k_ow_doh_capture_runtime_service_state || return 1
    fi
    _type=$(_z2k_ow_doh_config_type) || _type=""
    if [ -n "$_type" ]; then
        _z2k_ow_doh_owned_config_valid || {
            echo "DoH: конфигурация изменена извне; сохраняю её" >&2
            return 1
        }
    elif _z2k_ow_doh_should_preserve_package; then
        _z2k_ow_doh_prepare_config || {
            _reason=${Z2K_DOH_FAILURE_REASON:-resolver-config-failed}
            _z2k_ow_doh_enable_rollback "$_reason" || true
            return 1
        }
    else
        echo "DoH: принадлежащая z2kOW resolver section отсутствует" >&2
        return 1
    fi
    if _z2k_ow_doh_other_section_uses_port "$(_z2k_ow_doh_active_port)"; then
        echo "DoH: выбранный локальный DNS порт занят другой https-dns-proxy секцией" >&2
        return 1
    fi
    _z2k_ow_doh_progress "запускаю $Z2K_DOH_PROVIDER_LABEL и проверяю listener"
    if ! _z2k_ow_doh_set_enabled_state 1 \
        || ! "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 \
        || ! "$Z2K_DOH_PROXY_INIT" restart; then
        _reason=proxy-start-failed
    elif ! _z2k_ow_doh_listener_ready || ! _z2k_ow_doh_listener_dns_check; then
        _reason=listener-query-failed
    elif ! _z2k_ow_doh_dnsmasq_apply || ! "$Z2K_DOH_DNSMASQ_INIT" restart; then
        _reason=dnsmasq-restart-failed
    elif ! _z2k_ow_doh_router_dns_check; then
        _reason=router-dns-check-failed
    elif ! z2k_ow_doh_status | grep -q '^state=healthy '; then
        _reason=runtime-check-failed
    fi
    if [ -n "$_reason" ]; then
        echo "DoH: включение не прошло проверку (${_reason}); откатываю изменения z2kOW" >&2
        _z2k_ow_doh_enable_rollback "$_reason" || true
        return 1
    fi
    rm -f "$Z2K_DOH_ERROR_FILE"
    _z2k_ow_doh_progress "DoH включён и проверен через listener и dnsmasq"
    return 0
}

z2k_ow_doh_disable() {
    local _preserve=0
    _z2k_ow_doh_owned_config_valid || { echo "DoH: принадлежащая z2kOW секция отсутствует" >&2; return 1; }
    _z2k_ow_doh_progress "возвращаю dnsmasq к обычным upstream DNS"
    _z2k_ow_doh_dnsmasq_restore || return 1
    _z2k_ow_doh_set_enabled_state 0 || return 1
    _z2k_ow_doh_should_preserve_package && _preserve=1
    if [ "$_preserve" = 1 ]; then
        _z2k_ow_doh_remove_owned_section || return 1
        _z2k_ow_doh_restore_main || return 1
        _z2k_ow_doh_restore_install_service_state || return 1
    else
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || return 1
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || return 1
    fi
    _z2k_ow_doh_progress "DoH выключен; пакет и выбранный resolver сохранены"
}

z2k_ow_doh_restart() {
    _z2k_ow_doh_enabled || { echo "DoH выключен; включите его перед перезапуском" >&2; return 1; }
    _z2k_ow_doh_progress "перезапускаю https-dns-proxy"
    "$Z2K_DOH_PROXY_INIT" restart || return 1
    _z2k_ow_doh_dnsmasq_verify || {
        "$Z2K_DOH_DNSMASQ_INIT" restart >/dev/null 2>&1 || true
        z2k_ow_doh_status >&2
        return 1
    }
    _z2k_ow_doh_progress "DoH снова проверен через dnsmasq"
}

z2k_ow_doh_check() {
    local _status _state
    _status=$(z2k_ow_doh_status); printf '%s\n' "$_status"
    _state=$(printf '%s\n' "$_status" | sed -n 's/^state=\([^ ]*\).*/\1/p')
    case "$_state" in healthy|installed-disabled) return 0 ;; *) return 1 ;; esac
}

z2k_ow_doh_set_force_dns() {
    local _value="${1:-}"
    case "$_value" in 0|1) ;; *) echo "DoH: force DNS принимает только 0 или 1" >&2; return 1 ;; esac
    _z2k_ow_doh_owned_config_valid || { echo "DoH: конфигурация не установлена" >&2; return 1; }
    _z2k_ow_doh_set_main force_dns "$_value" || return 1
    if _z2k_ow_doh_enabled; then
        "$Z2K_DOH_PROXY_INIT" restart || return 1
        "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
        _z2k_ow_doh_dnsmasq_verify || return 1
    fi
    _z2k_ow_doh_progress "принудительный DNS для LAN $([ "$_value" = 1 ] && echo включён || echo выключен)"
}

z2k_ow_doh_uninstall() {
    local _rc=0 _owned_package=0 _external=0 _enabled_before _running_before _section_type
    [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] || {
        if [ ! -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ]; then
            rm -f "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_ERROR_FILE" "$Z2K_DOH_STATE_FILE"
            return 0
        fi
        _z2k_ow_doh_has_new_external_sections && _external=1
        if [ -s "$Z2K_DOH_MAIN_SNAPSHOT" ]; then
            _z2k_ow_doh_restore_main || return 1
        fi
        if [ "$_external" = 0 ]; then
            if [ -s "$Z2K_DOH_INSTALL_SNAPSHOT" ]; then
                _z2k_ow_doh_restore_install_service_state || return 1
            else
                "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || return 1
                _z2k_ow_doh_proxy_running && "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || true
            fi
            "$Z2K_DOH_APK_BIN" del "$Z2K_DOH_PACKAGE" || return 1
        else
            _z2k_ow_doh_restore_install_service_state || return 1
            echo "DoH: установка прервана; https-dns-proxy оставлен с внешними resolver sections" >&2
        fi
        rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_INSTALL_SNAPSHOT"
        rm -f "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_ERROR_FILE" "$Z2K_DOH_STATE_FILE"
        return 0
    }
    _z2k_ow_doh_progress "удаляю DoH resolver и восстанавливаю dnsmasq"
    _z2k_ow_doh_dnsmasq_restore || _rc=1
    _section_type=$(_z2k_ow_doh_config_type) || _section_type=""
    if [ -n "$_section_type" ]; then
        _z2k_ow_doh_owned_config_valid || {
            echo "DoH: конфигурация изменена извне; сохраняю её" >&2
            return 1
        }
        _z2k_ow_doh_remove_owned_section || _rc=1
    elif _z2k_ow_doh_enabled; then
        echo "DoH: активный resolver section отсутствует; сохраняю состояние" >&2
        return 1
    fi
    _z2k_ow_doh_restore_main || _rc=1
    [ "$_rc" = 0 ] || { echo "DoH: не удалось восстановить OpenWrt настройки" >&2; return 1; }
    _z2k_ow_doh_should_preserve_package && _external=1
    if [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ]; then _owned_package=1; fi
    _enabled_before=$(_z2k_ow_doh_file_value enabled_before "$Z2K_DOH_INSTALL_SNAPSHOT")
    _running_before=$(_z2k_ow_doh_file_value running_before "$Z2K_DOH_INSTALL_SNAPSHOT")
    rm -f "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_STATE_FILE" "$Z2K_DOH_DHCP_SNAPSHOT" \
        "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_ERROR_FILE"
    if [ "$_owned_package" = 1 ] && [ "$_external" = 0 ]; then
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || _rc=1
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || _rc=1
        if "$Z2K_DOH_APK_BIN" del "$Z2K_DOH_PACKAGE"; then
            rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_INSTALL_SNAPSHOT"
        else
            _rc=1
        fi
    else
        rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE"
        if [ "$_enabled_before" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || _rc=1
        else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || _rc=1; fi
        if [ "$_running_before" = 1 ] || [ "$_external" = 1 ]; then
            "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || _rc=1
        elif _z2k_ow_doh_proxy_running; then
            "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || _rc=1
        fi
        rm -f "$Z2K_DOH_INSTALL_SNAPSHOT"
        [ "$_external" = 0 ] || echo "DoH: https-dns-proxy оставлен — найдены внешние resolver sections" >&2
    fi
    [ "$_rc" = 0 ]
}
