#!/bin/sh
# Проверяет разбор и сохранение Telegram-настроек при регенерации общего конфига.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-policy-config"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgcfg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/z2k" "$T/root/bin/linux-x86_64"
printf '#!/bin/sh\nexit 0\n' > "$T/root/bin/linux-x86_64/tg-ws-proxy"
chmod +x "$T/root/bin/linux-x86_64/tg-ws-proxy"
cat > "$T/etc/z2k/config" <<'EOF'
ENABLED=1
TG_TCP_PORTS="443 5222 58321"
TG_CIDRS4="149.154.160.0/20 91.108.4.0/22"
TG_CIDRS6="2001:67c:4e8::/48 2001:b28:f23c::/47"
TG_DC_MAP_PATH="/etc/z2k/telegram-dc-map.json"
TG_DC_MAP_REFRESH_SECS="900"
TG_DC_MAP_ENDPOINTS_PATH="/etc/z2k/telegram-dc-endpoints.tsv"
EOF

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" Z2K_CONFIG="$T/etc/z2k/config"
export Z2K_TG_POLICY_CONFIG="$T/etc/z2k/tg-policy.conf"
export Z2K_CONFIG_GENERATION_MARKER="$T/etc/z2k/state/config.generation"
export Z2K_TG_RUST_BIN="$T/root/bin/linux-x86_64/tg-ws-proxy"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_OW_ARCH=x86_64
. "$REPO/platform/openwrt/generate.sh" || exit 1
z2k_ow_tg_policy_migrate || exit 1
. "$REPO/platform/openwrt/tg.sh" || exit 1

assert_eq "пробелы внутри TG_TCP_PORTS сохраняются" "443 5222 58321" "$Z2K_TG_TCP_PORTS"
assert_eq "каждый настроенный порт читается отдельно" "443 5222 58321" \
    "$(z2k_ow_tg_ports | tr '\n' ' ' | sed 's/ $//')"
assert_eq "CIDR IPv4 сохраняются с пробелами" "149.154.160.0/20 91.108.4.0/22" \
    "$(z2k_ow_tg_cfg TG_CIDRS4 '')"
assert_eq "CIDR IPv6 сохраняются с пробелами" "2001:67c:4e8::/48 2001:b28:f23c::/47" \
    "$(z2k_ow_tg_cfg TG_CIDRS6 '')"
assert_eq "путь манифеста DC сохраняется" "/etc/z2k/telegram-dc-endpoints.tsv" \
    "$(z2k_ow_tg_cfg TG_DC_MAP_ENDPOINTS_PATH '')"

assert_file "старые TG-настройки перенесены в OpenWrt-конфиг" "$Z2K_TG_POLICY_CONFIG"
assert_contains "в OpenWrt-конфиг перенесены порты" "$Z2K_TG_POLICY_CONFIG" \
    'TG_TCP_PORTS=443 5222 58321'

# После переноса OpenWrt-конфиг остаётся источником TG-настроек.
sed -i 's/^TG_TCP_PORTS=.*/TG_TCP_PORTS="443"/' "$Z2K_CONFIG"
z2k_ow_tg_policy_migrate || _t_bad "повторный перенос поверх существующей политики"
assert_eq "устаревшее значение общего конфига не затирает OpenWrt-порты" \
    "443 5222 58321" "$(z2k_ow_tg_cfg TG_TCP_PORTS '')"

# Генератор обновляет только общий конфиг; OpenWrt-owned файл остаётся источником TG.
create_official_config() {
    printf 'ENABLED=1\nNFQWS2_OPT="\\n--filter-tcp=443 --dpi-desync=fake\\n"\n' > "$1"
}
z2k_ow_config_fingerprint() { printf 'fixture-fingerprint'; }
z2k_ow_config_backup_prune() { :; }
ln -s "$Z2K_CONFIG" "$Z2K_ROOT/config"
Z2K_FORCE_CONFIG_REGEN=1
export Z2K_FORCE_CONFIG_REGEN
z2k_ow_generate || _t_bad "регенерация общего конфига через OpenWrt-обёртку"
z2k_ow_tg_policy_migrate || _t_bad "повторный перенос после регенерации"
assert_eq "порты переживают create_official_config" "443 5222 58321" \
    "$(z2k_ow_tg_cfg TG_TCP_PORTS '')"
assert_eq "путь карты DC переживает create_official_config" \
    "/etc/z2k/telegram-dc-map.json" "$(z2k_ow_tg_cfg TG_DC_MAP_PATH '')"
assert_eq "интервал обновления DC переживает create_official_config" \
    "900" "$(z2k_ow_tg_cfg TG_DC_MAP_REFRESH_SECS '')"
assert_eq "путь манифеста переживает create_official_config" \
    "/etc/z2k/telegram-dc-endpoints.tsv" "$(z2k_ow_tg_cfg TG_DC_MAP_ENDPOINTS_PATH '')"

_t_done
