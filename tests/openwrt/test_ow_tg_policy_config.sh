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
TG_CONNECTION_MODE="manual"
TG_CONNECTION_LIMIT="64"
TG_CF_WORKER_DOMAINS="worker-one.example.com worker-two.example.net"
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
assert_eq "режим Auto/Manual перенесён в OpenWrt-конфиг" "manual" \
    "$(z2k_ow_tg_cfg TG_CONNECTION_MODE '')"
assert_eq "ручной максимум перенесён в OpenWrt-конфиг" "64" \
    "$(z2k_ow_tg_cfg TG_CONNECTION_LIMIT '')"
assert_eq "ручной максимум попал в аргументы Rust" "64" "$Z2K_TG_MAX_CONNECTIONS"
assert_eq "домены Telegram Worker переносятся с общим конфигом" \
    "worker-one.example.com worker-two.example.net" \
    "$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS '')"

assert_file "старые TG-настройки перенесены в OpenWrt-конфиг" "$Z2K_TG_POLICY_CONFIG"
assert_contains "в OpenWrt-конфиг перенесены порты" "$Z2K_TG_POLICY_CONFIG" \
    'TG_TCP_PORTS=443 5222 58321'
assert_contains "домены Worker перенесены в OpenWrt-owned конфиг" "$Z2K_TG_POLICY_CONFIG" \
    'TG_CF_WORKER_DOMAINS=worker-one.example.com worker-two.example.net'

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
assert_eq "режим Auto/Manual переживает create_official_config" "manual" \
    "$(z2k_ow_tg_cfg TG_CONNECTION_MODE '')"
assert_eq "ручной максимум переживает create_official_config" "64" \
    "$(z2k_ow_tg_cfg TG_CONNECTION_LIMIT '')"
assert_eq "домены Worker переживают create_official_config" \
    "worker-one.example.com worker-two.example.net" \
    "$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS '')"

# Управление Worker проверяет DNS-имя, пишет OpenWrt-owned конфиг атомарно и
# сохраняет остальные Telegram-настройки при добавлении и удалении.
mkdir -p "$T/tmp/z2k"
cat > "$T/mock-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TEST_INIT_LOG"
exit 0
EOF
chmod +x "$T/mock-init"
Z2K_TMP="$T/tmp/z2k" Z2K_INIT="$T/mock-init" Z2K_TEST_INIT_LOG="$T/init.log"
export Z2K_TMP Z2K_INIT Z2K_TEST_INIT_LOG
assert_eq "домен Worker нормализуется" "worker.example.com" \
    "$(z2k_ow_tg_worker_normalize ' HTTPS://Worker.Example.COM/path ')"
for _invalid_worker in '127.0.0.1' 'worker.example:443' 'worker..example' '-bad.example'; do
    if z2k_ow_tg_worker_normalize "$_invalid_worker" >/dev/null 2>&1; then
        _t_bad "некорректный Worker принят: $_invalid_worker"
    else
        _t_ok
    fi
done
z2k_ow_tg_worker_add worker-three.example.org >/dev/null || _t_bad "добавление Worker"
assert_eq "Worker добавлен в OpenWrt-owned конфиг" \
    "worker-one.example.com,worker-two.example.net,worker-three.example.org" \
    "$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS '')"
z2k_ow_tg_worker_add worker-three.example.org >/dev/null || _t_bad "повторное добавление Worker"
assert_eq "повторное добавление не дублирует Worker" \
    "worker-one.example.com,worker-two.example.net,worker-three.example.org" \
    "$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS '')"
z2k_ow_tg_worker_remove worker-two.example.net >/dev/null || _t_bad "удаление Worker"
assert_eq "удалён только выбранный Worker" \
    "worker-one.example.com,worker-three.example.org" \
    "$(z2k_ow_tg_cfg TG_CF_WORKER_DOMAINS '')"
assert_eq "прочие Telegram-параметры не изменились" "443 5222 58321" \
    "$(z2k_ow_tg_cfg TG_TCP_PORTS '')"
assert_contains "изменения Worker применены через штатный init" "$T/init.log" "reload"

_worker_snapshot=$(sha256sum "$Z2K_TG_POLICY_CONFIG" | awk '{print $1}')
if z2k_ow_tg_worker_add 'bad/worker.example' >/dev/null 2>&1; then
    _t_bad "API-адаптер принял путь вместо домена Worker"
else
    _t_ok
fi
assert_eq "отклонённый Worker не меняет конфиг" "$_worker_snapshot" \
    "$(sha256sum "$Z2K_TG_POLICY_CONFIG" | awk '{print $1}')"

cat > "$T/full-worker-list.conf" <<'EOF'
TG_CF_WORKER_DOMAINS=one.example,two.example,three.example,four.example,five.example,six.example,seven.example,eight.example
EOF
Z2K_TG_POLICY_CONFIG="$T/full-worker-list.conf"
export Z2K_TG_POLICY_CONFIG
if z2k_ow_tg_worker_add nine.example >/dev/null 2>&1; then
    _t_bad "добавлен Worker сверх лимита восьми"
else
    _t_ok
fi
assert_eq "переполнение списка не меняет конфиг" \
    "TG_CF_WORKER_DOMAINS=one.example,two.example,three.example,four.example,five.example,six.example,seven.example,eight.example" \
    "$(cat "$Z2K_TG_POLICY_CONFIG")"

# Новая установка записывает безопасную Auto-политику в OpenWrt-owned файл.
mkdir -p "$T/default/etc/z2k"
printf 'ENABLED=1\n' > "$T/default/etc/z2k/config"
Z2K_CONFIG="$T/default/etc/z2k/config"
Z2K_TG_POLICY_CONFIG="$T/default/etc/z2k/tg-policy.conf"
z2k_ow_tg_policy_migrate || _t_bad "начальная Auto-политика"
assert_contains "новая установка сохраняет режим Auto" "$Z2K_TG_POLICY_CONFIG" \
    'TG_CONNECTION_MODE=auto'
assert_contains "новая установка сохраняет безопасный Auto-предел" "$Z2K_TG_POLICY_CONFIG" \
    'TG_CONNECTION_LIMIT=32'

_t_done
