#!/bin/sh
# tests/openwrt/test_ow_tg_firewall.sh - Stage 3 Layer B: nft/argv/conntrack.
# Mock'и: nft (с состоянием таблицы), conntrack, pidof, /proc, curl, procd.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-firewall"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgfw.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/root/etc" "$T/etc" "$T/tmp" "$T/proc"
export PATH="$T/bin:$PATH"

# --- mock nft: пишет вызовы, симулирует наличие таблицы ---
cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1" = "list" ] && [ "\$2" = "table" ]; then
    [ -f "$T/no-table" ] && exit 1
    exit 0
fi
if [ -n "\$NFT_FAIL" ] && [ "\$1 \$2" = "\$NFT_FAIL" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/conntrack" <<EOF
#!/bin/sh
echo "conntrack:\$*" >> "$T/conntrack.log"
exit 0
EOF
chmod +x "$T/bin/conntrack"
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"

# --- sysroot ---
cat > "$T/root/bin/tg-mtproxy-client" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/tg-mtproxy-client"
printf 'x\n' > "$T/root/etc/z2k-roots.pem"
printf 'ENABLED=1\n' > "$T/etc/config"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_LOG="$T/tmp/logs"
export Z2K_CONFIG="$T/etc/config" Z2K_PROC_ROOT="$T/proc"
export Z2K_TG_HEALTH_DIR="$T/tmp/tg-health"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tg.sh" || { echo "FAIL[ow-tg-firewall]: source tg.sh" >&2; exit 1; }

# --- wanted-матрица ---
z2k_ow_tg_wanted && _t_ok || _t_bad "wanted при всём хорошем"
printf 'ENABLED=0\n' > "$T/etc/config"
z2k_ow_tg_wanted && _t_bad "wanted при ENABLED=0" || _t_ok
printf 'ENABLED=1\nTG_PROXY_USER_DISABLED=1\n' > "$T/etc/config"
z2k_ow_tg_wanted && _t_bad "wanted при user-disable" || _t_ok
printf 'ENABLED=1\n' > "$T/etc/config"
chmod -x "$T/root/bin/tg-mtproxy-client"
z2k_ow_tg_wanted && _t_bad "wanted без бинарника" || _t_ok
chmod +x "$T/root/bin/tg-mtproxy-client"

# --- nft apply: точные shapes ---
: > "$T/nft.log"
z2k_ow_tg_nft_apply || _t_bad "nft_apply rc"
assert_contains "set dc4 создан" "$T/nft.log" 'add set inet zapret2 z2k_tg_dc4 { type ipv4_addr; flags interval; }'
assert_contains "set dc6 создан" "$T/nft.log" 'add set inet zapret2 z2k_tg_dc6 { type ipv6_addr; flags interval; }'
assert_contains "set cdn создан" "$T/nft.log" 'add set inet zapret2 z2k_tg_cdn4 { type ipv4_addr; flags interval; }'
assert_contains "dc4 элементы" "$T/nft.log" 'add element inet zapret2 z2k_tg_dc4 { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22, 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 91.105.192.0/23, 95.161.64.0/20, 185.76.151.0/24 }'
assert_contains "dc6 элементы" "$T/nft.log" 'add element inet zapret2 z2k_tg_dc6 { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280:203::/48 }'
assert_contains "cdn элемент" "$T/nft.log" 'add element inet zapret2 z2k_tg_cdn4 { 168.119.95.238/32 }'
assert_contains "chain prerouting" "$T/nft.log" 'add chain inet zapret2 z2k_tg_dst_pre { type nat hook prerouting priority -101; }'
assert_contains "chain output nat" "$T/nft.log" 'add chain inet zapret2 z2k_tg_dst_out { type nat hook output priority -101; }'
assert_contains "chain forward" "$T/nft.log" 'add chain inet zapret2 z2k_tg_flt_fwd { type filter hook forward priority -1; }'
assert_contains "chain output filter" "$T/nft.log" 'add chain inet zapret2 z2k_tg_flt_out { type filter hook output priority -1; }'
assert_contains "chain input guard" "$T/nft.log" 'add chain inet zapret2 z2k_tg_flt_in { type filter hook input priority -1; }'
assert_contains "redirect 443 pre" "$T/nft.log" 'add rule inet zapret2 z2k_tg_dst_pre tcp dport 443 ip daddr @z2k_tg_dc4 redirect to :1443'
assert_contains "redirect 443 out" "$T/nft.log" 'add rule inet zapret2 z2k_tg_dst_out tcp dport 443 ip daddr @z2k_tg_dc4 redirect to :1443'
assert_contains "redirect 80 pre" "$T/nft.log" 'add rule inet zapret2 z2k_tg_dst_pre tcp dport 80 ip daddr @z2k_tg_cdn4 redirect to :1444'
assert_contains "redirect 80 out" "$T/nft.log" 'add rule inet zapret2 z2k_tg_dst_out tcp dport 80 ip daddr @z2k_tg_cdn4 redirect to :1444'
assert_contains "v6 reject fwd" "$T/nft.log" 'add rule inet zapret2 z2k_tg_flt_fwd tcp ip6 daddr @z2k_tg_dc6 reject with tcp reset'
assert_contains "v6 reject out" "$T/nft.log" 'add rule inet zapret2 z2k_tg_flt_out tcp ip6 daddr @z2k_tg_dc6 reject with tcp reset'
assert_contains "guard accept scoped" "$T/nft.log" 'add rule inet zapret2 z2k_tg_flt_in tcp dport { 1443, 1444 } ct status dnat accept'
assert_contains "guard drop" "$T/nft.log" 'add rule inet zapret2 z2k_tg_flt_in tcp dport { 1443, 1444 } drop'
# порядок в chain: accept СТРОГО до drop (иначе редиректнутые тоже режем)
_accept_ln="$(grep -n 'z2k_tg_flt_in tcp dport { 1443, 1444 } ct status dnat accept' "$T/nft.log" | head -1 | cut -d: -f1)"
_drop_ln="$(grep -n 'z2k_tg_flt_in tcp dport { 1443, 1444 } drop' "$T/nft.log" | head -1 | cut -d: -f1)"
if [ -n "$_accept_ln" ] && [ -n "$_drop_ln" ] && [ "$_accept_ln" -lt "$_drop_ln" ]; then
    _t_ok
else
    _t_bad "guard: accept не до drop ($_accept_ln/$_drop_ln)"
fi
# в сетах нет локальных сетей (self-dial не фаерволом)
for _local in '127\.' '10\.' '192\.168' '::1' 'fc00' 'fe80'; do
    if grep -E "add element.*($_local)" "$T/nft.log" >/dev/null 2>&1; then
        _t_bad "локальная сеть в сете: $_local"
    else
        _t_ok
    fi
done
# таблица не создаётся нами (только list/add set|chain|rule|element)
if grep -E '^nft:(add|create) table' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "glue создаёт таблицу"
else
    _t_ok
fi

# --- идемпотентность: второй прогон = те же вызовы, дублей в состоянии нет ---
cp "$T/nft.log" "$T/nft1.log"
: > "$T/nft.log"
z2k_ow_tg_nft_apply || _t_bad "nft_apply повтор rc"
assert_eq "повтор даёт те же вызовы" "$(cat "$T/nft1.log")" "$(cat "$T/nft.log")"

# --- таблицы нет -> отказ до записей ---
: > "$T/nft.log"
: > "$T/no-table"
z2k_ow_tg_nft_apply 2>/dev/null && _t_bad "apply без таблицы принят" || _t_ok
if grep -E '^nft:add rule' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "правила пытались писать без таблицы"
else
    _t_ok
fi
rm -f "$T/no-table"

# --- remove: chains да (5), sets нет; cleanup full: и sets ---
: > "$T/nft.log"
z2k_ow_tg_nft_remove
assert_contains "flush pre" "$T/nft.log" 'flush chain inet zapret2 z2k_tg_dst_pre'
assert_contains "delete fwd" "$T/nft.log" 'delete chain inet zapret2 z2k_tg_flt_fwd'
assert_contains "delete input guard" "$T/nft.log" 'delete chain inet zapret2 z2k_tg_flt_in'
assert_eq "remove: chains сняты (5 delete)" "5" "$(grep -c '^nft:delete chain' "$T/nft.log")"
if grep -E '^nft:delete set' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "обычный remove снёс sets"
else
    _t_ok
fi
: > "$T/nft.log"
z2k_ow_tg_nft_remove full
assert_contains "full сносит set dc4" "$T/nft.log" 'delete set inet zapret2 z2k_tg_dc4'
assert_contains "full сносит set dc6" "$T/nft.log" 'delete set inet zapret2 z2k_tg_dc6'
assert_contains "full сносит set cdn" "$T/nft.log" 'delete set inet zapret2 z2k_tg_cdn4'

# --- conntrack: ровно TG CIDR + CDN, ничего больше ---
: > "$T/conntrack.log"
z2k_ow_tg_conntrack_flush
assert_eq "conntrack вызовов" "11" "$(grep -c '^conntrack:-D -d' "$T/conntrack.log")"
assert_contains "conntrack sample" "$T/conntrack.log" 'conntrack:-D -d 149.154.160.0/20'
assert_contains "conntrack cdn" "$T/conntrack.log" 'conntrack:-D -d 168.119.95.238/32'
if grep -vE '^conntrack:-D -d (149\.154\.160\.0/20|91\.108\.(4|8|12|16|20|56)\.0/22|91\.105\.192\.0/23|95\.161\.64\.0/20|185\.76\.151\.0/24|168\.119\.95\.238/32)$' "$T/conntrack.log" >/dev/null 2>&1; then
    _t_bad "conntrack задел чужое"
else
    _t_ok
fi

# --- argv: точная команда, overrides, тишина builder'а ---
_rec() { printf 'ARGV:%s\n' "$*" >> "$T/argv.log"; }
: > "$T/argv.log"
z2k_ow_tg_with_argv _rec
assert_contains "оба listen" "$T/argv.log" "--listen=:1443 --listen=:1444"
assert_contains "timeout" "$T/argv.log" "--timeout=15m"
assert_contains "бинарник из Z2K_BIN" "$T/argv.log" "$T/root/bin/tg-mtproxy-client"
if grep -q 'tunnel-secret' "$T/argv.log"; then
    _t_bad "secret без override"
else
    _t_ok
fi
printf 'ENABLED=1\nZ2K_RELAY_SECRET=abc123\nZ2K_RELAY_URL=wss://example.test/ws\n' > "$T/etc/config"
: > "$T/argv.log"
_out="$(z2k_ow_tg_with_argv _rec 2>"$T/argv.err")"
assert_contains "override secret" "$T/argv.log" "--tunnel-secret=abc123"
assert_contains "override url" "$T/argv.log" "--tunnel-url=wss://example.test/ws"
assert_eq "builder молчит в stdout" "" "$_out"
assert_eq "builder молчит в stderr" "" "$(cat "$T/argv.err")"
printf 'ENABLED=1\n' > "$T/etc/config"

# --- TLS env через stub-procd ---
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }
: > "$T/procd.log"
z2k_ow_tg_start_instance || _t_bad "start_instance rc"
assert_contains "instance z2k-tg" "$T/procd.log" "instance:z2k-tg"
assert_contains "GODEBUG" "$T/procd.log" "param:command "
assert_contains "GODEBUG env" "$T/procd.log" "param:env GODEBUG=asyncpreemptoff=1"
assert_contains "roots exported" "$T/procd.log" "param:env SSL_CERT_FILE=$T/root/etc/z2k-roots.pem"
assert_contains "respawn bounded" "$T/procd.log" "param:respawn 3600 5 5"
assert_contains "instance closed" "$T/procd.log" "close"
# корней нет -> env пропущен (пул Go не пустеет)
rm -f "$T/root/etc/z2k-roots.pem"
: > "$T/procd.log"
z2k_ow_tg_start_instance >/dev/null 2>&1 || _t_bad "start_instance без корней rc"
if grep -q 'SSL_CERT_FILE' "$T/procd.log"; then
    _t_bad "SSL_CERT_FILE при отсутствующем bundle"
else
    _t_ok
fi
printf 'x\n' > "$T/root/etc/z2k-roots.pem"

# --- pids: матч только по :1443 ---
mkdir -p "$T/proc/111" "$T/proc/222" "$T/proc/333"
printf 'tg-mtproxy-client --listen=:1443 --listen=:1444 --timeout=15m' | tr ' ' '\0' > "$T/proc/111/cmdline"
printf 'tg-mtproxy-client --listen=:1444 --timeout=15m' | tr ' ' '\0' > "$T/proc/222/cmdline"
printf 'some-other-daemon' > "$T/proc/333/cmdline"
printf '111 222 333\n' > "$T/pidof.out"
assert_eq "матч только :1443" "111" "$(z2k_ow_tg_pids | tr '\n' ' ' | tr -d ' ')"
printf '\n' > "$T/pidof.out"
z2k_ow_tg_running && _t_bad "running при пустом pidof" || _t_ok

_t_done
