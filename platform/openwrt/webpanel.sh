#!/bin/sh
# platform/openwrt/webpanel.sh - OpenWrt panel helpers (Stage 6, PACKAGE-owned).
#
# Только OS effects. Никаких вторых TG/RT/WARP/firewall/updater/config
# реализаций — везде делегация замороженным адаптерам Stages 1-5.
# Вызывается из webpanel/cgi/platform.sh (override-функции).

# Канонический LAN IPv4 для server.bind (НЕ имя сети!).
# z2k_ow_lan отдаёт ИМЯ сети ("lan") для zapret2 OPENWRT_LAN — lighttpd
# резолвить его не умеет, bind="lan" роняет старт (Stage 8 live-дефект).
# Источники: uci network.lan.ipaddr, иначе ubus network.interface.lan.
# Строгая IPv4-валидация: мусор — отказ, а не bind-куда-попало.
_wp_is_ipv4() {
    local _o="$1" _p="" _n=0
    case "$_o" in ''|*[!0-9.]*) return 1 ;; esac
    while [ -n "$_o" ]; do
        _p="${_o%%.*}"
        case "$_p" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_p" -le 255 ] 2>/dev/null || return 1
        _n=$((_n + 1))
        case "$_o" in *.*) _o="${_o#*.}" ;; *) _o="" ;; esac
    done
    [ "$_n" = "4" ]
}
wp_lan_ip() {
    # Только uci network.lan.ipaddr (канонический LAN IP; uci есть всегда).
    # НИКАКОГО ubus call здесь: static-guard запрещает platform-логику
    # через ubus в этом слое. Строгая IPv4-валидация: мусор — отказ.
    # CIDR-суффикс uci (192.168.1.1/24 на живом 25.12.5) снимаем ДО проверки
    # (Stage 8 live-дефект: целиком CIDR валидацию не проходил).
    # Имя сети ("lan") — отказ: lighttpd bind="lan" не стартует.
    # WP_UCI_BIN — шов тестируемости (как WP_IP_BIN ниже): явный путь
    # к uci-бинарнику; в проде не выставлен — работает авто-поиск.
    local _ip="" _uci="${WP_UCI_BIN:-}"
    if [ -z "$_uci" ]; then
        if command -v uci >/dev/null 2>&1; then
            _uci="uci"
        elif [ -x /sbin/uci ]; then
            # Урезанный PATH (postinst-контекст): явный системный путь.
            _uci="/sbin/uci"
        else
            echo "нет uci для LAN-адреса" >&2
            return 1
        fi
    fi
    _ip="$("$_uci" -q get network.lan.ipaddr 2>/dev/null)"
    _ip="${_ip%%/*}"
    _wp_is_ipv4 "$_ip" || { echo "нет LAN IPv4-адреса для bind" >&2; return 1; }
    printf '%s' "$_ip"
}

# Пути настроек панели (USER) и transient-конфига. Переопределимы тестам.
WP_SETTINGS_DIR="${WP_SETTINGS_DIR:-${Z2K_ETC:-/etc/z2k}/webpanel}"
WP_RUN_DIR="${WP_RUN_DIR:-${Z2K_TMP:-/tmp/z2k}/runtime/webpanel}"
WP_TEMPLATE="${WP_TEMPLATE:-${Z2K_ROOT:-/usr/lib/z2k}/webpanel/lighttpd.conf.in}"
WP_PORT_DEFAULT="${WP_PORT_DEFAULT:-8088}"
# Каталог errorlog lighttpd (из шаблона; tmpfs — пересоздавать при каждом
# render, иначе lighttpd не открывает лог и старт валится).
WP_LOG_DIR="${WP_LOG_DIR:-/tmp/z2k/logs}"

# Порт панели из настроек (или дефолт). Для init-проверок.
wp_panel_port() {
    local port=""
    port=$(cat "$WP_SETTINGS_DIR/port" 2>/dev/null | tr -dc '0-9')
    [ -n "$port" ] || port="$WP_PORT_DEFAULT"
    printf '%s' "$port"
}

# Render transient lighttpd.conf из шаблона + persistent settings.
# Настройки создаются, только если отсутствуют (WP2/WP3). Печатает путь.
# @PLATFORM_ENV@ подставляет Z2K_PLATFORM для CGI (тот же шаблон, §27).
wp_panel_render() {
    local port="" bind="" bind6="" sock="" dst tmp
    mkdir -p "$WP_SETTINGS_DIR" "$WP_RUN_DIR" "$WP_LOG_DIR" 2>/dev/null || return 1
    [ -f "$WP_TEMPLATE" ] || { echo "нет шаблона $WP_TEMPLATE" >&2; return 1; }
    port=$(cat "$WP_SETTINGS_DIR/port" 2>/dev/null | tr -dc '0-9')
    [ -n "$port" ] || port="$WP_PORT_DEFAULT"
    bind=$(cat "$WP_SETTINGS_DIR/bind" 2>/dev/null | tr -d ' \t\r\n')
    if [ -z "$bind" ]; then
        bind="$(wp_lan_ip)" || { echo "нет LAN-адреса для bind" >&2; return 1; }
    fi
    # Fail fast: мусор в bind (имя сети вместо IP, опечатка) иначе умирает
    # глубоко в lighttpd с невнятной ошибкой. Проверяем и из настроек.
    _wp_is_ipv4 "$bind" || { echo "bind не IPv4-адрес: [$bind]" >&2; return 1; }
    # Сохраняем ТОЛЬКО отсутствующее (переустановка/обновление не сбрасывает).
    [ -f "$WP_SETTINGS_DIR/port" ] || printf '%s\n' "$port" > "$WP_SETTINGS_DIR/port"
    [ -f "$WP_SETTINGS_DIR/bind" ] || printf '%s\n' "$bind" > "$WP_SETTINGS_DIR/bind"
    bind6=$(cat "$WP_SETTINGS_DIR/bind6" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$bind6" ]; then
        sock='$SERVER["socket"] == "['"$bind6"']:'"$port"'" { }'
    else
        sock=""
    fi
    dst="$WP_RUN_DIR/lighttpd.conf"
    tmp="$dst.z2k-new.$$"
    sed -e "s|@WWW_DIR@|${Z2K_ROOT:-/usr/lib/z2k}/www|g" \
        -e "s|@PORT@|${port}|g" -e "s|@BIND@|${bind}|g" \
        -e "s|@IPV6_SOCKET@|${sock}|g" \
        -e 's|@PLATFORM_ENV@|setenv.add-environment += ("Z2K_PLATFORM" => "openwrt")|g' \
        "$WP_TEMPLATE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if grep -q '@[A-Z_]*@' "$tmp" 2>/dev/null; then
        echo "в конфиге остался плейсхолдер" >&2
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    printf '%s' "$dst"
}

# Validate сгенерированного конфига (fail loudly до старта).
wp_panel_validate() {
    local cfg="${1:-$WP_RUN_DIR/lighttpd.conf}" _bin
    [ -f "$cfg" ] || return 1
    _bin="$(command -v lighttpd 2>/dev/null)" || _bin="/usr/sbin/lighttpd"
    [ -x "$_bin" ] || { echo "нет lighttpd: $_bin" >&2; return 1; }
    "$_bin" -tt -f "$cfg" 2>&1
}

# Panel process state: pidfile + cmdline-match (тот же приём, что S96).
wp_panel_running() {
    local pidfile="${WP_PIDFILE:-/var/run/z2k-webpanel.pid}" pid=""
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
        *lighttpd*"$WP_RUN_DIR"*) return 0 ;;
    esac
    return 1
}

# Порт свободен ИЛИ занят нашим процессом (WP21: чужого не kill'им,
# конфиг его не трогаем — старт просто громко падает).
wp_port_free_or_ours() {
    local port="$1" _pid=""
    [ -n "$port" ] || return 1
    if [ -f "${WP_PIDFILE:-/var/run/z2k-webpanel.pid}" ]; then
        _pid=$(cat "${WP_PIDFILE:-/var/run/z2k-webpanel.pid}" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            return 0
        fi
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$port " && return 1
        return 0
    fi
    # Без ss — по /proc/net/tcp{,6}: порт hex, слушается (0A).
    awk -v p="$port" 'BEGIN { want = sprintf("%04X", p) }
        FNR > 1 && $4 == "0A" { split($2, a, ":"); if (a[2] == want) found = 1 }
        END { exit (found ? 0 : 1) }' /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 1
    return 0
}

# Соседи для WARP UI (тот же \037 TSV, что парсер hotspot upstream): mac ip label net
# active on. Источники: ip neigh, затем /proc/net/arp; имена — из DHCP leases.
# Hostname неизвестен → label=mac (пустоты запрещены контрактом UI).
wp_neighbors() {
    local sel="${WARP_LISTS_DIR:-/etc/z2k/user-lists/warp}/devices.txt"
    [ -f "$sel" ] || sel=/dev/null
    {
        # WP_IP_BIN — шов тестируемости: api.sh кладёт свой PATH поверх
        # окружения, поэтому мок ip в CGI-тесте иначе недостижим.
        "${WP_IP_BIN:-ip}" -4 neigh show 2>/dev/null | awk 'NF >= 5 { print $1, $5, $3, $NF }'
        echo "---ARP---"
        awk 'FNR > 1 && $3 != "00:00:00:00:00:00" { print $1, $4, $6, "STALE" }' \
            "${WP_ARP_PATH:-/proc/net/arp}" 2>/dev/null
    } | awk -v sel="$sel" -v leases="${WP_DHCP_LEASES:-/tmp/dhcp.leases} /tmp/dhcp6.leases" '
    function norm_mac(m) { m = tolower(m); gsub(/-/, ":", m); return m }
    BEGIN {
        n = split(leases, lf, " ")
        for (i = 1; i <= n; i++) {
            while ((getline l < lf[i]) > 0) {
                gsub(/\r/, "", l)
                # dnsmasq: expiry mac ip hostname ... ; иное — пропустим молча
                if (split(l, f, " ") >= 4 && f[2] ~ /^([0-9a-fA-F][0-9a-fA-F]:){5}/) {
                    m = norm_mac(f[2])
                    if (!(m in host) && f[4] != "" && f[4] != "*") host[m] = f[4]
                }
            }
            close(lf[i])
        }
        while ((getline l < sel) > 0) {
            gsub(/\r/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); l = norm_mac(l)
            if (l ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/) on[l] = 1
        }
        close(sel)
    }
    /^---ARP---$/ { use_arp = 1; next }
    {
        ip = $1; mac = norm_mac($2); net = $3; st = $4
        if (mac !~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/) next
        if (mac in seen) next
        seen[mac] = 1
        # active доказывает только живой neigh (REACHABLE/PERMANENT);
        # arp-fallback перечисляет, но liveness не утверждает.
        active = (st == "REACHABLE" || st == "PERMANENT") ? 1 : 0
        label = (mac in host) ? host[mac] : mac
        gsub(/"/, "", label)
        printf "%s\037%s\037%s\037%s\037%d\037%d\n", mac, ip, label, net, active, (mac in on)
    }'
}
