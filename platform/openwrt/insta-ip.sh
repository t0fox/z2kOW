#!/bin/sh
# OpenWrt host-record backend for the shared upstream IP refresh flow.
# The helper keeps its DNS fetch, HMAC, range filter, and HTTPS liveness probes;
# validated address records are applied through dnsmasq addnhosts.

Z2K_INSTA_HOSTS_FILE="${Z2K_INSTA_HOSTS_FILE:-${Z2K_STATE:-/etc/z2k/state}/insta-hosts}"
Z2K_INSTA_UCI_MARKER="${Z2K_INSTA_UCI_MARKER:-${Z2K_STATE:-/etc/z2k/state}/.insta-addnhosts-owned}"
Z2K_INSTA_UCI_SECTION="${Z2K_INSTA_UCI_SECTION:-dhcp.@dnsmasq[0]}"
Z2K_INSTA_UCI_BIN="${Z2K_INSTA_UCI_BIN:-uci}"
Z2K_INSTA_DNSMASQ_INIT="${Z2K_INSTA_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"

z2k_ow_insta_registered() {
    "$Z2K_INSTA_UCI_BIN" -q show dhcp 2>/dev/null \
        | tr -d "'\"" \
        | grep -F ".addnhosts=$Z2K_INSTA_HOSTS_FILE" >/dev/null 2>&1
}

z2k_ow_insta_reload_dnsmasq() {
    [ -x "$Z2K_INSTA_DNSMASQ_INIT" ] || return 1
    "$Z2K_INSTA_DNSMASQ_INIT" reload >/dev/null 2>&1
}

# Register an exact persistent file path without replacing any existing
# dnsmasq addnhosts entries. Remember ownership only if this function added it.
z2k_ow_insta_prepare() {
    command -v "$Z2K_INSTA_UCI_BIN" >/dev/null 2>&1 || return 1
    [ -x "$Z2K_INSTA_DNSMASQ_INIT" ] || return 1
    "$Z2K_INSTA_UCI_BIN" -q show "$Z2K_INSTA_UCI_SECTION" >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$Z2K_INSTA_HOSTS_FILE")" "$(dirname "$Z2K_INSTA_UCI_MARKER")" \
        2>/dev/null || return 1
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] || : > "$Z2K_INSTA_HOSTS_FILE" || return 1
    if ! z2k_ow_insta_registered; then
        "$Z2K_INSTA_UCI_BIN" add_list \
            "$Z2K_INSTA_UCI_SECTION.addnhosts=$Z2K_INSTA_HOSTS_FILE" || return 1
        "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
        printf '%s\n' "$Z2K_INSTA_HOSTS_FILE" > "$Z2K_INSTA_UCI_MARKER" || return 1
        chmod 0600 "$Z2K_INSTA_UCI_MARKER" 2>/dev/null || return 1
        z2k_ow_insta_reload_dnsmasq || return 1
    fi
    return 0
}

# Match the upstream `show running-config` shape so its host/IP diff loop and
# validation stay shared: `ip host <hostname> <address>`.
z2k_ow_insta_show_running_config() {
    [ -r "$Z2K_INSTA_HOSTS_FILE" ] || return 0
    awk '
        /^[[:space:]]*#/ || NF < 2 { next }
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            ip=$1
            for (i=2; i<=NF; i++)
                if ($i ~ /^[a-zA-Z0-9.-]+$/) print "ip host " $i " " ip
        }
    ' "$Z2K_INSTA_HOSTS_FILE"
}

_z2k_ow_insta_write() {
    local _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k.$$"
    mkdir -p "$(dirname "$Z2K_INSTA_HOSTS_FILE")" 2>/dev/null || return 1
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
}

z2k_ow_insta_add_host() {
    local _host="$1" _ip="$2" _tmp
    case "$_host" in ''|*[!a-zA-Z0-9.-]*) return 1 ;; esac
    printf '%s\n' "$_ip" | awk -F. 'NF==4 && $1<256 && $2<256 && $3<256 && $4<256 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/' \
        | grep -q . || return 1
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] && awk -v h="$_host" -v ip="$_ip" \
        '$1==ip && $2==h {found=1} END {exit !found}' "$Z2K_INSTA_HOSTS_FILE" \
        && return 0
    _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k.$$"
    { [ ! -f "$Z2K_INSTA_HOSTS_FILE" ] || cat "$Z2K_INSTA_HOSTS_FILE"; \
      printf '%s %s\n' "$_ip" "$_host"; } > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
    return 0
}

z2k_ow_insta_remove_host() {
    local _host="$1" _ip="$2"
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] || return 0
    awk -v h="$_host" -v ip="$_ip" '!($1==ip && $2==h)' \
        "$Z2K_INSTA_HOSTS_FILE" | _z2k_ow_insta_write
}

# Заменить записи для нескольких проверенных доменов одним атомарным rename.
# Включения dnsmasq и все прочие строки остаются нетронутыми.
z2k_ow_insta_replace_hosts() {
    local _hosts="$1" _records="$2" _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k.$$"
    [ -f "$Z2K_INSTA_HOSTS_FILE" ] && [ ! -L "$Z2K_INSTA_HOSTS_FILE" ] || return 1
    printf '%s\n' "$_records" | awk '
        NF!=2 {exit 1}
        $1 !~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ {exit 1}
        $2 !~ /^[a-zA-Z0-9.-]+$/ {exit 1}
        {n=split($1,p,"."); for(i=1;i<=n;i++) if(p[i]>255) exit 1}
        {print}
    ' >/dev/null || return 1
    awk -v hosts="$_hosts" '
        BEGIN { n=split(hosts,h,/ +/); for(i=1;i<=n;i++) wanted[h[i]]=1 }
        /^[[:space:]]*#/ || NF<2 {print; next}
        wanted[$2] {next}
        {print}
    ' "$Z2K_INSTA_HOSTS_FILE" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    [ -z "$_records" ] || printf '%s\n' "$_records" >> "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0644 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE" || { rm -f "$_tmp"; return 1; }
}

z2k_ow_insta_restore_hosts() {
    local _backup="$1" _tmp="${Z2K_INSTA_HOSTS_FILE}.z2k-restore.$$"
    [ -f "$_backup" ] && [ ! -L "$_backup" ] || return 1
    cp -p "$_backup" "$_tmp" && mv -f "$_tmp" "$Z2K_INSTA_HOSTS_FILE"
}

z2k_ow_insta_commit() {
    "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
    z2k_ow_insta_reload_dnsmasq
}

z2k_ow_insta_flush_ip() {
    command -v conntrack >/dev/null 2>&1 || return 0
    conntrack -D -d "$1" >/dev/null 2>&1 || true
    return 0
}

# Получить A-записи напрямую у независимых DNS-over-HTTPS резолверов.
# Привязанный --resolve убирает зависимость начального запроса от DNS роутера;
# сертификат резолвера проверяется curl. Диапазон адреса и HTTPS/SNI затем
# проверяет общий z2k-insta-ip-refresh.sh.
z2k_ow_insta_resolve_hosts() {
    local _hosts="$*" _cache="${Z2K_INSTA_CACHE_FILE:-${Z2K_STATE:-/etc/z2k/state}/insta-ip-candidates}"
    local _now="${Z2K_INSTA_NOW:-$(date +%s)}" _grace="${Z2K_INSTA_CACHE_STALE_GRACE:-86400}"
    local _work="${_cache}.z2k.$$" _host _endpoint _name _ip _path _rest _tmp _result _found _rc
    case "$_now" in ''|*[!0-9]*) return 1 ;; esac
    case "$_grace" in ''|*[!0-9]*) _grace=86400 ;; esac
    [ ! -L "$_cache" ] || return 1
    [ ! -e "$_cache" ] || [ -f "$_cache" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    command -v jsonfilter >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$_cache")" 2>/dev/null || return 1
    _tmp="${_work}.json"
    _result="${_work}.result"
    : > "$_work" || return 1
    : > "$_tmp" || { rm -f "$_work"; return 1; }
    : > "$_result" || { rm -f "$_work" "$_tmp"; return 1; }

# Сохранить кэш доменов, которые этот запуск не обновляет.
    if [ -r "$_cache" ]; then
        awk -v hosts="$_hosts" '
            BEGIN { n=split(hosts,h,/ +/); for(i=1;i<=n;i++) wanted[h[i]]=1 }
            NF==5 && !wanted[$2] && $1~/^[0-9]+$/ && $3~/^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/ {print}
            ' "$_cache" > "$_work" || { rm -f "$_work" "$_tmp" "$_result"; return 1; }
    fi

    _found=0
    for _host in $_hosts; do
        case "$_host" in ''|*[!a-zA-Z0-9.-]*) continue ;; esac
        for _endpoint in 'cloudflare-dns.com|1.1.1.1|dns-query' \
            'dns.google|8.8.8.8|resolve' 'dns.adguard-dns.com|94.140.14.14|resolve'; do
            _name="${_endpoint%%|*}"
            _rest="${_endpoint#*|}"
            _ip="${_rest%%|*}"
            _path="${_rest#*|}"
            rm -f "$_tmp"
            if ! curl --fail --silent --show-error --connect-timeout 3 --max-time 8 \
                --resolve "$_name:443:$_ip" -H 'accept: application/dns-json' \
                "https://$_name/$_path?name=$_host&type=A" -o "$_tmp" 2>/dev/null; then
                continue
            fi
            _data="${_tmp}.data" _ttls="${_tmp}.ttls"
            jsonfilter -i "$_tmp" -e '@.Answer[*].data' > "$_data" 2>/dev/null || :
            jsonfilter -i "$_tmp" -e '@.Answer[*].TTL' > "$_ttls" 2>/dev/null || :
            awk 'FNR==NR {data[FNR]=$0; next} {print data[FNR] " " $0}' \
                "$_data" "$_ttls" | while read -r _answer _answer_ttl; do
                printf '%s\n' "$_answer" | awk -F. 'NF==4 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ && $4~/^[0-9]+$/ && $1<256 && $2<256 && $3<256 && $4<256' | grep -q . || continue
                case "$_answer_ttl" in ''|*[!0-9]*) _answer_ttl=300 ;; esac
                [ "$_answer_ttl" -gt 0 ] || _answer_ttl=30
                [ "$_answer_ttl" -le 86400 ] || _answer_ttl=86400
                _answer_expiry=$((_now + _answer_ttl))
                printf '%s\t%s\n' "$_host" "$_answer" >> "$_result"
                printf '%s %s %s %s %s\n' "$_answer_expiry" "$_host" "$_answer" "$_answer_ttl" "$_name" >> "$_work"
                : > "${_work}.fresh.$_host"
            done
            if [ -f "${_work}.fresh.$_host" ]; then
                _found=1
                rm -f "${_work}.fresh.$_host"
            fi
            rm -f "$_data" "$_ttls"
        done
        # При отказе резолверов используем записи с действующим TTL и
        # ограниченный устаревший кэш; HTTPS/SNI probe проверит адреса.
        if ! grep -q " $_host " "$_work" 2>/dev/null; then
            if [ -r "$_cache" ]; then
                awk -v h="$_host" -v now="$_now" -v grace="$_grace" \
                    '$2==h && $1+grace>=now {print $2 "\t" $3}' "$_cache" >> "$_result" \
                    || { rm -f "$_work" "$_tmp" "$_result"; return 1; }
                awk -v h="$_host" -v now="$_now" -v grace="$_grace" \
                    '$2==h && $1+grace>=now {print}' "$_cache" >> "$_work" \
                    || { rm -f "$_work" "$_tmp" "$_result"; return 1; }
            fi
        fi
    done
    rm -f "$_tmp"
    if [ "$_found" = 1 ]; then
        sort -u "$_work" -o "$_work" || { rm -f "$_work"; return 1; }
        mv -f "$_work" "$_cache" || { rm -f "$_work"; return 1; }
    else
        rm -f "$_work"
    fi
    if [ -s "$_result" ]; then
        cat "$_result"
        _rc=0
    else
        _rc=1
    fi
    rm -f "$_result"
    return "$_rc"
}

# Called before the complete payload tree is removed. Only delete the UCI list
# entry if z2k created it; user addnhosts entries and dnsmasq settings survive.
z2k_ow_insta_uninstall() {
    local _owned=""
    if [ -r "$Z2K_INSTA_UCI_MARKER" ]; then
        _owned=$(cat "$Z2K_INSTA_UCI_MARKER" 2>/dev/null)
        if [ "$_owned" = "$Z2K_INSTA_HOSTS_FILE" ]; then
            "$Z2K_INSTA_UCI_BIN" del_list \
                "$Z2K_INSTA_UCI_SECTION.addnhosts=$Z2K_INSTA_HOSTS_FILE" || return 1
            "$Z2K_INSTA_UCI_BIN" commit dhcp || return 1
            z2k_ow_insta_reload_dnsmasq || return 1
        fi
    fi
    rm -f "$Z2K_INSTA_HOSTS_FILE" "$Z2K_INSTA_UCI_MARKER"
}
