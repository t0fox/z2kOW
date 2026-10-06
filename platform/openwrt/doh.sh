#!/bin/sh
# OpenWrt https-dns-proxy integration; the package UCI config is the source of truth.

Z2K_DOH_PACKAGE=https-dns-proxy
Z2K_DOH_SECTION=z2kow_doh
Z2K_DOH_SECOND_SECTION=z2kow_doh_1
[ -n "${Z2K_DOH_UCI_BIN:-}" ] || Z2K_DOH_UCI_BIN=uci
[ -n "${Z2K_DOH_APK_BIN:-}" ] || Z2K_DOH_APK_BIN=apk
[ -n "${Z2K_DOH_PIDOF_BIN:-}" ] || Z2K_DOH_PIDOF_BIN=pidof
[ -n "${Z2K_DOH_PROXY_INIT:-}" ] || Z2K_DOH_PROXY_INIT=/etc/init.d/https-dns-proxy
[ -n "${Z2K_DOH_DNSMASQ_INIT:-}" ] || Z2K_DOH_DNSMASQ_INIT=/etc/init.d/dnsmasq
[ -n "${Z2K_DOH_CONFIG_FILE:-}" ] || Z2K_DOH_CONFIG_FILE=/etc/config/https-dns-proxy
[ -n "${Z2K_STATE:-}" ] || Z2K_STATE=/etc/z2k/state
_Z2K_DOH_DIR=$Z2K_STATE
[ -n "${Z2K_DOH_CONFIG_OWNED_FILE:-}" ] || Z2K_DOH_CONFIG_OWNED_FILE=$_Z2K_DOH_DIR/.doh-uci-owned
[ -n "${Z2K_DOH_PACKAGE_OWNED_FILE:-}" ] || Z2K_DOH_PACKAGE_OWNED_FILE=$_Z2K_DOH_DIR/.doh-package-owned
[ -n "${Z2K_DOH_CONFIG_BACKUP:-}" ] || Z2K_DOH_CONFIG_BACKUP=$_Z2K_DOH_DIR/.doh-config-backup
[ -n "${Z2K_DOH_CONFIG_BASELINE:-}" ] || Z2K_DOH_CONFIG_BASELINE=$_Z2K_DOH_DIR/.doh-config-baseline
[ -n "${Z2K_DOH_INSTALL_SNAPSHOT:-}" ] || Z2K_DOH_INSTALL_SNAPSHOT=$_Z2K_DOH_DIR/.doh-install-snapshot
[ -n "${Z2K_DOH_SERVICE_SNAPSHOT:-}" ] || Z2K_DOH_SERVICE_SNAPSHOT=$_Z2K_DOH_DIR/.doh-service-snapshot
[ -n "${Z2K_DOH_PREINSTALL_CONFIG:-}" ] || Z2K_DOH_PREINSTALL_CONFIG=$_Z2K_DOH_DIR/.doh-preinstall-config
[ -n "${Z2K_DOH_PREINSTALL_CONFIG_MARKER:-}" ] || Z2K_DOH_PREINSTALL_CONFIG_MARKER=$_Z2K_DOH_DIR/.doh-preinstall-config-present
[ -n "${Z2K_DOH_PROFILE_FILE:-}" ] || Z2K_DOH_PROFILE_FILE=$_Z2K_DOH_DIR/doh.provider
[ -n "${Z2K_DOH_STATE_FILE:-}" ] || Z2K_DOH_STATE_FILE=$_Z2K_DOH_DIR/doh.state
[ -n "${Z2K_DOH_ERROR_FILE:-}" ] || Z2K_DOH_ERROR_FILE=$_Z2K_DOH_DIR/.doh-error
[ -n "${Z2K_DOH_LEGACY_DHCP_SNAPSHOT:-}" ] || Z2K_DOH_LEGACY_DHCP_SNAPSHOT=$_Z2K_DOH_DIR/.doh-dnsmasq-snapshot
[ -n "${Z2K_DOH_LEGACY_MAIN_SNAPSHOT:-}" ] || Z2K_DOH_LEGACY_MAIN_SNAPSHOT=$_Z2K_DOH_DIR/.doh-main-snapshot

_z2k_ow_doh_uci() { "$Z2K_DOH_UCI_BIN" "$@"; }
_z2k_ow_doh_get() { _z2k_ow_doh_uci -q get "$1" 2>/dev/null; }
_z2k_ow_doh_export() { _z2k_ow_doh_uci -q export "$Z2K_DOH_PACKAGE" 2>/dev/null; }
_z2k_ow_doh_installed() { "$Z2K_DOH_APK_BIN" info -e "$Z2K_DOH_PACKAGE" >/dev/null 2>&1; }
_z2k_ow_doh_running() { "$Z2K_DOH_PIDOF_BIN" https-dns-proxy >/dev/null 2>&1; }
_z2k_ow_doh_enabled() { "$Z2K_DOH_PROXY_INIT" enabled >/dev/null 2>&1; }

_z2k_ow_doh_write() {
    _path=$1
    mkdir -p "$(dirname "$_path")" 2>/dev/null || return 1
    _tmp=$_path.new.$$
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_path"
}

_z2k_ow_doh_sections() {
    _z2k_ow_doh_uci -q show "$Z2K_DOH_PACKAGE" 2>/dev/null | awk -F= -v p="$Z2K_DOH_PACKAGE." '
        index($1,p)!=1 {next}
        {s=substr($1,length(p)+1); v=substr($0,index($0,"=")+1); gsub(/^\047|\047$/,"",v); if(v=="https-dns-proxy") print s}
    ' | sort -u
}

_z2k_ow_doh_delete_resolver_sections() {
    local _sections _section _after
    while :; do
        _sections=$(_z2k_ow_doh_sections)
        [ -n "$_sections" ] || return 0
        _section=$(printf '%s\n' "$_sections" | sed -n '1p')
        _z2k_ow_doh_uci delete "$Z2K_DOH_PACKAGE.$_section" || return 1
        _after=$(_z2k_ow_doh_sections)
        [ "$_after" != "$_sections" ] || return 1
    done
}

_z2k_ow_doh_owned() { [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] && grep -Fxq "$1" "$Z2K_DOH_CONFIG_OWNED_FILE"; }

_z2k_ow_doh_external_config() {
    local _section _found=0 _baseline _current
    if [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ]; then
        for _section in $(_z2k_ow_doh_sections); do _z2k_ow_doh_owned "$_section" || _found=1; done
        [ "$_found" = 1 ]
        return $?
    fi
    [ -s "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" ] && return 0
    if [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && [ -s "$Z2K_DOH_CONFIG_BASELINE" ]; then
        _baseline=$(cat "$Z2K_DOH_CONFIG_BASELINE")
        _current=$(_z2k_ow_doh_export)
        [ "$_baseline" = "$_current" ] && return 1
    fi
    [ -n "$(_z2k_ow_doh_export)" ]
}

_z2k_ow_doh_preset() {
    Z2K_DOH_PROVIDER=$1; Z2K_DOH_PROVIDER_LABEL=; Z2K_DOH_ENDPOINT=; Z2K_DOH_BOOTSTRAP=
    case "$1" in
        xbox) Z2K_DOH_PROVIDER_LABEL="Xbox DNS"; Z2K_DOH_ENDPOINT=https://xbox-dns.ru/dns-query ;;
        comss) Z2K_DOH_PROVIDER_LABEL=Comss; Z2K_DOH_ENDPOINT=https://dns.comss.one/dns-query; Z2K_DOH_BOOTSTRAP=92.38.152.163,93.115.24.204,2a03:90c0:56::1a5,2a02:7b40:5eb0:e95d::1 ;;
        google) Z2K_DOH_PROVIDER_LABEL=Google; Z2K_DOH_ENDPOINT=https://dns.google/dns-query; Z2K_DOH_BOOTSTRAP=8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844 ;;
        quad9) Z2K_DOH_PROVIDER_LABEL=Quad9; Z2K_DOH_ENDPOINT=https://dns.quad9.net/dns-query; Z2K_DOH_BOOTSTRAP=9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9 ;;
        xyz) Z2K_DOH_PROVIDER_LABEL="XyZ DNS"; Z2K_DOH_ENDPOINT=https://dns.yo1nk.app/dns-query ;;
        geohide_ru) Z2K_DOH_PROVIDER_LABEL="GeoHide RU"; Z2K_DOH_ENDPOINT=https://geohide.ru/dns-query ;;
        geohide_eu) Z2K_DOH_PROVIDER_LABEL="GeoHide EU"; Z2K_DOH_ENDPOINT=https://eu.geohide.ru/dns-query ;;
        geohide_us) Z2K_DOH_PROVIDER_LABEL="GeoHide US"; Z2K_DOH_ENDPOINT=https://us.geohide.ru/dns-query ;;
        cloudflare) Z2K_DOH_PROVIDER_LABEL=Cloudflare; Z2K_DOH_ENDPOINT=https://cloudflare-dns.com/dns-query; Z2K_DOH_BOOTSTRAP=1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001 ;;
        dns_ai) Z2K_DOH_PROVIDER_LABEL=dns.dns-ai.ru; Z2K_DOH_ENDPOINT=https://dns.dns-ai.ru/dns-query ;;
        malw) Z2K_DOH_PROVIDER_LABEL=dns.malw.link; Z2K_DOH_ENDPOINT=https://dns.malw.link/dns-query ;;
        astracat) Z2K_DOH_PROVIDER_LABEL=dns.astracat.ru; Z2K_DOH_ENDPOINT=https://dns.astracat.ru/dns-query ;;
        mafioznik) Z2K_DOH_PROVIDER_LABEL=dns.mafioznik.xyz; Z2K_DOH_ENDPOINT=https://dns.mafioznik.xyz/dns-query ;;
        malw_cloudflare) Z2K_DOH_PROVIDER_LABEL="malw Cloudflare Gateway"; Z2K_DOH_ENDPOINT=https://5u35p8m9i7.cloudflare-gateway.com/dns-query ;;
        nullsproxy) Z2K_DOH_PROVIDER_LABEL=nullsproxy; Z2K_DOH_ENDPOINT=https://dns.nullsproxy.com/dns-query ;;
        default) Z2K_DOH_PROVIDER_LABEL="Cloudflare + Google"; Z2K_DOH_ENDPOINT=https://cloudflare-dns.com/dns-query; Z2K_DOH_BOOTSTRAP=1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001 ;;
        *) return 1 ;;
    esac
}

_z2k_ow_doh_detect_provider() {
    case "$1" in
        *https://cloudflare-dns.com/dns-query*https://dns.google/dns-query*|*https://dns.google/dns-query*https://cloudflare-dns.com/dns-query*) Z2K_DOH_PROVIDER=default ;;
        *https://xbox-dns.ru/dns-query*) Z2K_DOH_PROVIDER=xbox ;;
        *https://dns.comss.one/dns-query*) Z2K_DOH_PROVIDER=comss ;;
        *https://dns.google/dns-query*) Z2K_DOH_PROVIDER=google ;;
        *https://dns.quad9.net/dns-query*) Z2K_DOH_PROVIDER=quad9 ;;
        *https://dns.yo1nk.app/dns-query*) Z2K_DOH_PROVIDER=xyz ;;
        *https://geohide.ru/dns-query*) Z2K_DOH_PROVIDER=geohide_ru ;;
        *https://eu.geohide.ru/dns-query*) Z2K_DOH_PROVIDER=geohide_eu ;;
        *https://us.geohide.ru/dns-query*) Z2K_DOH_PROVIDER=geohide_us ;;
        *https://cloudflare-dns.com/dns-query*) Z2K_DOH_PROVIDER=cloudflare ;;
        *https://dns.dns-ai.ru/dns-query*) Z2K_DOH_PROVIDER=dns_ai ;;
        *https://dns.malw.link/dns-query*) Z2K_DOH_PROVIDER=malw ;;
        *https://dns.astracat.ru/dns-query*) Z2K_DOH_PROVIDER=astracat ;;
        *https://dns.mafioznik.xyz/dns-query*) Z2K_DOH_PROVIDER=mafioznik ;;
        *https://5u35p8m9i7.cloudflare-gateway.com/dns-query*) Z2K_DOH_PROVIDER=malw_cloudflare ;;
        *https://dns.nullsproxy.com/dns-query*) Z2K_DOH_PROVIDER=nullsproxy ;;
        *) Z2K_DOH_PROVIDER=custom ;;
    esac
}

_z2k_ow_doh_valid_custom_endpoint() {
    local _url=$1 _rest _authority _host _port _path _length
    case "$_url" in https://*) ;; *) return 1 ;; esac
    _length=$(printf %s "$_url" | wc -c | tr -d ' ')
    [ -n "$_length" ] && [ "$_length" -le 2048 ] || return 1
    _rest=$(printf %s "$_url" | sed 's,^https://,,')
    _authority=$(printf %s "$_rest" | cut -d/ -f1)
    _path=/$(printf %s "$_rest" | cut -d/ -f2-)
    case "$_authority" in
        *:*) _host=$(printf %s "$_authority" | sed 's/:[^:]*$//'); _port=$(printf %s "$_authority" | sed 's/^.*://'); case "$_port" in ''|*[!0-9]*) return 1 ;; esac; [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1 ;;
        *) _host=$_authority ;;
    esac
    case "$_host" in ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;; esac
    printf %s "$_path" | LC_ALL=C grep -Eq '^[A-Za-z0-9._~/?%&=+-]+$'
}

_z2k_ow_doh_valid_bootstrap() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | awk -F, '
        function v4(s,a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||length(a[i])>3||a[i]+0>255||(length(a[i])>1&&substr(a[i],1,1)=="0"))return 0;return 1}
        function v6(s,a,n,i,c,g){if(s!~/:/||s~/[^0-9A-Fa-f:]/||s~/:::/)return 0;g=(s~/::/);if(g&&s~/::.*::/)return 0;n=split(s,a,":");c=0;for(i=1;i<=n;i++)if(a[i]!=""){if(length(a[i])>4)return 0;c++}if(g)return c<8;return c==8}
        NF<1||NF>8{valid=0;next}{valid=1;for(i=1;i<=NF;i++)if(!v4($i)&&!v6($i))valid=0}
        END{exit !(NR==1&&valid)}
    '
}

_z2k_ow_doh_urls() {
    local _section _value
    for _section in $(_z2k_ow_doh_sections); do
        _value=$(_z2k_ow_doh_get "$Z2K_DOH_PACKAGE.$_section.resolver_url") || _value=
        [ -n "$_value" ] && printf '%s\n' "$_value"
    done
}

_z2k_ow_doh_bootstraps() {
    local _section _value
    for _section in $(_z2k_ow_doh_sections); do
        _value=$(_z2k_ow_doh_get "$Z2K_DOH_PACKAGE.$_section.bootstrap_dns") || _value=
        [ -n "$_value" ] && printf '%s\n' "$_value"
    done
}

_z2k_ow_doh_save_service() {
    local _enabled=0 _running=0
    _z2k_ow_doh_enabled && _enabled=1
    _z2k_ow_doh_running && _running=1
    printf 'enabled=%s\nrunning=%s\n' "$_enabled" "$_running" | _z2k_ow_doh_write "$Z2K_DOH_SERVICE_SNAPSHOT"
}

_z2k_ow_doh_restore_service() {
    [ -s "$Z2K_DOH_SERVICE_SNAPSHOT" ] || return 0
    local _enabled _running
    _enabled=$(sed -n 's/^enabled=//p' "$Z2K_DOH_SERVICE_SNAPSHOT")
    _running=$(sed -n 's/^running=//p' "$Z2K_DOH_SERVICE_SNAPSHOT")
    if [ "$_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable || return 1; else "$Z2K_DOH_PROXY_INIT" disable || return 1; fi
    if [ "$_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart || return 1; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || true; fi
    "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
    rm -f "$Z2K_DOH_SERVICE_SNAPSHOT"
}

_z2k_ow_doh_restore_backup() {
    [ -s "$Z2K_DOH_CONFIG_BACKUP" ] || return 1
    _z2k_ow_doh_uci -q import "$Z2K_DOH_PACKAGE" < "$Z2K_DOH_CONFIG_BACKUP" || return 1
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
    "$Z2K_DOH_PROXY_INIT" reload >/dev/null 2>&1 || true
    _z2k_ow_doh_restore_service
}

z2k_ow_doh_status() {
    local _state=not-installed _installed=0 _running=0 _enabled=0 _provider=unknown _endpoint= _bootstrap= _urls _bootstraps _external=0 _owner=external _sections _force=0 _reason=
    if _z2k_ow_doh_installed; then
        _installed=1
        _z2k_ow_doh_running && _running=1
        _z2k_ow_doh_enabled && _enabled=1
        [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && _owner=z2kow
        _sections=$(_z2k_ow_doh_sections)
        _urls=$(_z2k_ow_doh_urls | paste -sd, -)
        _bootstraps=$(_z2k_ow_doh_bootstraps | paste -sd, -)
        if [ -n "$_urls" ]; then
            _z2k_ow_doh_detect_provider "$_urls"
            _provider=$Z2K_DOH_PROVIDER
            _endpoint=$(printf '%s\n' "$_urls" | sed -n '1p')
        fi
        _bootstrap=$(printf '%s\n' "$_bootstraps" | sed -n '1p')
        _z2k_ow_doh_external_config && _external=1
        [ "$(_z2k_ow_doh_get "$Z2K_DOH_PACKAGE.config.force_dns")" = 1 ] && _force=1
        if [ -z "$_urls" ]; then
            _state=error; _reason=resolver-config-missing
        elif [ "$_running" = 1 ]; then
            _state=working
        elif [ "$_enabled" = 1 ]; then
            _state=error; _reason=proxy-not-running
        else
            _state=disabled
        fi
    fi
    printf 'state=%s installed=%s enabled=%s running=%s provider=%s endpoint=%s bootstrap=%s package_owner=%s external_config=%s force_lan_dns=%s reason=%s\n' \
        "$_state" "$_installed" "$_enabled" "$_running" "$_provider" "$_endpoint" "$_bootstrap" "$_owner" "$_external" "$_force" "$_reason"
}

z2k_ow_doh_install() {
    local _before
    if _z2k_ow_doh_installed; then echo "https-dns-proxy уже установлен; конфигурация не менялась"; return 0; fi
    mkdir -p "$_Z2K_DOH_DIR" 2>/dev/null || return 1
    _before=$(_z2k_ow_doh_export)
    if [ -n "$_before" ] || [ -s "$Z2K_DOH_CONFIG_FILE" ]; then
        printf '%s\n' "$_before" | _z2k_ow_doh_write "$Z2K_DOH_PREINSTALL_CONFIG" || return 1
        printf 'present=1\n' | _z2k_ow_doh_write "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" || return 1
    fi
    "$Z2K_DOH_APK_BIN" add "$Z2K_DOH_PACKAGE" || return 1
    _z2k_ow_doh_installed || { echo "apk не подтвердил установку https-dns-proxy" >&2; return 1; }
    printf '%s\n' "$Z2K_DOH_PACKAGE" | _z2k_ow_doh_write "$Z2K_DOH_PACKAGE_OWNED_FILE" || return 1
    _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BASELINE" || return 1
    printf 'preexisting_config=%s\n' "$([ -s "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" ] && echo 1 || echo 0)" \
        | _z2k_ow_doh_write "$Z2K_DOH_INSTALL_SNAPSHOT" || return 1
    echo "https-dns-proxy установлен; выберите провайдера и нажмите Применить"
}

z2k_ow_doh_select_provider() {
    local _provider=$1 _endpoint=${2:-} _bootstrap=${3:-} _replace=${4:-} _external=0 _section
    [ -n "$_replace" ] || _replace=0
    case "$_replace" in 0|1) ;; *) return 1 ;; esac
    if [ "$_provider" = custom ]; then
        _z2k_ow_doh_valid_custom_endpoint "$_endpoint" && _z2k_ow_doh_valid_bootstrap "$_bootstrap" || {
            echo "DoH: некорректный HTTPS endpoint или bootstrap DNS" >&2; return 1;
        }
        Z2K_DOH_PROVIDER=custom; Z2K_DOH_PROVIDER_LABEL="Свой endpoint"; Z2K_DOH_ENDPOINT=$_endpoint; Z2K_DOH_BOOTSTRAP=$_bootstrap
    else
        _z2k_ow_doh_preset "$_provider" || { echo "DoH: неизвестный provider" >&2; return 1; }
    fi
    _z2k_ow_doh_installed || { echo "DoH: сначала установите https-dns-proxy" >&2; return 1; }
    _z2k_ow_doh_external_config && _external=1
    if [ "$_external" = 1 ] && [ "$_replace" != 1 ]; then
        echo "DoH: найдена пользовательская конфигурация; подтвердите замену" >&2; return 1
    fi
    if [ "$_external" = 1 ]; then
        [ -s "$Z2K_DOH_CONFIG_BACKUP" ] || _z2k_ow_doh_export | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_BACKUP" || return 1
        [ -s "$Z2K_DOH_SERVICE_SNAPSHOT" ] || _z2k_ow_doh_save_service || return 1
    fi
    _z2k_ow_doh_delete_resolver_sections || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.config=main" || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.config.listen_addr=127.0.0.1" || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.config.dnsmasq_config_update=*" || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECTION=https-dns-proxy" || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECTION.resolver_url=$Z2K_DOH_ENDPOINT" || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECTION.listen_port=5053" || return 1
    [ -z "$Z2K_DOH_BOOTSTRAP" ] || _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECTION.bootstrap_dns=$Z2K_DOH_BOOTSTRAP" || return 1
    if [ "$_provider" = default ]; then
        _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECOND_SECTION=https-dns-proxy" || return 1
        _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECOND_SECTION.resolver_url=https://dns.google/dns-query" || return 1
        _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECOND_SECTION.bootstrap_dns=8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844" || return 1
        _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.$Z2K_DOH_SECOND_SECTION.listen_port=5054" || return 1
    fi
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
    printf '%s\n%s\n' "$Z2K_DOH_SECTION" "$([ "$_provider" = default ] && echo "$Z2K_DOH_SECOND_SECTION")" \
        | sed '/^$/d' | _z2k_ow_doh_write "$Z2K_DOH_CONFIG_OWNED_FILE" || return 1
    "$Z2K_DOH_PROXY_INIT" enable || return 1
    "$Z2K_DOH_PROXY_INIT" restart || return 1
    "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
    echo "DoH настроен: $Z2K_DOH_PROVIDER_LABEL"
}

z2k_ow_doh_enable() { _z2k_ow_doh_installed && "$Z2K_DOH_PROXY_INIT" enable && "$Z2K_DOH_PROXY_INIT" restart && "$Z2K_DOH_DNSMASQ_INIT" restart; }
z2k_ow_doh_disable() { _z2k_ow_doh_installed && "$Z2K_DOH_PROXY_INIT" disable && "$Z2K_DOH_PROXY_INIT" stop && "$Z2K_DOH_DNSMASQ_INIT" restart; }
z2k_ow_doh_restart() { _z2k_ow_doh_installed && "$Z2K_DOH_PROXY_INIT" restart && "$Z2K_DOH_DNSMASQ_INIT" restart; }

z2k_ow_doh_check() {
    local _lookup _output _host
    _lookup=$Z2K_DOH_NSLOOKUP_BIN; [ -n "$_lookup" ] || _lookup=nslookup
    _host=$Z2K_DOH_HEALTH_HOST; [ -n "$_host" ] || _host=example.com
    _output=$("$_lookup" "$_host" 127.0.0.1 2>&1) || { printf '%s\n' "DoH/DNS check failed: $_output" >&2; return 1; }
    printf '%s\n' "$_output" | awk '/Address([[:space:]]+[0-9]+)?:/&&$NF~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/&&$NF!="127.0.0.1"{ok=1} END{exit !ok}' || {
        echo "DoH/DNS check returned no IPv4 address" >&2; return 1;
    }
    echo "DoH/DNS check succeeded"
}

z2k_ow_doh_set_force_dns() {
    case "$1" in 0|1) ;; *) return 1 ;; esac
    _z2k_ow_doh_installed || return 1
    _z2k_ow_doh_uci set "$Z2K_DOH_PACKAGE.config.force_dns=$1" && _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" \
        && "$Z2K_DOH_PROXY_INIT" restart && "$Z2K_DOH_DNSMASQ_INIT" restart
}

_z2k_ow_doh_remove_sections() {
    local _section
    for _section in "$Z2K_DOH_SECTION" "$Z2K_DOH_SECOND_SECTION" z2kow_xbox; do
        _z2k_ow_doh_owned "$_section" || continue
        if [ "$(_z2k_ow_doh_get "$Z2K_DOH_PACKAGE.$_section")" = https-dns-proxy ]; then
            _z2k_ow_doh_uci delete "$Z2K_DOH_PACKAGE.$_section" || return 1
        fi
    done
    _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE"
}

_z2k_ow_doh_restore_legacy_dnsmasq() {
    [ -s "$Z2K_DOH_LEGACY_DHCP_SNAPSHOT" ] || return 0
    local _kind _section _value _port _rc=0
    _port=$(awk -F'|' '$1=="route_port"{print $3;exit}' "$Z2K_DOH_LEGACY_DHCP_SNAPSHOT")
    for _section in $(_z2k_ow_doh_uci -q show dhcp 2>/dev/null | awk -F= '$1~/^dhcp\..+$/&&$2~/dnsmasq/{x=$1;sub(/^dhcp\./,"",x);sub(/\..*/,"",x);print x}' | sort -u); do
        [ -z "$_port" ] || _z2k_ow_doh_uci del_list "dhcp.$_section.server=/#/127.0.0.1#$_port" || _rc=1
    done
    while IFS='|' read -r _kind _section _value; do
        case "$_kind" in
            server) _z2k_ow_doh_uci add_list "dhcp.$_section.server=$_value" || _rc=1 ;;
            noresolv)
                case "$_value" in 0:) _z2k_ow_doh_uci delete "dhcp.$_section.noresolv" || _rc=1 ;; 1:*) _z2k_ow_doh_uci set "dhcp.$_section.noresolv=$(printf %s "$_value" | cut -c3-)" || _rc=1 ;; esac
                ;;
        esac
    done < "$Z2K_DOH_LEGACY_DHCP_SNAPSHOT"
    _z2k_ow_doh_uci commit dhcp || _rc=1
    [ "$_rc" = 0 ] && "$Z2K_DOH_DNSMASQ_INIT" restart || _rc=1
    [ "$_rc" = 0 ] && rm -f "$Z2K_DOH_LEGACY_DHCP_SNAPSHOT"
    return "$_rc"
}

z2k_ow_doh_uninstall() {
    local _owned_package=0 _external=0 _legacy=0 _preexisting=0
    [ -s "$Z2K_DOH_PACKAGE_OWNED_FILE" ] && _owned_package=1
    [ -s "$Z2K_DOH_CONFIG_OWNED_FILE" ] && _legacy=1
    _z2k_ow_doh_external_config && _external=1
    [ "$_legacy" = 0 ] || _z2k_ow_doh_restore_legacy_dnsmasq || return 1

    if [ "$_owned_package" = 1 ] && [ -s "$Z2K_DOH_PREINSTALL_CONFIG_MARKER" ]; then
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || true
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || true
        if _z2k_ow_doh_installed; then "$Z2K_DOH_APK_BIN" del "$Z2K_DOH_PACKAGE" || return 1; fi
        if [ -s "$Z2K_DOH_CONFIG_BACKUP" ]; then
            _z2k_ow_doh_uci -q import "$Z2K_DOH_PACKAGE" < "$Z2K_DOH_CONFIG_BACKUP" || return 1
            _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
        elif [ -s "$Z2K_DOH_PREINSTALL_CONFIG" ]; then
            _z2k_ow_doh_uci -q import "$Z2K_DOH_PACKAGE" < "$Z2K_DOH_PREINSTALL_CONFIG" || return 1
            _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
        elif [ -e "$Z2K_DOH_CONFIG_FILE" ]; then
            : > "$Z2K_DOH_CONFIG_FILE" || return 1
        fi
        "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
        rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_CONFIG_BACKUP" \
            "$Z2K_DOH_CONFIG_BASELINE" "$Z2K_DOH_INSTALL_SNAPSHOT" "$Z2K_DOH_SERVICE_SNAPSHOT" \
            "$Z2K_DOH_PREINSTALL_CONFIG" "$Z2K_DOH_PREINSTALL_CONFIG_MARKER"
    elif [ -s "$Z2K_DOH_CONFIG_BACKUP" ]; then
        _z2k_ow_doh_remove_sections || return 1
        _z2k_ow_doh_uci -q import "$Z2K_DOH_PACKAGE" < "$Z2K_DOH_CONFIG_BACKUP" || return 1
        _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
        if [ -s "$Z2K_DOH_SERVICE_SNAPSHOT" ]; then
            _enabled=$(sed -n 's/^enabled=//p' "$Z2K_DOH_SERVICE_SNAPSHOT")
            _running=$(sed -n 's/^running=//p' "$Z2K_DOH_SERVICE_SNAPSHOT")
            if [ "$_enabled" = 1 ]; then "$Z2K_DOH_PROXY_INIT" enable || return 1; else "$Z2K_DOH_PROXY_INIT" disable || return 1; fi
            if [ "$_running" = 1 ]; then "$Z2K_DOH_PROXY_INIT" restart || return 1; else "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || true; fi
        fi
        "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
        rm -f "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_CONFIG_BACKUP" "$Z2K_DOH_SERVICE_SNAPSHOT"
    elif [ "$_owned_package" = 1 ] && [ "$_external" = 0 ]; then
        "$Z2K_DOH_PROXY_INIT" disable >/dev/null 2>&1 || true
        "$Z2K_DOH_PROXY_INIT" stop >/dev/null 2>&1 || true
        "$Z2K_DOH_APK_BIN" del "$Z2K_DOH_PACKAGE" || return 1
        _preexisting=$(sed -n 's/^preexisting_config=//p' "$Z2K_DOH_INSTALL_SNAPSHOT" 2>/dev/null)
        if [ "$_preexisting" = 1 ] && [ -s "$Z2K_DOH_PREINSTALL_CONFIG" ]; then
            _z2k_ow_doh_uci -q import "$Z2K_DOH_PACKAGE" < "$Z2K_DOH_PREINSTALL_CONFIG" || return 1
            _z2k_ow_doh_uci commit "$Z2K_DOH_PACKAGE" || return 1
        else rm -f "$Z2K_DOH_CONFIG_FILE"; fi
        rm -f "$Z2K_DOH_PACKAGE_OWNED_FILE" "$Z2K_DOH_CONFIG_OWNED_FILE" "$Z2K_DOH_CONFIG_BASELINE" \
            "$Z2K_DOH_INSTALL_SNAPSHOT" "$Z2K_DOH_PREINSTALL_CONFIG" "$Z2K_DOH_PREINSTALL_CONFIG_MARKER"
    elif [ "$_legacy" = 1 ]; then
        "$Z2K_DOH_PROXY_INIT" reload >/dev/null 2>&1 || true
        "$Z2K_DOH_DNSMASQ_INIT" restart || return 1
        rm -f "$Z2K_DOH_CONFIG_OWNED_FILE"
    fi
    rm -f "$Z2K_DOH_PROFILE_FILE" "$Z2K_DOH_STATE_FILE" "$Z2K_DOH_ERROR_FILE"
    return 0
}
