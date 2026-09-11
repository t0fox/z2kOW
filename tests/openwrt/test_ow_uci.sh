#!/bin/sh
# tests/openwrt/test_ow_uci.sh - uci.sh: системные данные без своей UCI-схемы.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-uci"
AD="$(cd "$(dirname "$0")/../.." && pwd)/platform/openwrt"
. "$AD/uci.sh"

# без uci в PATH — дефолты, молча
assert_eq "lan default без uci" "lan" "$(z2k_ow_lan)"
assert_eq "dnsmasq servers без uci — пусто" "" "$(z2k_ow_dnsmasq_servers)"

# env побеждает
( OPENWRT_LAN="lan lan2"; [ "$(z2k_ow_lan)" = "lan lan2" ] ) \
    && _t_ok || _t_bad "OPENWRT_LAN из окружения"

# stub-uci: dnsmasq servers читаются из системы
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-uci.XXXXXX")"
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
# stub: uci -q get dhcp.@dnsmasq[0].server
if [ "$3" = "dhcp.@dnsmasq[0].server" ]; then
    printf '1.1.1.1\n8.8.8.8\n'
    exit 0
fi
exit 1
EOF
chmod +x "$T/bin/uci"
PATH="$T/bin:$PATH"
assert_eq "dnsmasq servers из stub-uci" "1.1.1.1
8.8.8.8" "$(z2k_ow_dnsmasq_servers)"

# своей UCI-схемы z2k нет: ни одного обращения к uci-секции z2k
if grep -qE 'uci[^"]*z2k\.|get "z2k' "$AD/uci.sh"; then
    _t_bad "uci.sh обращается к несуществующей UCI-схеме z2k"
else
    _t_ok
fi

_t_done
