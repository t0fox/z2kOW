#!/bin/sh
# Проверяет атомарную синхронизацию проверенных dcOption с nft.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-dynamic-policy"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgpair.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin/linux-x86_64" "$T/etc/z2k" "$T/tmp"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1 \$2" = "list table" ]; then exit 0; fi
if [ "\$1 \$2" = "-f -" ]; then
    while IFS= read -r _line; do echo "batch:\$_line" >> "$T/nft.log"; done
    exit 0
fi
if [ "\$1 \$2" = "list set" ]; then
    case "\$5" in
        z2k_tg_pair4) cat "$T/pair4.list" ;;
        z2k_tg_pair6) cat "$T/pair6.list" ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/lock" <<EOF
#!/bin/sh
echo "lock:\$*" >> "$T/lock.log"
exit 0
EOF
chmod +x "$T/bin/lock"
cat > "$T/root/bin/linux-x86_64/tg-ws-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/linux-x86_64/tg-ws-proxy"
printf 'ENABLED=1\n' > "$T/etc/z2k/config"
cat > "$T/etc/z2k/tg-policy.conf" <<'EOF'
TG_TCP_PORTS="443 5222"
EOF
cat > "$T/endpoints.tsv" <<'EOF'
z2k-tg-dc-options-v1 1791782348 1791782348
149.154.175.52 443
2001:db8::4 5222
EOF
printf 'elements = { 149.154.175.52 . 443 }\n' > "$T/pair4.list"
printf 'elements = { 2001:db8::4 . 5222 }\n' > "$T/pair6.list"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc/z2k" Z2K_TMP="$T/tmp"
export Z2K_CONFIG="$T/etc/z2k/config" Z2K_TG_POLICY_CONFIG="$T/etc/z2k/tg-policy.conf"
export Z2K_TG_DC_MAP_ENDPOINTS_PATH="$T/endpoints.tsv"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_OW_ARCH=x86_64
export Z2K_TG_RUST_BIN="$T/root/bin/linux-x86_64/tg-ws-proxy"
. "$REPO/platform/openwrt/tg.sh" || exit 1

: > "$T/nft.log"
z2k_ow_tg_nft_apply || _t_bad "применение проверенного манифеста"
assert_contains "создан IPv4 набор пар" "$T/nft.log" 'type ipv4_addr . inet_service'
assert_contains "создан IPv6 набор пар" "$T/nft.log" 'type ipv6_addr . inet_service'
assert_contains "обе семьи обновляются одним nft batch" "$T/nft.log" 'batch:flush set inet zapret2 z2k_tg_pair4'
assert_contains "IPv4 адрес и порт хранятся одной парой" "$T/nft.log" 'batch:add element inet zapret2 z2k_tg_pair4 { 149.154.175.52 . 443 }'
assert_contains "IPv6 адрес и порт хранятся одной парой" "$T/nft.log" 'batch:add element inet zapret2 z2k_tg_pair6 { 2001:db8::4 . 5222 }'
assert_contains "prerouting использует IPv4 пару" "$T/nft.log" 'ip daddr . tcp dport @z2k_tg_pair4 counter redirect to :1443'
assert_contains "output использует IPv6 пару" "$T/nft.log" 'ip6 daddr . tcp dport @z2k_tg_pair6 counter redirect to :1443'
assert_not_contains "официальная карта отключает широкие CIDR redirect" "$T/nft.log" 'ip daddr @z2k_tg_dc4 counter redirect'
assert_not_contains "обычный HTTP/80 запрещён" "$T/nft.log" 'dport 80.*redirect'

# Полный IPv6 без сокращения `::` тоже допустим в Rust-манифесте.
cp "$T/endpoints.tsv" "$T/endpoints.good"
printf 'z2k-tg-dc-options-v1 1791782348 1791782348\n2001:db8:1:2:3:4:5:6 443\n' > "$T/endpoints.tsv"
assert_eq "полный IPv6 принимается в манифесте" dynamic "$(z2k_ow_tg_manifest_mode)"
cp "$T/endpoints.good" "$T/endpoints.tsv"

# Лишняя старая пара должна вызывать конвергенцию и удаляться из набора.
printf 'z2k-tg-dc-options-v1 1791782348 1791782348\n149.154.175.52 443\n' > "$T/endpoints.tsv"
_z2k_ow_tg_pair_set_matches 6 "$Z2K_TG_PAIR6" && _t_bad "устаревшая IPv6-пара не обнаружена" || _t_ok
cp "$T/endpoints.good" "$T/endpoints.tsv"

# Тот же путь вызывается после fw4 reload; правила заново сходятся к манифесту.
: > "$T/nft.log"
z2k_ow_tg rules || _t_bad "повторное применение после fw4 reload"
assert_contains "после reload восстановлено IPv4-перенаправление по паре" "$T/nft.log" \
    'ip daddr . tcp dport @z2k_tg_pair4 counter redirect to :1443'
assert_not_contains "после reload не возвращается широкий CIDR redirect" "$T/nft.log" \
    'ip daddr @z2k_tg_dc4 counter redirect'

# Ошибочный файл не должен менять kernel-наборы/правила; последняя nft-карта остаётся живой.
printf 'z2k-tg-dc-options-v1 broken\n149.154.1.2; drop 443\n' > "$T/endpoints.tsv"
: > "$T/nft.log"
z2k_ow_tg_nft_apply 2>/dev/null && _t_bad "повреждённый манифест принят" || _t_ok
assert_not_contains "ошибка файла не запускает nft batch" "$T/nft.log" '^nft:-f -'
assert_not_contains "ошибка файла не меняет redirect rules" "$T/nft.log" '^nft:add rule'

# Порт 80 не принимается даже если его вручную добавили в общий список.
(
    Z2K_TG_TCP_PORTS='80 443'
    z2k_ow_tg_ports >/dev/null 2>&1 && _t_bad "80 принят политикой" || _t_ok
)

_t_done
