#!/bin/sh
# OpenWrt dnsproxy UCI/procd adapter. doh.sh only sources this file for API compatibility.
Z2K_DOH_PACKAGE=dnsproxy
Z2K_DOH_SECTION=z2kow
[ -n "${Z2K_DOH_UCI_BIN:-}" ] || Z2K_DOH_UCI_BIN=uci
[ -n "${Z2K_DOH_APK_BIN:-}" ] || Z2K_DOH_APK_BIN=apk
[ -n "${Z2K_DOH_PIDOF_BIN:-}" ] || Z2K_DOH_PIDOF_BIN=pidof
[ -n "${Z2K_DOH_PROXY_INIT:-}" ] || Z2K_DOH_PROXY_INIT=/etc/init.d/dnsproxy
[ -n "${Z2K_DOH_DNSMASQ_INIT:-}" ] || Z2K_DOH_DNSMASQ_INIT=/etc/init.d/dnsmasq
[ -n "${Z2K_STATE:-}" ] || Z2K_STATE=/etc/z2k/state
_Z2K_DOH_DIR=$Z2K_STATE
[ -n "${Z2K_DOH_PACKAGE_OWNED_FILE:-}" ] || Z2K_DOH_PACKAGE_OWNED_FILE=$_Z2K_DOH_DIR/.dnsproxy-package-owned
[ -n "${Z2K_DOH_CONFIG_OWNED_FILE:-}" ] || Z2K_DOH_CONFIG_OWNED_FILE=$_Z2K_DOH_DIR/.dnsproxy-config-owned
[ -n "${Z2K_DOH_CONFIG_BACKUP:-}" ] || Z2K_DOH_CONFIG_BACKUP=$_Z2K_DOH_DIR/.dnsproxy-config-backup
[ -n "${Z2K_DOH_CONFIG_BASELINE:-}" ] || Z2K_DOH_CONFIG_BASELINE=$_Z2K_DOH_DIR/.dnsproxy-config-baseline
[ -n "${Z2K_DOH_PREINSTALL_CONFIG_MARKER:-}" ] || Z2K_DOH_PREINSTALL_CONFIG_MARKER=$_Z2K_DOH_DIR/.dnsproxy-preinstall-config-present
[ -n "${Z2K_DOH_INSTALL_SNAPSHOT:-}" ] || Z2K_DOH_INSTALL_SNAPSHOT=$_Z2K_DOH_DIR/.dnsproxy-install-snapshot
[ -n "${Z2K_DOH_SERVICE_SNAPSHOT:-}" ] || Z2K_DOH_SERVICE_SNAPSHOT=$_Z2K_DOH_DIR/.dnsproxy-service-snapshot
[ -n "${Z2K_DOH_STATE_FILE:-}" ] || Z2K_DOH_STATE_FILE=$_Z2K_DOH_DIR/doh.state
[ -n "${Z2K_DOH_PROFILE_FILE:-}" ] || Z2K_DOH_PROFILE_FILE=$_Z2K_DOH_DIR/doh.provider
[ -n "${Z2K_DOH_ROUTE_SNAPSHOT:-}" ] || Z2K_DOH_ROUTE_SNAPSHOT=$_Z2K_DOH_DIR/.dnsproxy-dnsmasq-snapshot
[ -n "${Z2K_DOH_LEGACY_ROUTE_TXN:-}" ] || Z2K_DOH_LEGACY_ROUTE_TXN=$_Z2K_DOH_DIR/.dnsproxy-legacy-route-txn
[ -n "${Z2K_DOH_REDIRECT_MARKER:-}" ] || Z2K_DOH_REDIRECT_MARKER=$_Z2K_DOH_DIR/.dnsproxy-lan-redirect-owned
[ -n "${Z2K_DOH_FW4_BIN:-}" ] || Z2K_DOH_FW4_BIN=fw4
[ -n "${Z2K_DOH_FIREWALL_INIT:-}" ] || Z2K_DOH_FIREWALL_INIT=/etc/init.d/firewall
Z2K_DOH_CONFIG_FILE=${Z2K_DOH_CONFIG_FILE:-/etc/config/dnsproxy}
Z2K_DOH_OLD_PACKAGE=https-dns-proxy
Z2K_DOH_OLD_INIT=${Z2K_DOH_OLD_INIT:-/etc/init.d/https-dns-proxy}
Z2K_DOH_OLD_BACKUP=${Z2K_DOH_OLD_BACKUP:-$_Z2K_DOH_DIR/.https-dns-proxy-migration-snapshot}
Z2K_DOH_OLD_OWNED=${Z2K_DOH_OLD_OWNED:-$_Z2K_DOH_DIR/.https-dns-proxy-package-owned}
Z2K_DOH_OLD_SERVICE_SNAPSHOT=${Z2K_DOH_OLD_SERVICE_SNAPSHOT:-$_Z2K_DOH_DIR/.https-dns-proxy-service-snapshot}
Z2K_DOH_PORT=${Z2K_DOH_PORT:-5353}
Z2K_DOH_DEFAULT_BOOTSTRAP='9.9.9.9,149.112.112.112,8.8.8.8,8.8.4.4,2620:fe::fe,2620:fe::9,2001:4860:4860::8888,2001:4860:4860::8844'
_z2k_ow_doh_old_owned() { [ -s "$Z2K_DOH_OLD_OWNED" ] || [ -s "$_Z2K_DOH_DIR/.doh-package-owned" ]; }

_z2k_ow_doh_uci() { "$Z2K_DOH_UCI_BIN" "$@"; }
_z2k_ow_doh_get() { _z2k_ow_doh_uci -q get "$1" 2>/dev/null; }
_z2k_ow_doh_export() { _z2k_ow_doh_uci -q export dnsproxy 2>/dev/null; }
_z2k_ow_doh_installed() { "$Z2K_DOH_APK_BIN" info -e dnsproxy >/dev/null 2>&1; }
_z2k_ow_doh_running() { "$Z2K_DOH_PIDOF_BIN" dnsproxy >/dev/null 2>&1; }
_z2k_ow_doh_enabled() { "$Z2K_DOH_PROXY_INIT" enabled >/dev/null 2>&1; }
_z2k_ow_doh_progress() {
    [ -n "${Z2K_JOB_ID:-}" ] || return 0
    if command -v job_progress >/dev/null 2>&1; then job_progress "DNS: $*"; else printf 'DNS: %s\n' "$*" >&2; fi
}
_z2k_ow_doh_write() {
    _path=$1; mkdir -p "$(dirname "$_path")" 2>/dev/null || return 1
    _tmp=$_path.new.$$; cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || true; mv -f "$_tmp" "$_path"
}
_z2k_ow_doh_base64_encode() {
    _base64_bin=${Z2K_DOH_BASE64_BIN:-base64}
    if command -v "$_base64_bin" >/dev/null 2>&1; then
        _encoded=$(printf '%s' "$1" | "$_base64_bin" 2>/dev/null) || return 1
        printf '%s' "$_encoded" | tr -d '\n'
        return $?
    fi
    # OpenWrt's stock BusyBox build may omit both base64 and od. Profile state
    # still needs a single-line transport for the CGI status protocol, so use
    # awk's portable ASCII character conversion instead of adding a package.
    printf '%s' "$1" | LC_ALL=C awk '
      BEGIN {
        alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (i=1;i<128;i++) code[sprintf("%c",i)]=i
      }
      {
        if (NR>1) data=data "\n"
        data=data $0
      }
      END {
        n=length(data)
        for (i=1;i<=n;i+=3) {
          a=code[substr(data,i,1)]
          b=(i+1<=n ? code[substr(data,i+1,1)] : 0)
          c=(i+2<=n ? code[substr(data,i+2,1)] : 0)
          printf "%s%s", substr(alphabet,int(a/4)+1,1), substr(alphabet,(a%4)*16+int(b/16)+1,1)
          if (i+1<=n) printf "%s", substr(alphabet,(b%16)*4+int(c/64)+1,1); else printf "="
          if (i+2<=n) printf "%s", substr(alphabet,c%64+1,1); else printf "="
        }
      }'
}
_z2k_ow_doh_sections() {
    _z2k_ow_doh_uci -q show dnsproxy 2>/dev/null | awk -F= '$1~/^dnsproxy\.[^.]+$/&&$2~/dnsproxy/{s=$1;sub(/^dnsproxy\./,"",s);print s}' | sort -u
}
_z2k_ow_doh_external_config() {
    [ -n "$(_z2k_ow_doh_export)" ] || return 1
    [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] || return 0
    [ ! -s "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" ] || return 0
    [ -s "$Z2K_DOH_CONFIG_BASELINE" ] || return 0
    _baseline=$(cat "$Z2K_DOH_CONFIG_BASELINE"); _current=$(_z2k_ow_doh_export)
    [ "$_baseline" != "$_current" ]
}
_z2k_ow_doh_valid_bootstrap() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | awk -F, '
      function v4(s,a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||length(a[i])>3||a[i]+0>255||(length(a[i])>1&&substr(a[i],1,1)=="0"))return 0;return 1}
      function v6(s,a,n,i,c,g){if(s!~/:/||s~/[^0-9A-Fa-f:]/||s~/:::/)return 0;g=(s~/::/);if(g&&s~/::.*::/)return 0;n=split(s,a,":");c=0;for(i=1;i<=n;i++)if(a[i]!=""){if(length(a[i])>4)return 0;c++}if(g)return c<8;return c==8}
      NF<1||NF>8{exit 1}{for(i=1;i<=NF;i++)if(!v4($i)&&!v6($i))exit 1}'
}
_z2k_ow_doh_is_ip() {
    printf '%s\n' "$1" | awk '
      function v4(s,a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||length(a[i])>3||a[i]+0>255||(length(a[i])>1&&substr(a[i],1,1)=="0"))return 0;return 1}
      function v6(s,a,n,i,c,g){if(s!~/:/||s~/[^0-9A-Fa-f:]/||s~/:::/)return 0;g=(s~/::/);if(g&&s~/::.*::/)return 0;n=split(s,a,":");c=0;for(i=1;i<=n;i++)if(a[i]!=""){if(length(a[i])>4)return 0;c++}if(g)return c<8;return c==8}
      {exit !(v4($0)||v6($0))}'
}
_z2k_ow_doh_valid_upstream() {
    case "$1" in
        https://*|h3://*|tls://*|quic://*|sdns://*) ;;
        *) return 1 ;;
    esac
    case "$1" in *' '*|*"'"*|*'"'*|*'|'*|*';'*|*'&'*) return 1 ;; esac
    case "$1" in
        https://*|h3://*|tls://*|quic://*)
            _authority=$(printf %s "$1" | sed -E 's,^[a-z0-9]+://([^/?#]*).*,\1,')
            case "$_authority" in ''|.*|*.|*..*|*[!A-Za-z0-9.:%\[\]-]*) return 1 ;; esac ;;
        sdns://*) _z2k_ow_doh_dnscrypt_stamp "$1" || return 1 ;;
    esac
    [ "$(printf %s "$1" | wc -c | tr -d ' ')" -le 2048 ]
}
_z2k_ow_doh_profile_endpoint() {
    _endpoint=$1 _bootstrap=$2
    _z2k_ow_doh_valid_upstream "$_endpoint" || return 1
    case "$_endpoint" in
        # DNSCrypt stamps carry their resolver address; dnsproxy's bootstrap
        # list is for hostname-based DoH/DoT upstreams.
        sdns://*) return 0 ;;
        *://*)
            _authority=$(printf %s "$_endpoint" | sed -E 's,^[a-z0-9]+://([^/?#]*).*,\1,')
            case "$_authority" in \[*\]*) _host=${_authority#\[}; _host=${_host%%\]*} ;; *) _host=${_authority%%:*} ;; esac
            _z2k_ow_doh_is_ip "$_host" || [ -n "$_bootstrap" ] || return 1 ;;
    esac
}
_z2k_ow_doh_profile_list() {
    _items=$1 _bootstrap=$2 _required=$3
    [ -n "$_items" ] || [ "$_required" = 0 ] || return 1
    printf '%s\n' "$_items" | while IFS= read -r _item; do
        [ -n "$_item" ] || continue
        _z2k_ow_doh_profile_endpoint "$_item" "$_bootstrap" || exit 1
    done
}
_z2k_ow_doh_valid_domain() {
    printf '%s\n' "$1" | awk '
      {
        s=$0
        if(substr(s,1,2)=="*.")s=substr(s,3)
        if(s==""||length(s)>253||s~/[^A-Za-z0-9.-]/||s~/\.\./||s~/^\./||s~/\.$/)exit 1
        n=split(s,a,".")
        for(i=1;i<=n;i++)if(length(a[i])>63||a[i]~/^-/||a[i]~/-$/)exit 1
      }'
}
_z2k_ow_doh_dnscrypt_stamp() {
    _stamp=${1#sdns://}; [ -n "$_stamp" ] || return 1
    [ "${#_stamp}" -ge 15 ] || return 1
    case "$_stamp" in AQ*) ;; *) return 1 ;; esac
    case "$_stamp" in *[!A-Za-z0-9_-]*) return 1 ;; esac
}
_z2k_ow_doh_valid_custom_endpoint() {
    _z2k_ow_doh_protocol_scheme doh "$1"
}
_z2k_ow_doh_valid_protocol_endpoint() {
    _z2k_ow_doh_valid_upstream "$1" && _z2k_ow_doh_protocol_scheme "$2" "$1"
}
_z2k_ow_doh_protocol_scheme() {
    case "$1:$2" in
        doh:https://*) return 0 ;; doh3:h3://*) return 0 ;;
        dot:tls://*) return 0 ;; doq:quic://*) return 0 ;;
        dnscrypt:sdns://*) return 0 ;;
    esac
    return 1
}
z2k_ow_doh_provider_protocol_valid() {
    _provider=$1 _protocol=$2 _endpoint=${3:-}
    case "$_protocol" in doh|doh3|dot|doq|dnscrypt) ;; *) return 1 ;; esac
    case "$_provider:$_protocol" in
        quad9:*) ;;
        xbox:doh|comss:doh|google:doh|xyz:doh|geohide_ru:doh|geohide_eu:doh|geohide_us:doh|cloudflare:doh|dns_ai:doh|malw:doh|astracat:doh|mafioznik:doh|malw_cloudflare:doh|nullsproxy:doh|default:doh) ;;
        custom:*) [ -n "$_endpoint" ] && _z2k_ow_doh_valid_protocol_endpoint "$_endpoint" "$_protocol" || return 1 ;;
        *) return 1 ;;
    esac
}
_z2k_ow_doh_preset() {
    Z2K_DOH_PROVIDER=$1; Z2K_DOH_PROVIDER_LABEL=; Z2K_DOH_ENDPOINT=; Z2K_DOH_BOOTSTRAP=$Z2K_DOH_DEFAULT_BOOTSTRAP
    case "$1" in
        xbox) Z2K_DOH_PROVIDER_LABEL='Xbox DNS'; Z2K_DOH_ENDPOINT=https://xbox-dns.ru/dns-query ;;
        comss) Z2K_DOH_PROVIDER_LABEL=Comss; Z2K_DOH_ENDPOINT=https://dns.comss.one/dns-query ;;
        google) Z2K_DOH_PROVIDER_LABEL=Google; Z2K_DOH_ENDPOINT=https://dns.google/dns-query ;;
        quad9) Z2K_DOH_PROVIDER_LABEL=Quad9; Z2K_DOH_ENDPOINT=https://dns.quad9.net/dns-query ;;
        xyz) Z2K_DOH_PROVIDER_LABEL='XyZ DNS'; Z2K_DOH_ENDPOINT=https://dns.yo1nk.app/dns-query ;;
        geohide_ru) Z2K_DOH_PROVIDER_LABEL='GeoHide RU'; Z2K_DOH_ENDPOINT=https://geohide.ru/dns-query ;;
        geohide_eu) Z2K_DOH_PROVIDER_LABEL='GeoHide EU'; Z2K_DOH_ENDPOINT=https://eu.geohide.ru/dns-query ;;
        geohide_us) Z2K_DOH_PROVIDER_LABEL='GeoHide US'; Z2K_DOH_ENDPOINT=https://us.geohide.ru/dns-query ;;
        dns_ai) Z2K_DOH_PROVIDER_LABEL=dns.dns-ai.ru; Z2K_DOH_ENDPOINT=https://dns.dns-ai.ru/dns-query ;;
        malw) Z2K_DOH_PROVIDER_LABEL=dns.malw.link; Z2K_DOH_ENDPOINT=https://dns.malw.link/dns-query ;;
        astracat) Z2K_DOH_PROVIDER_LABEL=dns.astracat.ru; Z2K_DOH_ENDPOINT=https://dns.astracat.ru/dns-query ;;
        mafioznik) Z2K_DOH_PROVIDER_LABEL=dns.mafioznik.xyz; Z2K_DOH_ENDPOINT=https://dns.mafioznik.xyz/dns-query ;;
        malw_cloudflare) Z2K_DOH_PROVIDER_LABEL='malw Cloudflare Gateway'; Z2K_DOH_ENDPOINT=https://5u35p8m9i7.cloudflare-gateway.com/dns-query ;;
        nullsproxy) Z2K_DOH_PROVIDER_LABEL=nullsproxy; Z2K_DOH_ENDPOINT=https://dns.nullsproxy.com/dns-query ;;
        cloudflare) Z2K_DOH_PROVIDER_LABEL=Cloudflare; Z2K_DOH_ENDPOINT=https://cloudflare-dns.com/dns-query ;;
        default) Z2K_DOH_PROVIDER_LABEL='Cloudflare + Google'; Z2K_DOH_ENDPOINT='https://cloudflare-dns.com/dns-query
https://dns.google/dns-query' ;;
        *) return 1 ;;
    esac
}
_z2k_ow_doh_server_values() { _z2k_ow_doh_uci -q show dnsproxy.servers 2>/dev/null | awk -F= '$1~/\.upstream$/||$1~/\.bootstrap$/ {v=substr($0,index($0,"=")+1);gsub(/^\047|\047$/,"",v);print v}'; }
_z2k_ow_doh_configured_protocol() {
    _servers=$(_z2k_ow_doh_uci -q show dnsproxy.servers 2>/dev/null | awk -F= '$1~/\.upstream$/ {v=substr($0,index($0,"=")+1);gsub(/^\047|\047$/,"",v);print v}')
    _fallbacks=$(_z2k_ow_doh_uci -q show dnsproxy.servers 2>/dev/null | awk -F= '$1~/\.fallback$/ {v=substr($0,index($0,"=")+1);gsub(/^\047|\047$/,"",v);print v}')
    [ -n "$_servers" ] || return 1
    _values=$_servers; [ -z "$_fallbacks" ] || _values=$(printf '%s\n%s' "$_servers" "$_fallbacks")
    _protocol=
    while IFS= read -r _value; do
        case "$_value" in https://*) _item=doh ;; h3://*) _item=doh3 ;; tls://*) _item=dot ;; quic://*) _item=doq ;; sdns://*) _item=dnscrypt ;; *) return 1 ;; esac
        if [ -z "$_protocol" ]; then _protocol=$_item; elif [ "$_protocol" != "$_item" ]; then return 1; fi
    done <<EOF
$_values
EOF
    [ -n "$_protocol" ] || return 1
    printf '%s\n' "$_protocol"
}
_z2k_ow_doh_save_route() {
    [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ] && return 0
    _noresolv=$(_z2k_ow_doh_get 'dhcp.@dnsmasq[0].noresolv') || _noresolv=__unset__
    if _z2k_ow_doh_old_owned; then
        _legacy_noresolv=$(_z2k_ow_doh_get 'dhcp.@dnsmasq[0].doh_backup_noresolv') || _legacy_noresolv=
        case "$_legacy_noresolv" in -1) _noresolv=__unset__ ;; 0|1) _noresolv=$_legacy_noresolv ;; esac
    fi
    if _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT"; then _route_preexisting=1; else _route_preexisting=0; fi
    printf 'noresolv=%s\nroute_preexisting=%s\n' "$_noresolv" "$_route_preexisting" | _z2k_ow_doh_write "$Z2K_DOH_ROUTE_SNAPSHOT"
}
_z2k_ow_doh_has_route() {
    _route=$1
    _z2k_ow_doh_uci -q show dhcp 2>/dev/null | awk -F= -v key='dhcp.@dnsmasq[0].server' -v route="$_route" '
      $1==key {
        value=substr($0,index($0,"=")+1)
        gsub(/\047/," ",value)
        count=split(value,items,/[[:space:]]+/)
        for(i=1;i<=count;i++)if(items[i]==route)found=1
      }
      END{exit !found}'
}
_z2k_ow_doh_has_preexisting_route() {
    [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ] || return 1
    [ "$(sed -n 's/^route_preexisting=//p' "$Z2K_DOH_ROUTE_SNAPSHOT" | sed -n '1p')" = 1 ] || return 1
    _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT"
}
_z2k_ow_doh_switch_route() {
    _z2k_ow_doh_save_route || return 1
    if _z2k_ow_doh_old_owned; then
        if [ ! -f "$Z2K_DOH_LEGACY_ROUTE_TXN" ]; then
            _z2k_ow_doh_uci -q show dhcp 2>/dev/null | awk -F= '$1~/\.doh_(backup_)?server$/ {k=$1;sub(/\.doh_.*/,"",k);v=substr($0,index($0,"=")+1);gsub(/\047/,"",v);n=split(v,routes,/[[:space:]]+/);for(i=1;i<=n;i++)if(routes[i]!="")print k "|" routes[i]}' > "$Z2K_DOH_LEGACY_ROUTE_TXN"
        fi
        while IFS='|' read -r _key _route; do
            case "$_route" in 127.0.0.1\#*) _z2k_ow_doh_uci del_list "$_key.server=$_route" || return 1 ;; esac
        done < "$Z2K_DOH_LEGACY_ROUTE_TXN"
    fi
    _route_preexisting=$(sed -n 's/^route_preexisting=//p' "$Z2K_DOH_ROUTE_SNAPSHOT")
    if [ "$_route_preexisting" != 1 ]; then
        while _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT"; do
            _z2k_ow_doh_uci del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$Z2K_DOH_PORT" || return 1
        done
    fi
    _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT" || \
      _z2k_ow_doh_uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$Z2K_DOH_PORT" || return 1
    _z2k_ow_doh_uci set 'dhcp.@dnsmasq[0].noresolv=1' || return 1
    _z2k_ow_doh_uci commit dhcp || return 1
    "${Z2K_DOH_DNSMASQ_INIT}" restart || { _z2k_ow_doh_restore_configure_route; return 1; }
}
_z2k_ow_doh_restore_route() {
    [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ] || return 0
    _route_preexisting=$(sed -n 's/^route_preexisting=//p' "$Z2K_DOH_ROUTE_SNAPSHOT")
    if [ "$_route_preexisting" != 1 ]; then
        while _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT"; do
            _z2k_ow_doh_uci del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$Z2K_DOH_PORT" || return 1
        done
    fi
    if [ -s "$Z2K_DOH_LEGACY_ROUTE_TXN" ]; then
        while IFS='|' read -r _key _route; do
            [ -z "$_route" ] || _z2k_ow_doh_has_route "$_route" || _z2k_ow_doh_uci add_list "$_key.server=$_route" || return 1
        done < "$Z2K_DOH_LEGACY_ROUTE_TXN"
    fi
    _noresolv=$(sed -n 's/^noresolv=//p' "$Z2K_DOH_ROUTE_SNAPSHOT")
    case "$_noresolv" in __unset__|-1) _z2k_ow_doh_uci delete 'dhcp.@dnsmasq[0].noresolv' || return 1 ;; *) _z2k_ow_doh_uci set "dhcp.@dnsmasq[0].noresolv=$_noresolv" || return 1 ;; esac
    _z2k_ow_doh_uci commit dhcp || return 1
    "${Z2K_DOH_DNSMASQ_INIT}" restart || return 1
}
_z2k_ow_doh_restore_configure_route() {
    # Once migration is committed, a provider-change rollback must keep dnsmasq
    # on the still-owned dnsproxy route instead of restoring stopped legacy ports.
    [ -s "$Z2K_DOH_CONFIG_BASELINE" ] && return 0
    _z2k_ow_doh_restore_route
}
_z2k_ow_doh_rollback_migration() {
    _z2k_ow_doh_restore_legacy_service || return 1
    _z2k_ow_doh_restore_route || return 1
}
_z2k_ow_doh_save_legacy_service() {
    _z2k_ow_doh_old_owned && [ -x "$Z2K_DOH_OLD_INIT" ] || return 0
    [ -s "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" ] && return 0
    "$Z2K_DOH_OLD_INIT" enabled >/dev/null 2>&1 && _enabled=1 || _enabled=0
    "$Z2K_DOH_PIDOF_BIN" https_dns_proxy >/dev/null 2>&1 || \
      "$Z2K_DOH_PIDOF_BIN" https-dns-proxy >/dev/null 2>&1
    [ "$?" -eq 0 ] && _running=1 || _running=0
    printf 'enabled=%s\nrunning=%s\n' "$_enabled" "$_running" | _z2k_ow_doh_write "$Z2K_DOH_OLD_SERVICE_SNAPSHOT"
}
_z2k_ow_doh_restore_legacy_service() {
    _z2k_ow_doh_old_owned && [ -x "$Z2K_DOH_OLD_INIT" ] && [ -s "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" ] || return 0
    _enabled=$(sed -n 's/^enabled=//p' "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" | sed -n '1p')
    _running=$(sed -n 's/^running=//p' "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" | sed -n '1p')
    case "$_running" in 1) "$Z2K_DOH_OLD_INIT" restart || return 1 ;; 0) "$Z2K_DOH_OLD_INIT" stop || return 1 ;; *) return 1 ;; esac
    case "$_enabled" in 1) "$Z2K_DOH_OLD_INIT" enable ;; 0) "$Z2K_DOH_OLD_INIT" disable ;; *) return 1 ;; esac
}
_z2k_ow_doh_clear_legacy_markers() {
    _z2k_ow_doh_uci -q show dhcp 2>/dev/null | awk -F= '$1~/\.doh_(server|backup_server|backup_noresolv)$/ {print $1}' | while IFS= read -r _key; do _z2k_ow_doh_uci delete "$_key" || exit 1; done
    _z2k_ow_doh_uci commit dhcp
}
_z2k_ow_doh_exchange_error_count() {
    command -v logread >/dev/null 2>&1 || return 1
    logread 2>/dev/null | awk 'tolower($0) ~ /dnsproxy.*exchange failed/ { n++ } END { print n+0 }'
}
_z2k_ow_doh_direct_query() {
    _lookup=${Z2K_DOH_NSLOOKUP_BIN:-nslookup}
    _host=${Z2K_DOH_HEALTH_HOST:-example.com}
    _nonce=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    case "$_nonce" in ''|*[!0-9]*) _nonce="$(date +%s 2>/dev/null)-$$-${RANDOM:-0}" ;; esac
    _attempt=0
    while [ "$_attempt" -lt 3 ]; do
        _attempt=$((_attempt + 1))
        _probe_host="z2k-health-${_nonce}-${_attempt}-${RANDOM:-0}.$_host"
        _errors_before=$(_z2k_ow_doh_exchange_error_count 2>/dev/null) || _errors_before=
        _out=$("$_lookup" -timeout=2 -type=A "$_probe_host" "127.0.0.1:$Z2K_DOH_PORT" 2>&1) || _out=${_out:-}
        if printf '%s\n' "$_out" | grep -qi 'NXDOMAIN'; then return 0; fi
        if printf '%s\n' "$_out" | awk '/Address([[:space:]]+[0-9]+)?:[[:space:]]*/ {ip=$NF;if(ip~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/&&ip!="127.0.0.1")found=1} END{exit !found}'; then return 0; fi
        # BusyBox prints this marker for all empty NOERROR replies, including
        # dnsproxy's error response. Trust it only if no new exchange failure
        # appeared while issuing this cache-busting query.
        if printf '%s\n' "$_out" | grep -q 'Non-authoritative answer:' && [ -n "$_errors_before" ]; then
            _errors_after=$(_z2k_ow_doh_exchange_error_count 2>/dev/null) || _errors_after=
            case "$_errors_before:$_errors_after" in *[!0-9:]*) ;; *) [ "$_errors_before" = "$_errors_after" ] && return 0 ;; esac
        fi
        [ "$_attempt" -lt 3 ] && sleep 1
    done
    echo "Direct DNS probe failed after 3 attempts: $_out" >&2
    return 1
}
_z2k_ow_doh_configure() {
    _upstream=$1 _bootstrap=$2 _protocol=$3 _replace=$4 _fallbacks=${5:-} _routes=${6:-} _mode=${7:-}
    _cache_enabled=$(_z2k_ow_doh_get 'dnsproxy.cache.enabled') || _cache_enabled=0
    _cache_size=$(_z2k_ow_doh_get 'dnsproxy.cache.size') || _cache_size=65535
    case "$_cache_enabled" in 0|1) ;; *) _cache_enabled=1 ;; esac
    case "$_cache_size" in ''|*[!0-9]*) _cache_size=65535 ;; esac
    [ "$_cache_size" -ge 4096 ] 2>/dev/null && [ "$_cache_size" -le 1048576 ] 2>/dev/null || _cache_size=65535
    _z2k_ow_doh_external_config && [ "$_replace" != 1 ] && { echo 'DNS: найдена внешняя конфигурация dnsproxy; требуется подтверждение замены' >&2; return 1; }
    if _z2k_ow_doh_external_config && [ ! -s "$Z2K_DOH_CONFIG_BACKUP" ]; then
        _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BACKUP" || return 1
        _z2k_ow_doh_enabled && _was_enabled=1 || _was_enabled=0
        _z2k_ow_doh_running && _was_running=1 || _was_running=0
        printf 'enabled=%s\nrunning=%s\n' "$_was_enabled" "$_was_running" | _z2k_ow_doh_write "$Z2K_DOH_SERVICE_SNAPSHOT" || return 1
    fi
    for _section in global cache servers; do _z2k_ow_doh_uci delete "dnsproxy.$_section" >/dev/null 2>&1 || :; done
    _z2k_ow_doh_uci set 'dnsproxy.global=dnsproxy' || return 1
    _z2k_ow_doh_uci set 'dnsproxy.global.enabled=1' || return 1
    _z2k_ow_doh_uci add_list 'dnsproxy.global.listen_addr=127.0.0.1' || return 1
    _z2k_ow_doh_uci add_list "dnsproxy.global.listen_port=$Z2K_DOH_PORT" || return 1
    _z2k_ow_doh_uci set 'dnsproxy.global.insecure=0' || return 1
    # `https://` remains ordinary DoH. DoH3 is explicit in its `h3://`
    # endpoint; globally enabling HTTP/3 breaks providers that only serve TCP.
    _z2k_ow_doh_uci set 'dnsproxy.global.http3=0' || return 1
    [ -z "$_mode" ] || _z2k_ow_doh_uci set "dnsproxy.global.upstream_mode=$_mode" || return 1
    _z2k_ow_doh_uci set 'dnsproxy.cache=dnsproxy' || return 1
    _z2k_ow_doh_uci set "dnsproxy.cache.enabled=$_cache_enabled" || return 1
    _z2k_ow_doh_uci set "dnsproxy.cache.size=$_cache_size" || return 1
    _z2k_ow_doh_uci set 'dnsproxy.servers=dnsproxy' || return 1
    _z2k_ow_doh_uci delete 'dnsproxy.servers.upstream' >/dev/null 2>&1 || :
    _z2k_ow_doh_uci delete 'dnsproxy.servers.bootstrap' >/dev/null 2>&1 || :
    _z2k_ow_doh_uci delete 'dnsproxy.servers.fallback' >/dev/null 2>&1 || :
    printf '%s\n' "$_upstream" | while IFS= read -r _upstream_item; do [ -z "$_upstream_item" ] || _z2k_ow_doh_uci add_list "dnsproxy.servers.upstream=$_upstream_item" || exit 1; done || return 1
    printf '%s\n' "$_routes" | while IFS= read -r _route; do
        [ -z "$_route" ] && continue
        _domain=${_route%%=*}; _endpoint=${_route#*=}
        _z2k_ow_doh_uci add_list "dnsproxy.servers.upstream=[/$_domain/]$_endpoint" || exit 1
    done || return 1
    printf '%s\n' "$_fallbacks" | while IFS= read -r _fallback; do [ -z "$_fallback" ] || _z2k_ow_doh_uci add_list "dnsproxy.servers.fallback=$_fallback" || exit 1; done || return 1
    printf '%s\n' "$_bootstrap" | tr ',' '\n' | while IFS= read -r _ip; do [ -z "$_ip" ] || _z2k_ow_doh_uci add_list "dnsproxy.servers.bootstrap=$_ip" || exit 1; done || return 1
    _z2k_ow_doh_uci commit dnsproxy || return 1
    printf '%s\n' global cache servers | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_OWNED_FILE" || return 1
    printf '%s\n' "$_protocol" > "$Z2K_DOH_PROFILE_FILE" || return 1
    "$Z2K_DOH_PROXY_INIT" enable || return 1
    "$Z2K_DOH_PROXY_INIT" restart || return 1
    _z2k_ow_doh_running || { echo 'DNS: dnsproxy не запустился' >&2; return 1; }
    _z2k_ow_doh_direct_query || { echo 'DNS: upstream не подтвердил прямой DNS-ответ; маршрут не переключён' >&2; return 1; }
    _z2k_ow_doh_switch_route || return 1
    _z2k_ow_doh_lookup_answer >/dev/null || { _z2k_ow_doh_restore_configure_route; return 1; }
    # Do not stop https-dns-proxy unless z2kOW owns it and the cutover succeeded.
    if _z2k_ow_doh_old_owned && [ -x "$Z2K_DOH_OLD_INIT" ]; then
        _z2k_ow_doh_save_legacy_service || { _z2k_ow_doh_rollback_migration; return 1; }
        "$Z2K_DOH_OLD_INIT" disable && "$Z2K_DOH_OLD_INIT" stop || {
            _z2k_ow_doh_rollback_migration >/dev/null 2>&1 || :
            return 1
        }
        _z2k_ow_doh_clear_legacy_markers || { _z2k_ow_doh_rollback_migration; return 1; }
        # https-dns-proxy restores its saved dnsmasq servers while stopping; reclaim the route after it exits.
        _z2k_ow_doh_switch_route || { _z2k_ow_doh_rollback_migration >/dev/null 2>&1 || :; return 1; }
        _z2k_ow_doh_lookup_answer >/dev/null || { _z2k_ow_doh_rollback_migration >/dev/null 2>&1 || :; return 1; }
    fi
    _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BASELINE" || {
        _z2k_ow_doh_rollback_migration
        return 1
    }
    rm -f "$Z2K_DOH_SERVICE_SNAPSHOT" "$Z2K_DOH_PREINSTALL_CONFIG_MARKER"
    [ -s "$Z2K_DOH_CONFIG_BACKUP" ] || rm -f "$Z2K_DOH_CONFIG_BACKUP"
}

_z2k_ow_doh_cache_size_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 4096 ] 2>/dev/null && [ "$1" -le 1048576 ] 2>/dev/null
}
z2k_ow_doh_set_cache() {
    _enabled=$1 _size=${2:-65535}
    case "$_enabled" in 0|1) ;; *) echo 'DNS: cache_enabled должен быть 0 или 1' >&2; return 1 ;; esac
    _z2k_ow_doh_cache_size_valid "$_size" || { echo 'DNS: cache_size должен быть от 4096 до 1048576 байт' >&2; return 1; }
    _z2k_ow_doh_installed || return 1
    _z2k_ow_doh_external_config && { echo 'DNS: внешняя конфигурация dnsproxy требует явной замены через provider API' >&2; return 1; }
    _old_enabled=$(_z2k_ow_doh_get 'dnsproxy.cache.enabled') || _old_enabled=1
    _old_size=$(_z2k_ow_doh_get 'dnsproxy.cache.size') || _old_size=65535
    case "$_old_enabled" in 0|1) ;; *) _old_enabled=1 ;; esac
    _z2k_ow_doh_cache_size_valid "$_old_size" || _old_size=65535
    _was_running=0; _z2k_ow_doh_running && _was_running=1
    _z2k_ow_doh_uci set 'dnsproxy.cache=dnsproxy' && \
      _z2k_ow_doh_uci set "dnsproxy.cache.enabled=$_enabled" && \
      _z2k_ow_doh_uci set "dnsproxy.cache.size=$_size" && \
      _z2k_ow_doh_uci commit dnsproxy || return 1
    if [ "$_was_running" = 1 ]; then
        "$Z2K_DOH_PROXY_INIT" restart && _z2k_ow_doh_direct_query || {
            _z2k_ow_doh_uci set "dnsproxy.cache.enabled=$_old_enabled" >/dev/null 2>&1 || :
            _z2k_ow_doh_uci set "dnsproxy.cache.size=$_old_size" >/dev/null 2>&1 || :
            _z2k_ow_doh_uci commit dnsproxy >/dev/null 2>&1 || :
            "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || :
            echo 'DNS: кэш не применён; восстановлена предыдущая конфигурация' >&2
            return 1
        }
    fi
    _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BASELINE" || return 1
    return 0
}

_z2k_ow_doh_redirect_get() { _z2k_ow_doh_get "firewall.z2kow_dns_redirect.$1"; }
_z2k_ow_doh_lan_ipv4() {
    _lan=$(_z2k_ow_doh_get network.lan.ipaddr) || return 1
    _lan=${_lan%%/*}
    printf '%s\n' "$_lan" | awk -F. 'NF==4 {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i+0>255||$i=="")exit 1;ok=1} END{exit !ok}' || return 1
    printf '%s\n' "$_lan"
}
_z2k_ow_doh_redirect_matches() {
    [ "$( _z2k_ow_doh_redirect_get name )" = 'z2kOW DNS redirect' ] &&
    [ "$( _z2k_ow_doh_redirect_get src )" = lan ] &&
    [ "$( _z2k_ow_doh_redirect_get proto )" = 'tcp udp' ] &&
    [ "$( _z2k_ow_doh_redirect_get src_dport )" = 53 ] &&
    [ "$( _z2k_ow_doh_redirect_get dest )" = lan ] &&
    [ "$( _z2k_ow_doh_redirect_get dest_ip )" = "$_redirect_ip" ] &&
    [ "$( _z2k_ow_doh_redirect_get dest_port )" = 53 ] &&
    [ "$( _z2k_ow_doh_redirect_get target )" = DNAT ] &&
    [ "$( _z2k_ow_doh_redirect_get family )" = ipv4 ]
}
_z2k_ow_doh_redirect_reload() {
    _z2k_ow_doh_uci commit firewall || return 1
    "$Z2K_DOH_FW4_BIN" -q check || return 1
    "$Z2K_DOH_FIREWALL_INIT" reload
}
z2k_ow_doh_set_force_dns() {
    _enable=${1:-0}
    case "$_enable" in 0|1) ;; *) echo 'DNS: force_lan_dns должен быть 0 или 1' >&2; return 1 ;; esac
    if [ "$_enable" = 1 ]; then
        _z2k_ow_doh_installed || { echo 'DNS: сначала установите dnsproxy' >&2; return 1; }
        _redirect_ip=$(_z2k_ow_doh_lan_ipv4) || { echo 'DNS: не удалось определить IPv4 адрес LAN' >&2; return 1; }
        if [ -s "$Z2K_DOH_REDIRECT_MARKER" ]; then
            _z2k_ow_doh_redirect_matches || { echo 'DNS: owned redirect изменён вручную; отказ от перезаписи' >&2; return 1; }
            return 0
        fi
        if _z2k_ow_doh_get firewall.z2kow_dns_redirect >/dev/null 2>&1; then
            echo 'DNS: секция firewall.z2kow_dns_redirect занята; отказ от перезаписи' >&2; return 1
        fi
        printf 'redirect_ip=%s\n' "$_redirect_ip" | _z2k_ow_doh_write "$Z2K_DOH_REDIRECT_MARKER" || return 1
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect=redirect' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.name=z2kOW DNS redirect' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.src=lan' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.dest=lan' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.proto=tcp udp' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.src_dport=53' && \
          _z2k_ow_doh_uci set "firewall.z2kow_dns_redirect.dest_ip=$_redirect_ip" && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.dest_port=53' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.target=DNAT' && \
          _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.family=ipv4' || {
            _z2k_ow_doh_uci delete firewall.z2kow_dns_redirect >/dev/null 2>&1 || :
            rm -f "$Z2K_DOH_REDIRECT_MARKER"
            return 1
          }
        _z2k_ow_doh_redirect_reload || {
            _z2k_ow_doh_uci delete firewall.z2kow_dns_redirect >/dev/null 2>&1 || :
            _z2k_ow_doh_uci commit firewall >/dev/null 2>&1 || :
            "$Z2K_DOH_FW4_BIN" -q check >/dev/null 2>&1 && "$Z2K_DOH_FIREWALL_INIT" reload >/dev/null 2>&1 || :
            rm -f "$Z2K_DOH_REDIRECT_MARKER"
            return 1
        }
        return 0
    fi
    [ -s "$Z2K_DOH_REDIRECT_MARKER" ] || return 0
    _redirect_ip=$(sed -n 's/^redirect_ip=//p' "$Z2K_DOH_REDIRECT_MARKER" | sed -n '1p')
    _z2k_ow_doh_redirect_matches || { echo 'DNS: owned redirect изменён вручную; сохранён для ручной проверки' >&2; return 1; }
    _z2k_ow_doh_uci delete firewall.z2kow_dns_redirect || return 1
    _z2k_ow_doh_redirect_reload || {
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect=redirect' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.name=z2kOW DNS redirect' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.src=lan' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.dest=lan' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.proto=tcp udp' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.src_dport=53' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set "firewall.z2kow_dns_redirect.dest_ip=$_redirect_ip" >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.dest_port=53' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.target=DNAT' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci set 'firewall.z2kow_dns_redirect.family=ipv4' >/dev/null 2>&1 || :
        _z2k_ow_doh_uci commit firewall >/dev/null 2>&1 || :
        "$Z2K_DOH_FIREWALL_INIT" reload >/dev/null 2>&1 || :
        return 1
    }
    rm -f "$Z2K_DOH_REDIRECT_MARKER"
}

z2k_ow_doh_install() {
    mkdir -p "$_Z2K_DOH_DIR" || return 1
    if _z2k_ow_doh_installed; then echo 'dnsproxy уже установлен'; return 0; fi
    _preinstall=$(_z2k_ow_doh_export)
    if [ -n "$_preinstall" ]; then
        printf '%s\n' "$_preinstall" | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BACKUP" || return 1
        printf 'present=1\n' | _z2k_ow_doh_write "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" || return 1
    fi
    # Preserve the old package configuration before adding anything; leave its service untouched.
    if "$Z2K_DOH_APK_BIN" info -e https-dns-proxy >/dev/null 2>&1; then
        _old=$(_z2k_ow_doh_uci -q export https-dns-proxy 2>/dev/null)
        printf '%s\n' "$_old" | _z2k_ow_doh_write "$Z2K_DOH_OLD_BACKUP" || return 1
        _old_urls=$(printf '%s\n' "$_old" | awk '{v="";if(($1=="option"||$1=="list")&&$2=="resolver_url")v=$3;else{key=$0;sub(/=.*/,"",key);if(key~/\.resolver_url$/){v=substr($0,index($0,"=")+1)}}gsub(/\047/,"",v);if(v!="")print v}')
        _old_bootstrap=$(printf '%s\n' "$_old" | awk '{v="";if(($1=="option"||$1=="list")&&$2=="bootstrap_dns")v=$3;else{key=$0;sub(/=.*/,"",key);if(key~/\.bootstrap_dns$/)v=substr($0,index($0,"=")+1)}gsub(/\047/,"",v);if(v!=""){gsub(/,/," ",v);n=split(v,a," ");for(i=1;i<=n;i++)if(a[i]!=""){printf "%s%s",sep,a[i];sep=","}}}END{if(sep!="")print ""}')
        case "$_old_urls" in https://*)
            {
                printf 'protocol=doh\n'
                printf '%s\n' "$_old_urls" | while IFS= read -r _old_endpoint; do
                    [ -z "$_old_endpoint" ] || printf 'endpoint=%s\n' "$_old_endpoint"
                done
                printf 'bootstrap=%s\n' "$_old_bootstrap"
            } | _z2k_ow_doh_write "$Z2K_DOH_INSTALL_SNAPSHOT" || return 1
            ;;
        esac
    fi
    _z2k_ow_doh_progress 'устанавливаю dnsproxy из системного репозитория apk'
    "$Z2K_DOH_APK_BIN" add dnsproxy || return 1
    _z2k_ow_doh_installed || return 1
    printf 'dnsproxy\n' | _z2k_ow_doh_write "$Z2K_DOH_PACKAGE_OWNED_FILE"
    [ -s "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" ] || _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BASELINE"
    if _z2k_ow_doh_old_owned && [ -s "$Z2K_DOH_INSTALL_SNAPSHOT" ]; then
        _old_urls=$(sed -n 's/^endpoint=//p' "$Z2K_DOH_INSTALL_SNAPSHOT")
        _old_bootstrap=$(sed -n 's/^bootstrap=//p' "$Z2K_DOH_INSTALL_SNAPSHOT" | sed -n '1p')
        if [ -n "$_old_bootstrap" ]; then
            _z2k_ow_doh_progress 'переношу owned DoH профиль, проверяю dnsproxy и переключаю dnsmasq'
            z2k_ow_doh_apply_profile "$_old_urls" '' '' load_balance "$_old_bootstrap" 0 || return 1
            rm -f "$Z2K_DOH_INSTALL_SNAPSHOT"
        else
            echo 'dnsproxy установлен; старый DNS оставлен рабочим: для безопасной миграции нужен явный bootstrap IP'
        fi
    fi
}
z2k_ow_doh_select_provider() {
    _provider=$1 _endpoint=${2:-} _bootstrap=${3:-} _replace=${4:-0} _protocol=${5:-doh}
    case "$_protocol" in doh|doh3|dot|doq|dnscrypt) ;; *) echo 'DNS: неподдерживаемый protocol' >&2; return 1 ;; esac
    z2k_ow_doh_provider_protocol_valid "$_provider" "$_protocol" "$_endpoint" || { echo 'DNS: provider не поддерживает выбранный protocol или endpoint' >&2; return 1; }
    if [ "$_provider" = custom ]; then _upstream=$_endpoint; Z2K_DOH_PROVIDER_LABEL='Пользовательский сервер'
    else
        if [ "$_provider" = quad9 ] && [ "$_protocol" != doh ]; then
            Z2K_DOH_PROVIDER_LABEL='Quad9'
            Z2K_DOH_BOOTSTRAP=${_bootstrap:-$Z2K_DOH_DEFAULT_BOOTSTRAP}
            case "$_protocol" in
                doh3) Z2K_DOH_ENDPOINT=h3://dns.quad9.net/dns-query ;;
                dot) Z2K_DOH_ENDPOINT=tls://dns.quad9.net ;;
                doq) Z2K_DOH_ENDPOINT=quic://dns.quad9.net:853 ;;
                dnscrypt) Z2K_DOH_ENDPOINT=sdns://AQMAAAAAAAAADDkuOS45Ljk6ODQ0MyBnyEe4yHWM0SAkVUO-dWdG3zTfHYTAC4xHA2jfgh2GPhkyLmRuc2NyeXB0LWNlcnQucXVhZDkubmV0 ;;
            esac
        else
            [ "$_protocol" = doh ] || { echo 'DNS: текущие preset-серверы подтверждены только для DoH' >&2; return 1; }
        fi
        [ -n "${Z2K_DOH_ENDPOINT:-}" ] || _z2k_ow_doh_preset "$_provider" || { echo 'DNS: неизвестный provider' >&2; return 1; }
        _upstream=$Z2K_DOH_ENDPOINT; [ -z "$_bootstrap" ] && _bootstrap=$Z2K_DOH_BOOTSTRAP
    fi
    _upstream_items=$(printf '%s' "$_upstream" | tr ',' ' ')
    for _upstream_item in $_upstream_items; do
        _z2k_ow_doh_valid_upstream "$_upstream_item" && _z2k_ow_doh_protocol_scheme "$_protocol" "$_upstream_item" || { echo 'DNS: endpoint не соответствует выбранному protocol' >&2; return 1; }
        case "$_upstream_item" in
            sdns://*) : ;; # Address is carried by the DNSCrypt stamp.
            *://*)
                _authority=$(printf %s "$_upstream_item" | sed -E 's,^[a-z0-9]+://([^/?#]*).*,\1,')
                case "$_authority" in \[*\]*) _host=${_authority#\[}; _host=${_host%%\]*} ;; *) _host=${_authority%%:*} ;; esac
                _z2k_ow_doh_is_ip "$_host" || [ -n "$_bootstrap" ] || { echo 'DNS: для hostname upstream требуется явный bootstrap DNS' >&2; return 1; } ;;
        esac
    done
    [ -z "$_bootstrap" ] || _z2k_ow_doh_valid_bootstrap "$_bootstrap" || { echo 'DNS: bootstrap должен содержать IP-адреса' >&2; return 1; }
    _z2k_ow_doh_installed || { echo 'DNS: сначала установите dnsproxy' >&2; return 1; }
    mkdir -p "$_Z2K_DOH_DIR" || return 1
    _tx=$Z2K_DOH_CONFIG_BACKUP.txn
    _z2k_ow_doh_export | _z2k_ow_doh_write "$_tx" || return 1
    _z2k_ow_doh_enabled && _was_enabled=1 || _was_enabled=0
    _z2k_ow_doh_running && _was_running=1 || _was_running=0
    _z2k_ow_doh_configure "$_upstream" "$_bootstrap" "$_protocol" "$_replace" || {
        if [ -s "$_tx" ]; then _z2k_ow_doh_uci -q import dnsproxy < "$_tx" || :; else
            for _section in $(_z2k_ow_doh_sections); do _z2k_ow_doh_uci delete "dnsproxy.$_section" || :; done
        fi
        _z2k_ow_doh_uci commit dnsproxy >/dev/null 2>&1 || :
        if [ "$_was_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || :; fi
        if [ "$_was_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || :; fi
        rm -f "$_tx"
        return 1
    }
    printf 'protocol=%s\nprovider=%s\nendpoint=%s\nbootstrap=%s\n' "$_protocol" "$_provider" "$_upstream" "$_bootstrap" | _z2k_ow_doh_write "$Z2K_DOH_STATE_FILE" || {
        _z2k_ow_doh_rollback_migration
        if [ -s "$_tx" ]; then _z2k_ow_doh_uci -q import dnsproxy < "$_tx" || :; else
            for _section in $(_z2k_ow_doh_sections); do _z2k_ow_doh_uci delete "dnsproxy.$_section" || :; done
        fi
        _z2k_ow_doh_uci commit dnsproxy >/dev/null 2>&1 || :
        if [ "$_was_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || :; fi
        if [ "$_was_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || :; fi
        rm -f "$_tx"
        return 1
    }
        rm -f "$_tx"
    echo "DNS настроен: $Z2K_DOH_PROVIDER_LABEL"
}
z2k_ow_doh_apply_profile() {
    _upstreams=$1 _fallbacks=${2:-} _routes=${3:-} _mode=${4:-} _bootstrap=${5:-} _replace=${6:-0}
    case "$_mode" in load_balance|parallel|fastest_addr) ;; *) echo 'DNS: неподдерживаемый upstream mode' >&2; return 1 ;; esac
    case "$_replace" in 0|1) ;; *) return 1 ;; esac
    _upstreams=$(printf '%s\n' "$_upstreams" | sed '/^[[:space:]]*$/d')
    [ -n "$_upstreams" ] || { echo 'DNS: требуется хотя бы один upstream' >&2; return 1; }
    _profile_bootstrap=$(printf '%s\n' "$_bootstrap" | tr ',' '\n' | sed '/^$/d')
    _bootstrap=$(printf '%s\n' "$_profile_bootstrap" | tr '\n' ',' | sed 's/,$//')
    [ -z "$_bootstrap" ] || _z2k_ow_doh_valid_bootstrap "$_bootstrap" || { echo 'DNS: bootstrap должен содержать IP-адреса' >&2; return 1; }
    _z2k_ow_doh_profile_list "$_upstreams" "$_bootstrap" 1 || { echo 'DNS: некорректный защищённый upstream' >&2; return 1; }
    _z2k_ow_doh_profile_list "$_fallbacks" "$_bootstrap" 0 || { echo 'DNS: fallback должен использовать защищённый upstream' >&2; return 1; }
    _route_upstreams=
    while IFS= read -r _route; do
        [ -n "$_route" ] || continue
        case "$_route" in *=*) _domain=${_route%%=*}; _route_endpoint=${_route#*=} ;; *) return 1 ;; esac
        _z2k_ow_doh_valid_domain "$_domain" && _z2k_ow_doh_profile_endpoint "$_route_endpoint" "$_bootstrap" || { echo 'DNS: некорректный domain route' >&2; return 1; }
        _route_upstreams="${_route_upstreams}${_route_upstreams:+
}$_route_endpoint"
    done <<EOF
$_routes
EOF
    _profile_upstreams_b64=$(_z2k_ow_doh_base64_encode "$_upstreams") || return 1
    _profile_fallbacks_b64=$(_z2k_ow_doh_base64_encode "$_fallbacks") || return 1
    _profile_routes_b64=$(_z2k_ow_doh_base64_encode "$_routes") || return 1
    _profile_bootstrap_b64=$(_z2k_ow_doh_base64_encode "$_profile_bootstrap") || return 1
    _z2k_ow_doh_installed || { echo 'DNS: сначала установите dnsproxy' >&2; return 1; }
    mkdir -p "$_Z2K_DOH_DIR" || return 1
    _tx=$Z2K_DOH_CONFIG_BACKUP.txn
    _z2k_ow_doh_export | _z2k_ow_doh_write "$_tx" || return 1
    _z2k_ow_doh_enabled && _was_enabled=1 || _was_enabled=0
    _z2k_ow_doh_running && _was_running=1 || _was_running=0
    _all_upstreams=$_upstreams
    [ -z "$_route_upstreams" ] || _all_upstreams="$_all_upstreams
$_route_upstreams"
    _protocol=unknown
    _protocols=
    while IFS= read -r _item; do
        case "$_item" in https://*) _item_protocol=doh ;; h3://*) _item_protocol=doh3 ;; tls://*) _item_protocol=dot ;; quic://*) _item_protocol=doq ;; sdns://*) _item_protocol=dnscrypt ;; esac
        case "$_protocols" in *" $_item_protocol "*) ;; *) _protocols="$_protocols $_item_protocol " ;; esac
    done <<EOF
$_all_upstreams
$_fallbacks
EOF
    set -- $_protocols
    [ "$#" -eq 1 ] && _protocol=$1
    _z2k_ow_doh_configure "$_upstreams" "$_bootstrap" "$_protocol" "$_replace" "$_fallbacks" "$_routes" "$_mode" || {
        if [ -s "$_tx" ]; then _z2k_ow_doh_uci -q import dnsproxy < "$_tx" || :; else
            for _section in $(_z2k_ow_doh_sections); do _z2k_ow_doh_uci delete "dnsproxy.$_section" || :; done
        fi
        _z2k_ow_doh_uci commit dnsproxy >/dev/null 2>&1 || :
        if [ "$_was_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || :; fi
        if [ "$_was_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || :; fi
        rm -f "$_tx"
        return 1
    }
    _endpoint=$(printf '%s\n' "$_upstreams" | sed -n '1p')
    printf 'protocol=%s\nprovider=profile\nendpoint=%s\nbootstrap=%s\nmode=%s\nprofile_upstreams_b64=%s\nprofile_fallbacks_b64=%s\nprofile_routes_b64=%s\nprofile_bootstrap_b64=%s\n' \
      "$_protocol" "$_endpoint" "$_bootstrap" "$_mode" "$_profile_upstreams_b64" "$_profile_fallbacks_b64" "$_profile_routes_b64" "$_profile_bootstrap_b64" | _z2k_ow_doh_write "$Z2K_DOH_STATE_FILE" || {
        _z2k_ow_doh_rollback_migration >/dev/null 2>&1 || :
        if [ -s "$_tx" ]; then _z2k_ow_doh_uci -q import dnsproxy < "$_tx" || :; fi
        _z2k_ow_doh_uci commit dnsproxy >/dev/null 2>&1 || :
        if [ "$_was_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || :; fi
        if [ "$_was_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart >/dev/null 2>&1 || :; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || :; fi
        rm -f "$_tx"
        return 1
    }
    rm -f "$_tx"
}
_z2k_ow_doh_lookup_answer() {
    _lookup=${Z2K_DOH_NSLOOKUP_BIN:-nslookup}; _host=${Z2K_DOH_HEALTH_HOST:-example.com}
    _attempt=0
    while [ "$_attempt" -lt 5 ]; do
        _attempt=$((_attempt + 1))
        _out=$("$_lookup" "$_host" 127.0.0.1 2>&1) || _out=${_out:-}
        _answer=$(printf '%s\n' "$_out" | awk '/Address([[:space:]]+[0-9]+)?:[[:space:]]*/ {ip=$NF;if(ip~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/&&ip!="127.0.0.1"){print ip;found=1}} END{exit !found}') && { printf '%s\n' "$_answer"; return 0; }
        [ "$_attempt" -lt 5 ] && sleep 1
    done
    echo "DNS lookup failed after 5 attempts: $_out" >&2
    return 1
}
z2k_ow_doh_status() {
    _state=not-installed _installed=0 _running=0 _enabled=0 _provider=unknown _endpoint= _bootstrap= _protocol=unknown _actual_protocol=unknown _local_dns=unknown _upstream_state=unconfirmed _external=0 _owner=none _force=0 _proxy=unavailable _dnsmasq=unavailable _reason= _confirmed=0 _confirm_remove=0 _migration_available=0 _legacy_endpoint= _legacy_bootstrap= _route_snapshot=0 _cache_enabled=unknown _cache_size=unknown _redirect_state=disabled _redirect_snapshot=0 _configured_protocol= _profile_upstreams_b64= _profile_fallbacks_b64= _profile_routes_b64= _profile_bootstrap_b64= _profile_mode=
    if _z2k_ow_doh_installed; then
        [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ] && _route_snapshot=1
        [ -s "$Z2K_DOH_REDIRECT_MARKER" ] && _redirect_snapshot=1
        _cache_enabled=$(_z2k_ow_doh_get dnsproxy.cache.enabled) || _cache_enabled=0
        _cache_size=$(_z2k_ow_doh_get dnsproxy.cache.size) || _cache_size=65535
        case "$_cache_enabled" in 0|1) ;; *) _cache_enabled=unknown ;; esac
        _z2k_ow_doh_cache_size_valid "$_cache_size" || _cache_size=unknown
        if [ "$_redirect_snapshot" = 1 ]; then
            _redirect_ip=$(sed -n 's/^redirect_ip=//p' "$Z2K_DOH_REDIRECT_MARKER" | sed -n '1p')
            if _z2k_ow_doh_redirect_matches && "$Z2K_DOH_FW4_BIN" -q check >/dev/null 2>&1; then _redirect_state=active; _force=1
            else _redirect_state=drift; fi
        elif _z2k_ow_doh_get firewall.z2kow_dns_redirect >/dev/null 2>&1; then _redirect_state=unowned-conflict
        fi
        _installed=1; _owner=external; [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && _owner=z2kow
        _z2k_ow_doh_running && _running=1; _z2k_ow_doh_enabled && _enabled=1
        [ "$_running" = 1 ] && _proxy=available
        _z2k_ow_doh_external_config && _external=1
        [ "$_external" = 0 ] || _confirm_remove=1
        [ ! -s "$Z2K_DOH_CONFIG_BACKUP" ] || _confirm_remove=1
        if [ -s "$Z2K_DOH_STATE_FILE" ]; then
            _protocol=$(sed -n 's/^protocol=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _provider=$(sed -n 's/^provider=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _endpoint=$(sed -n 's/^endpoint=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _bootstrap=$(sed -n 's/^bootstrap=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _profile_upstreams_b64=$(sed -n 's/^profile_upstreams_b64=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _profile_fallbacks_b64=$(sed -n 's/^profile_fallbacks_b64=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _profile_routes_b64=$(sed -n 's/^profile_routes_b64=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _profile_bootstrap_b64=$(sed -n 's/^profile_bootstrap_b64=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
            _profile_mode=$(sed -n 's/^mode=//p' "$Z2K_DOH_STATE_FILE" | sed -n '1p')
        else
            _upstreams=$(_z2k_ow_doh_server_values); _endpoint=$(printf '%s\n' "$_upstreams" | sed -n '1p')
            case "$_endpoint" in h3://*) _protocol=doh3 ;; tls://*) _protocol=dot ;; quic://*) _protocol=doq ;; sdns://*) _protocol=dnscrypt ;; https://*) _protocol=doh ;; esac
            _provider=custom
        fi
        if [ -s "$Z2K_DOH_INSTALL_SNAPSHOT" ]; then
            _legacy_endpoint=$(sed -n 's/^endpoint=//p' "$Z2K_DOH_INSTALL_SNAPSHOT" | sed -n '1p')
            _legacy_bootstrap=$(sed -n 's/^bootstrap=//p' "$Z2K_DOH_INSTALL_SNAPSHOT" | sed -n '1p')
            [ -z "$_legacy_endpoint" ] || _migration_available=1
        fi
        _configured_protocol=$(_z2k_ow_doh_configured_protocol) || _configured_protocol=
        [ -n "$_configured_protocol" ] && _protocol=$_configured_protocol || _protocol=unknown
        if [ -n "$_endpoint" ] && [ "$_running" = 1 ] && _z2k_ow_doh_direct_query; then
            _confirmed=1; _upstream_state=confirmed
            [ -z "$_configured_protocol" ] || _actual_protocol=$_configured_protocol
        else [ -z "$_endpoint" ] || _upstream_state=failed; fi
        if [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ] && _z2k_ow_doh_has_route "127.0.0.1#$Z2K_DOH_PORT"; then _dnsmasq=available; else _dnsmasq=route-missing; fi
        if [ "$_dnsmasq" = available ] && _z2k_ow_doh_lookup_answer >/dev/null 2>&1; then _local_dns=working; else [ -n "$_endpoint" ] && _local_dns=failed; fi
        if [ -z "$_endpoint" ]; then _state=disabled; _reason=resolver-config-missing
        elif [ "$_running" = 1 ] && [ "$_confirmed" = 1 ] && [ "$_local_dns" = working ]; then _state=working
        elif [ "$_running" = 1 ] && [ "$_confirmed" = 1 ]; then _state=error; _reason=dnsmasq-not-routing
        elif [ "$_running" = 1 ]; then _state=unverified; _reason=upstream-unconfirmed
        elif [ "$_enabled" = 1 ]; then _state=error; _reason=proxy-not-running
        else _state=disabled; fi
    fi
    printf 'state=%s installed=%s enabled=%s running=%s provider=%s endpoint=%s bootstrap=%s protocol=%s actual_protocol=%s local_dns_state=%s upstream_state=%s upstream_confirmed=%s migration_available=%s legacy_endpoint=%s legacy_bootstrap=%s route_snapshot=%s cache_enabled=%s cache_size=%s upstream_family=unsupported force_lan_dns=%s redirect_state=%s redirect_snapshot=%s redirect_family=ipv4 package_owner=%s external_config=%s confirm_remove=%s proxy=%s dnsmasq=%s reason=%s profile_upstreams_b64=%s profile_fallbacks_b64=%s profile_routes_b64=%s profile_bootstrap_b64=%s profile_mode=%s\n' \
      "$_state" "$_installed" "$_enabled" "$_running" "$_provider" "$_endpoint" "$_bootstrap" "$_protocol" "$_actual_protocol" "$_local_dns" "$_upstream_state" "$_confirmed" "$_migration_available" "$_legacy_endpoint" "$_legacy_bootstrap" "$_route_snapshot" "$_cache_enabled" "$_cache_size" "$_force" "$_redirect_state" "$_redirect_snapshot" "$_owner" "$_external" "$_confirm_remove" "$_proxy" "$_dnsmasq" "$_reason" "$_profile_upstreams_b64" "$_profile_fallbacks_b64" "$_profile_routes_b64" "$_profile_bootstrap_b64" "$_profile_mode"
}
z2k_ow_doh_enable() {
    _z2k_ow_doh_installed && "$Z2K_DOH_PROXY_INIT" enable && "$Z2K_DOH_PROXY_INIT" restart && \
      _z2k_ow_doh_direct_query && _z2k_ow_doh_switch_route || return 1
    _z2k_ow_doh_lookup_answer || { _z2k_ow_doh_rollback_migration; return 1; }
    if _z2k_ow_doh_old_owned && [ -x "$Z2K_DOH_OLD_INIT" ]; then
        _z2k_ow_doh_save_legacy_service || { _z2k_ow_doh_rollback_migration; return 1; }
        "$Z2K_DOH_OLD_INIT" disable && "$Z2K_DOH_OLD_INIT" stop || { _z2k_ow_doh_rollback_migration; return 1; }
        _z2k_ow_doh_clear_legacy_markers || { _z2k_ow_doh_rollback_migration; return 1; }
    fi
}
z2k_ow_doh_disable() {
    if _z2k_ow_doh_has_preexisting_route; then
        echo 'DNS: сохранён предварительно настроенный маршрут на dnsproxy; отключение заблокировано, чтобы не оставить его без resolver' >&2
        return 1
    fi
    _z2k_ow_doh_restore_legacy_service && _z2k_ow_doh_restore_route && \
      "$Z2K_DOH_PROXY_INIT" disable && "$Z2K_DOH_PROXY_INIT" stop
}
z2k_ow_doh_restart() { _z2k_ow_doh_installed && "$Z2K_DOH_PROXY_INIT" restart && _z2k_ow_doh_direct_query; }
z2k_ow_doh_check() {
    _status=$(z2k_ow_doh_status) || return 1
    printf '%s\n' "$_status"
    case " $_status " in *'state=working '* ) return 0 ;; *) return 1 ;; esac
}
z2k_ow_doh_diagnostics() {
    _status=$(z2k_ow_doh_status) || return 1
    printf '%s\n' "$_status"
    _z2k_ow_doh_installed || { printf 'diagnostic=package-missing\n'; return 1; }
    _diag_rc=0
    if _z2k_ow_doh_running; then printf 'dnsproxy_service=running\n'; else printf 'dnsproxy_service=stopped\n'; fi
    if _z2k_ow_doh_direct_query; then printf 'dnsproxy_direct_probe=working\n'; else printf 'dnsproxy_direct_probe=failed\n'; _diag_rc=1; fi
    case "$_status" in *'dnsmasq=available '*)
        if _z2k_ow_doh_lookup_answer >/dev/null 2>&1; then printf 'dnsmasq_probe=working\n'; else printf 'dnsmasq_probe=failed\n'; _diag_rc=1; fi ;;
      *) printf 'dnsmasq_probe=route-missing\n'; _diag_rc=1 ;;
    esac
    case "$_status" in *'redirect_state=active '*) printf 'lan_redirect=active\n' ;; *) printf 'lan_redirect=inactive-or-drift\n' ;; esac
    return "$_diag_rc"
}
z2k_ow_doh_recover() {
    _z2k_ow_doh_installed || { echo 'DNS: dnsproxy не установлен' >&2; return 1; }
    _z2k_ow_doh_enabled || "$Z2K_DOH_PROXY_INIT" enable || return 1
    "$Z2K_DOH_PROXY_INIT" restart || return 1
    _z2k_ow_doh_running && _z2k_ow_doh_direct_query || { echo 'DNS: direct upstream probe failed; dnsmasq route was not changed' >&2; return 1; }
    if [ -s "$Z2K_DOH_ROUTE_SNAPSHOT" ]; then
        _z2k_ow_doh_switch_route || return 1
        _z2k_ow_doh_lookup_answer >/dev/null || { _z2k_ow_doh_restore_route; echo 'DNS: dnsmasq recovery check failed; previous route restored' >&2; return 1; }
    fi
    z2k_ow_doh_diagnostics
}
z2k_ow_doh_uninstall() {
    z2k_ow_doh_set_force_dns 0 || return 1
    _z2k_ow_doh_installed || return 0
    if [ ! -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ]; then echo 'DNS: dnsproxy is externally owned; refusing package removal' >&2; return 1; fi
    if [ -s "$Z2K_DOH_CONFIG_BACKUP" ] && [ "${1:-0}" != 1 ]; then echo 'DNS: пользовательская конфигурация сохранена; подтвердите восстановление' >&2; return 1; fi
    if _z2k_ow_doh_has_preexisting_route; then
        echo 'DNS: сохранён предварительно настроенный маршрут на dnsproxy; удаление заблокировано, чтобы не оставить его без resolver' >&2
        return 1
    fi
    _z2k_ow_doh_restore_legacy_service || return 1
    _z2k_ow_doh_restore_route || return 1
    _z2k_ow_doh_enabled && "$Z2K_DOH_PROXY_INIT" disable || :
    "$Z2K_DOH_PROXY_INIT" stop || return 1
    if [ -s "$Z2K_DOH_CONFIG_BACKUP" ]; then
        _z2k_ow_doh_uci -q import dnsproxy < "$Z2K_DOH_CONFIG_BACKUP" || return 1
        _z2k_ow_doh_uci commit dnsproxy || return 1
    else
        for _section in global cache servers; do _z2k_ow_doh_uci delete "dnsproxy.$_section" >/dev/null 2>&1 || :; done
        _z2k_ow_doh_uci commit dnsproxy || return 1
    fi
    "$Z2K_DOH_APK_BIN" del dnsproxy || return 1
    rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_CONFIG_BACKUP" "$Z2K_DOH_CONFIG_BASELINE" "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" "$Z2K_DOH_SERVICE_SNAPSHOT" "$Z2K_DOH_STATE_FILE" "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_ROUTE_SNAPSHOT" "$Z2K_DOH_LEGACY_ROUTE_TXN" "$Z2K_DOH_OLD_SERVICE_SNAPSHOT" "$Z2K_DOH_OLD_BACKUP"
}
