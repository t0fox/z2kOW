#!/bin/sh
# Жизненный цикл Telegram на Rust: один экземпляр procd, свои nft-правила, без релея.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-lifecycle"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tglc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/root/bin/linux-x86_64" "$T/etc/state" "$T/tmp" "$T/proc"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1 \$2" = "-f -" ]; then
    while IFS= read -r _line; do echo "nft-batch:\$_line" >> "$T/nft.log"; done
    exit 0
fi
if [ "\$1 \$2" = "list table" ]; then exit 0; fi
if [ "\$1 \$2" = "list set" ]; then
    case "\$5" in
      z2k_tg_dc6) echo 'set z2k_tg_dc6 { elements = { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280:203::/48 } }' ;;
      *) echo 'set z2k_tg_dc4 { elements = { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24 } }' ;;
    esac
    exit 0
fi
if [ "\$1 \$2" = "list chain" ]; then
    case "\$5" in
      z2k_tg_dst_pre|z2k_tg_dst_out)
        [ "\$5" = z2k_tg_dst_out ] && echo 'meta mark 0x40000000 return'
        for port in \$(printf '%s' "\$Z2K_TG_TCP_PORTS" | tr ',' ' '); do
            echo "tcp dport \$port ip daddr @z2k_tg_dc4 counter packets 0 bytes 0 redirect to :1443"
            echo "tcp dport \$port ip6 daddr @z2k_tg_dc6 counter packets 0 bytes 0 redirect to :1443"
        done
        ;;
      z2k_tg_flt_in) echo 'tcp dport 1443 ct status dnat accept'; echo 'tcp dport 1443 drop' ;;
      *) exit 1 ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/conntrack" <<EOF
#!/bin/sh
echo "conntrack:\$*" >> "$T/conntrack.log"
EOF
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
[ "\$1" = tg-ws-proxy ] || exit 0
cat "$T/pidof.out" 2>/dev/null
EOF
chmod +x "$T/bin/conntrack" "$T/bin/pidof"
cat > "$T/root/bin/linux-x86_64/tg-ws-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/linux-x86_64/tg-ws-proxy"
printf 'ENABLED=1\nZ2K_RELAY_SECRET=obsolete-preserved\nZ2K_RELAY_URL=obsolete-preserved\n' > "$T/etc/config"
printf '{"legacy":"preserved"}\n' > "$T/etc/state/relay-id.json"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_LOG="$T/tmp/logs"
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_OW_ARCH=x86_64
export Z2K_TG_RUST_BIN="$T/root/bin/linux-x86_64/tg-ws-proxy"
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc"
. "$REPO/platform/openwrt/tg.sh" || exit 1
export Z2K_TG_TCP_PORTS
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo close >> "$T/procd.log"; }

z2k_ow_tg 1 || _t_bad "Rust запускается на поддерживаемой архитектуре"
assert_eq "один владелец procd" 1 "$(grep -c '^instance:z2k-tg$' "$T/procd.log")"
assert_contains "ограниченный перезапуск procd" "$T/procd.log" 'param:respawn 3600 5 5'
assert_contains "прозрачный режим Rust и IPv6 dual-stack" "$T/procd.log" '--host=:: --transparent'
assert_contains "ограничение числа соединений равно восьми" "$T/procd.log" '--max-connections=8'
assert_contains "Rust получил список портов из общей политики" "$T/procd.log" \
    "--transparent-ports=$(z2k_ow_tg_ports_csv)"
assert_contains "procd запускает обновление официальной карты DC с кэшем" "$T/procd.log" \
    "--dc-map-path=$Z2K_ETC/telegram-dc-map.json --dc-map-refresh-secs=21600"
assert_not_contains "настройки старого релея не передаются Rust" "$T/procd.log" 'Z2K_RELAY_SECRET|Z2K_RELAY_URL|relay-id-file'
_policy_port_count="$(z2k_ow_tg_ports | wc -l | tr -d ' ')"
_expected_rules=$((_policy_port_count * 4 + 3))
assert_eq "созданы правила для настроенных портов и защитные правила" "$_expected_rules" "$(grep -c '^nft:add rule' "$T/nft.log")"
for _port in $(z2k_ow_tg_ports); do
    assert_eq "TCP/$_port перенаправлен для IPv4 и IPv6 в двух хуках" 4 \
        "$(grep -c "dport $_port .*redirect to :1443" "$T/nft.log")"
done
assert_contains "метка исходящего Rust-сокета предотвращает цикл перенаправления" "$T/nft.log" 'meta mark 0x40000000 return'
assert_not_contains "обычный HTTP/80 не перенаправляется в Telegram" "$T/nft.log" 'dport 80.*redirect'
assert_not_contains "старый Go-слушатель не запускается" "$T/procd.log" 'tg-mtproxy-client|1444'
assert_eq "пользовательский файл релея сохранён для отката" '{"legacy":"preserved"}' "$(cat "$T/etc/state/relay-id.json")"

: > "$T/procd.log"; : > "$T/nft.log"
z2k_ow_tg 1 || _t_bad "повторный запуск сходится к заданному состоянию"
assert_eq "на каждый запуск создан один экземпляр procd" 1 "$(grep -c '^instance:z2k-tg$' "$T/procd.log")"
assert_eq "повторный набор правил не дублируется" "$_expected_rules" "$(grep -c '^nft:add rule' "$T/nft.log")"

printf 'ENABLED=1\nTG_PROXY_USER_DISABLED=1\n' > "$T/etc/config"
: > "$T/procd.log"; : > "$T/nft.log"
z2k_ow_tg 1
assert_eq "при пользовательском отключении нет экземпляра procd" 0 "$(grep -c '^instance:' "$T/procd.log" || true)"
assert_eq "при пользовательском отключении нет перенаправлений" 0 "$(grep -c '^nft:add rule' "$T/nft.log" || true)"

printf 'ENABLED=1\n' > "$T/etc/config"
Z2K_OW_ARCH=mips
export Z2K_OW_ARCH
: > "$T/procd.log"; : > "$T/nft.log"
assert_eq "пользователю показан статус неподдерживаемой архитектуры" 'Тип не поддерживается' "$(z2k_ow_tg_status 2>/dev/null)"
z2k_ow_tg 1
assert_eq "на неподдерживаемой архитектуре процесс procd не запускается" 0 "$(grep -c '^instance:' "$T/procd.log" || true)"
assert_eq "на неподдерживаемой архитектуре новые правила не создаются" 0 "$(grep -c '^nft:add rule' "$T/nft.log" || true)"

_t_done
