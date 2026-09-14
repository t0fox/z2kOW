#!/bin/sh
# tests/openwrt/test_ow_rt_firewall.sh - Stage 4 Layer B: nft/argv/whitelist.
# Mock'и: nft, pidof, /proc, procd. Реальный код rt.sh in-process.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-rt-firewall"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtfw.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/root/lists" "$T/etc" "$T/tmp" "$T/proc"
export PATH="$T/bin:$PATH"

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
if [ "\$1" = "list" ] && [ "\$2" = "table" ]; then
    [ -f "$T/no-table" ] && exit 1
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"

cat > "$T/root/bin/z2k-rt-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-rt-proxy"
printf 'ENABLED=1\n' > "$T/etc/config"
printf 'user-domain.example\n' > "$T/root/lists/whitelist.txt"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_PROC_ROOT="$T/proc"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/rt.sh" || { echo "FAIL[ow-rt-firewall]: source" >&2; exit 1; }

# --- wanted-матрица ---
z2k_ow_rt_wanted && _t_ok || _t_bad "wanted при всём хорошем"
printf 'ENABLED=0\n' > "$T/etc/config"
z2k_ow_rt_wanted && _t_bad "wanted при ENABLED=0" || _t_ok
printf 'ENABLED=1\n' > "$T/etc/config"
chmod -x "$T/root/bin/z2k-rt-proxy"
z2k_ow_rt_wanted && _t_bad "wanted без бинарника" || _t_ok
chmod +x "$T/root/bin/z2k-rt-proxy"

# --- nft apply: точные shapes, без sets ---
: > "$T/nft.log"
z2k_ow_rt_nft_apply || _t_bad "nft_apply rc"
assert_contains "chain pre" "$T/nft.log" 'add chain inet zapret2 z2k_rt_dst_pre { type nat hook prerouting priority -101; }'
assert_contains "chain out" "$T/nft.log" 'add chain inet zapret2 z2k_rt_dst_out { type nat hook output priority -101; }'
assert_contains "chain in" "$T/nft.log" 'add chain inet zapret2 z2k_rt_flt_in { type filter hook input priority -1; }'
assert_contains "redirect pre" "$T/nft.log" 'add rule inet zapret2 z2k_rt_dst_pre tcp dport 443 ip daddr 10.171.171.171 redirect to :1445'
assert_contains "redirect out" "$T/nft.log" 'add rule inet zapret2 z2k_rt_dst_out tcp dport 443 ip daddr 10.171.171.171 redirect to :1445'
assert_contains "guard accept" "$T/nft.log" 'add rule inet zapret2 z2k_rt_flt_in tcp dport 1445 ct status dnat accept'
assert_contains "guard drop" "$T/nft.log" 'add rule inet zapret2 z2k_rt_flt_in tcp dport 1445 drop'
assert_contains "v6 fwd chain" "$T/nft.log" 'add chain inet zapret2 z2k_rt_flt6_fwd { type filter hook forward priority -1; }'
assert_contains "v6 out chain" "$T/nft.log" 'add chain inet zapret2 z2k_rt_flt6_out { type filter hook output priority -1; }'
assert_contains "v6 reject fwd" "$T/nft.log" 'add rule inet zapret2 z2k_rt_flt6_fwd ip6 daddr 2001:db8::1:1445 tcp dport 443 reject with icmpv6 type port-unreachable'
assert_contains "v6 reject out" "$T/nft.log" 'add rule inet zapret2 z2k_rt_flt6_out ip6 daddr 2001:db8::1:1445 tcp dport 443 reject with icmpv6 type port-unreachable'
assert_eq "правил 6" "6" "$(grep -c '^nft:add rule' "$T/nft.log")"
# sets нет вообще (один /32 — set избыточен)
if grep -E '^nft:(add|flush|delete) set' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "RT завёл sets"
else
    _t_ok
fi
# таблицы не создаём, flowtable/flow-add нет (структурное освобождение)
if grep -E '^nft:(add|create) table' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "glue создаёт таблицу"
else
    _t_ok
fi
if grep -Ei 'flowtable|flow add|offload' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "offload-конструкции в наших chains"
else
    _t_ok
fi
# порядок guard: accept до drop
_accept_ln="$(grep -n 'z2k_rt_flt_in tcp dport 1445 ct status dnat accept' "$T/nft.log" | head -1 | cut -d: -f1)"
_drop_ln="$(grep -n 'z2k_rt_flt_in tcp dport 1445 drop' "$T/nft.log" | head -1 | cut -d: -f1)"
if [ -n "$_accept_ln" ] && [ -n "$_drop_ln" ] && [ "$_accept_ln" -lt "$_drop_ln" ]; then
    _t_ok
else
    _t_bad "guard: accept не до drop"
fi

# --- идемпотентность ---
cp "$T/nft.log" "$T/nft1.log"
: > "$T/nft.log"
z2k_ow_rt_nft_apply || _t_bad "повтор rc"
assert_eq "повтор даёт те же вызовы" "$(cat "$T/nft1.log")" "$(cat "$T/nft.log")"

# --- таблицы нет -> отказ ---
: > "$T/nft.log"
: > "$T/no-table"
z2k_ow_rt_nft_apply 2>/dev/null && _t_bad "apply без таблицы принят" || _t_ok
rm -f "$T/no-table"

# --- remove: 3 chains ---
: > "$T/nft.log"
z2k_ow_rt_nft_remove
assert_eq "delete chains 5" "5" "$(grep -c '^nft:delete chain' "$T/nft.log")"
assert_contains "guard chain снесён" "$T/nft.log" 'delete chain inet zapret2 z2k_rt_flt_in'

# --- argv: точная команда upstream + so-mark (p-84.17 parity) ---
_rec() { printf 'ARGV:%s\n' "$*" >> "$T/argv.log"; }
: > "$T/argv.log"
_out="$(z2k_ow_rt_with_argv _rec 2>"$T/argv.err")"
assert_contains "бинарник+порты" "$T/argv.log" "$T/root/bin/z2k-rt-proxy --listen=:1445 --timeout=15m"
assert_eq "ровно 4 argv (+so-mark builtin)" "1" "$(grep -c "^ARGV:$T/root/bin/z2k-rt-proxy --listen=:1445 --timeout=15m --so-mark=0x40000000$" "$T/argv.log")"
assert_eq "builder молчит" "" "$_out$(cat "$T/argv.err")"

# --- whitelist ensure (RT20): append exact-5, чужое цело ---
z2k_ow_rt_desync_exclude || _t_bad "exclude rc"
for _d in rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc; do
    assert_contains "exclude $_d" "$T/root/lists/whitelist.txt" "$_d"
done
assert_contains "user-строка цела" "$T/root/lists/whitelist.txt" "user-domain.example"
_before="$(cksum "$T/root/lists/whitelist.txt")"
z2k_ow_rt_desync_exclude || _t_bad "exclude повтор rc"
assert_eq "повтор не дописывает" "$_before" "$(cksum "$T/root/lists/whitelist.txt")"
# exact-line, не suffix: foo.rutracker.org не покрывает rutracker.org
printf 'foo.rutracker.org\n' > "$T/root/lists/whitelist.txt"
printf 'user-domain.example\n' >> "$T/root/lists/whitelist.txt"
z2k_ow_rt_desync_exclude || _t_bad "exclude после сабдомена rc"
if grep -qxF 'rutracker.org' "$T/root/lists/whitelist.txt"; then
    _t_ok
else
    _t_bad "exact rutracker.org не добавлен (suffix посчитан покрытием)"
fi

# --- pids: матч по :1445 ---
mkdir -p "$T/proc/777" "$T/proc/888"
printf 'z2k-rt-proxy --listen=:1445 --timeout=15m' | tr ' ' '\0' > "$T/proc/777/cmdline"
printf 'something-else' > "$T/proc/888/cmdline"
printf '777 888\n' > "$T/pidof.out"
assert_eq "матч только :1445" "777" "$(z2k_ow_rt_pids | tr '\n' ' ' | tr -d ' ')"
printf '\n' > "$T/pidof.out"
z2k_ow_rt_running && _t_bad "running при пустом pidof" || _t_ok

# --- procd instance: exact params ---
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }
: > "$T/procd.log"
z2k_ow_rt_start_instance || _t_bad "start_instance rc"
assert_contains "instance z2k-rt" "$T/procd.log" "instance:z2k-rt"
assert_contains "respawn bounded" "$T/procd.log" "param:respawn 3600 5 5"
assert_contains "GODEBUG" "$T/procd.log" "param:env GODEBUG=asyncpreemptoff=1"
assert_contains "instance closed" "$T/procd.log" "close"

_t_done
