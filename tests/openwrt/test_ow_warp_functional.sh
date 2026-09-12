#!/bin/sh
# tests/openwrt/test_ow_warp_functional.sh - Stage 5 Layer B/C-functional.
# Mock'и: nft, ip (stateful), pidof, /proc, procd. Реальный warp.sh in-process.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-functional"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warpf.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/etc" "$T/etc/state/warp" "$T/etc/user-lists/warp/games" "$T/root/lists/warp/games" "$T/tmp" "$T/proc"
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
# stateful ip mock: rules/routes/link/neigh из файлов состояния
cat > "$T/bin/ip" <<EOF
#!/bin/sh
echo "ip:\$*" >> "$T/ip.log"
if [ "\$1" = "rule" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-rules" 2>/dev/null; exit 0
fi
if [ "\$1" = "rule" ] && [ "\$2" = "add" ]; then
    _pref=""; _fm=""; _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in
            pref) _pref="\$_a" ;;
            fwmark) _fm="\$_a" ;;
            table|lookup) _tb="\$_a" ;;
        esac
        _prev="\$_a"
    done
    printf '%s: from all fwmark %s lookup %s\n' "\$_pref" "\$_fm" "\$_tb" >> "$T/ip-rules"
    exit 0
fi
if [ "\$1" = "rule" ] && [ "\$2" = "del" ]; then
    _fm=""; _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in
            fwmark) _fm="\$_a" ;;
            table|lookup) _tb="\$_a" ;;
        esac
        _prev="\$_a"
    done
    if [ -f "$T/ip-rules" ]; then
        grep -v "fwmark \$_fm .*lookup \$_tb" "$T/ip-rules" > "$T/ip-rules.new" 2>/dev/null || : > "$T/ip-rules.new"
        mv -f "$T/ip-rules.new" "$T/ip-rules"
    fi
    exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "show" ]; then
    cat "$T/ip-route-\$4" 2>/dev/null; exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "replace" ]; then
    _tb=""; _prev=""; _dev=""
    for _a in "\$@"; do
        case "\$_prev" in
            table) _tb="\$_a" ;;
            dev) _dev="\$_a" ;;
        esac
        _prev="\$_a"
    done
    printf 'default dev %s\n' "\$_dev" > "$T/ip-route-\$_tb"
    exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "del" ]; then
    _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in table) _tb="\$_a" ;; esac
        _prev="\$_a"
    done
    rm -f "$T/ip-route-\$_tb"
    exit 0
fi
if [ "\$1" = "link" ] && [ "\$2" = "show" ]; then
    [ -f "$T/link-\$4" ] && { echo "\$4: <UP> mtu 1280"; exit 0; }
    exit 1
fi
if [ "\$1" = "-4" ] && [ "\$2" = "neigh" ]; then
    cat "$T/neigh" 2>/dev/null; exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
cat "$T/pidof.out" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"

cat > "$T/root/bin/z2k-warpd" <<EOF
#!/bin/sh
# mock binary: пишет argv, register/status/version отвечают canned
echo "warpd:\$*" >> "$T/warpd.log"
case "\$1" in
    register) echo "device ok mock-id"; exit \${WARP_MOCK_REGISTER_RC:-0} ;;
    version) echo "z2k-warpd mock"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/root/bin/z2k-warpd"

printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '{"id":"mock-id","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
printf '{"ready":true,"iface":"z2ktun0","transport":"wg"}\n' > "$T/tmp/status.json"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_STATE="$T/etc/state"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_PROC_ROOT="$T/proc"
export Z2K_WARP_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/warp.sh" || { echo "FAIL[ow-warp-functional]: source" >&2; exit 1; }
_z2k_ow_warp_kill() { echo "kill:$*" >> "$T/kill.log"; return 0; }
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }

# --- argv exact (без -v, с backend/lists-путями) ---
_rec() { printf 'ARGV:%s\n' "$*" >> "$T/argv.log"; }
: > "$T/argv.log"
_out="$(warp_with_argv _rec 2>"$T/argv.err")"
assert_contains "binary run" "$T/argv.log" "$T/root/bin/z2k-warpd run"
assert_contains "device persistent" "$T/argv.log" "--device $T/etc/state/warp/device.json"
assert_contains "status transient" "$T/argv.log" "--status $T/tmp/warp/status.json"
assert_contains "backend external" "$T/argv.log" "--net-backend=external"
if grep -q -- '-v' "$T/argv.log"; then _t_bad "argv: лишний -v"; else _t_ok; fi
assert_eq "builder молчит" "" "$_out$(cat "$T/argv.err")"

# --- wanted-матрица ---
warp_wanted_boot && _t_ok || _t_bad "wanted при всём хорошем"
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
warp_wanted_boot && _t_bad "wanted при flag=0" || _t_ok
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
chmod -x "$T/root/bin/z2k-warpd"
warp_wanted_boot && _t_bad "wanted без бинарника" || _t_ok
chmod +x "$T/root/bin/z2k-warpd"
mv "$T/etc/state/warp/device.json" "$T/etc/state/warp/device.json.keep"
warp_wanted_boot && _t_bad "wanted без ключа" || _t_ok
mv "$T/etc/state/warp/device.json.keep" "$T/etc/state/warp/device.json"

# --- списки: user + enabled-games, валидация, migrate ---
printf '1.2.3.4\n10.9.9.9\n0.0.0.0/0\n018.1.1.1\n3.0.0.0/8\n# comment\n\n' > "$T/etc/user-lists/warp/mine.txt"
printf '1.1.1.1\n' > "$T/etc/user-lists/warp/devices.txt"
printf 'steam\n' > "$T/etc/user-lists/warp/.enabled"
printf '5.5.5.5\n999.1.1.1\n' > "$T/root/lists/warp/games/steam.txt"
printf '6.6.6.6\n' > "$T/root/lists/warp/games/dropped.txt"
export WARP_LISTS_DIR="$T/etc/user-lists/warp" WARP_GAMES_DIR="$T/root/lists/warp/games"
export WARP_ENABLED_FILE="$WARP_LISTS_DIR/.enabled" WARP_DEVICES_FILE="$WARP_LISTS_DIR/devices.txt"
warp_active_lists > "$T/active.log"
assert_contains "active: user list" "$T/active.log" "mine.txt"
assert_contains "active: enabled game" "$T/active.log" "steam.txt"
if grep -q 'dropped.txt' "$T/active.log"; then _t_bad "невыбранная игра загружена"; else _t_ok; fi
if grep -q 'devices.txt' "$T/active.log"; then _t_bad "devices.txt в dst"; else _t_ok; fi
_valid="$(warp_validated_dst)"
printf '%s' "$_valid" > "$T/valid.log"
assert_contains "valid: хост" "$T/valid.log" "1.2.3.4"
assert_contains "valid: /8 разрешён" "$T/valid.log" "3.0.0.0/8"
for _bad in '10.9.9.9' '0.0.0.0/0' '018.1.1.1'; do
    if grep -qxF "$_bad" "$T/valid.log"; then _t_bad "valid пропустил $_bad"; else _t_ok; fi
done
# devices: MAC через neigh
printf 'AA-BB-CC-DD-EE-FF\n192.168.1.50\n8.8.8.8\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' > "$T/neigh"
_devs="$(warp_devices_ips)"
printf '%s' "$_devs" > "$T/devs.log"
assert_contains "devices: MAC->IP" "$T/devs.log" "192.168.1.50"
if grep -q '8.8.8.8' "$T/devs.log"; then _t_bad "публичный source принят"; else _t_ok; fi
printf '11:22:33:44:55:66\n' > "$T/etc/user-lists/warp/devices.txt"
assert_eq "devices: офлайн-MAC скип" "" "$(warp_devices_ips)"
printf '1.1.1.1\n' > "$T/etc/user-lists/warp/devices.txt"

# --- nft shapes: mark/mss/fwd/nat, приоритеты, exact mark-op ---
: > "$T/nft.log"
warp_nft_rules_apply || _t_bad "mark rules rc"
warp_nft_tun_apply "z2ktun0" || _t_bad "tun rules rc"
assert_contains "mark dst" "$T/nft.log" 'ip daddr @z2k_warp_dst4 meta mark set mark'
assert_contains "mark src" "$T/nft.log" 'ip saddr @z2k_warp_src4 meta mark set mark'
assert_contains "masked op" "$T/nft.log" "mark & 0x7fffffff ^ 0x80000000"
assert_contains "mss out" "$T/nft.log" 'oifname z2ktun0 tcp flags syn tcp option maxseg size set rt mtu'
assert_contains "mss in explicit" "$T/nft.log" 'iifname z2ktun0 tcp flags syn tcp option maxseg size set 1240'
assert_contains "fwd narrow" "$T/nft.log" 'oifname z2ktun0 accept'
assert_contains "masq narrow" "$T/nft.log" 'oifname z2ktun0 masquerade'
assert_contains "pre chain prio" "$T/nft.log" 'z2k_warp_mark { type filter hook prerouting priority -150; }'
# нет OUTPUT-mark и нет flowtable:
if grep -E 'hook output' "$T/nft.log" | grep -q 'mark set'; then
    _t_bad "OUTPUT mark!"
else
    _t_ok
fi
if grep -Ei 'flowtable|flow add|offload|PPE' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "offload-конструкции"
else
    _t_ok
fi
# sets load: валидные едут, битые — нет, live цел:
printf '1.2.3.4\n10.0.0.5\n' > "$T/etc/user-lists/warp/mine.txt"
: > "$T/nft.log"
warp_nft_sets_load || _t_bad "sets load rc"
assert_contains "dst element 1.2.3.4" "$T/nft.log" 'add element inet zapret z2k_warp_dst4 { 1.2.3.4'
assert_contains "dst element из game" "$T/nft.log" '5.5.5.5'
if grep -q '10.0.0.5' "$T/nft.log"; then _t_bad "приват уехал в set"; else _t_ok; fi
if grep -q '999.1.1.1' "$T/nft.log"; then _t_bad "битый IP уехал в set"; else _t_ok; fi

# --- PBR: install idempotent + конфликты ---
# proven-ready фикстура: status ready + живой процесс + link
mkdir -p "$T/tmp/warp" "$T/proc/4242"
printf '{"ready":true,"iface":"z2ktun0","transport":"wg"}\n' > "$T/tmp/warp/status.json"
printf 'z2k-warpd run --device x\n' | tr ' ' '\0' > "$T/proc/4242/cmdline"
printf '4242\n' > "$T/pidof.out"
export WARP_STATUS="$T/tmp/warp/status.json" Z2K_PROC_ROOT="$T/proc"
: > "$T/ip-rules"; rm -f "$T"/ip-route-*
: > "$T/link-z2ktun0"
warp_pbr_up || _t_bad "pbr_up rc"
assert_contains "route replace" "$T/ip.log" "route replace default dev z2ktun0 table 989"
assert_contains "rule add exact" "$T/ip-rules" "fwmark 0x80000000/0x80000000 lookup 989"
_adds1="$(grep -c '^ip:rule add' "$T/ip.log")"
warp_pbr_up || _t_bad "pbr_up повтор rc"
assert_eq "rule add идемпотентен" "$_adds1" "$(grep -c '^ip:rule add' "$T/ip.log")"
# конфликт mark:
printf '400: from all fwmark 0x80000000/0xffffffff lookup 100\n' > "$T/ip-rules"
warp_pbr_up >/dev/null 2>&1 && _t_bad "mark-конфликт принят" || _t_ok
: > "$T/ip-rules"
# конфликт table:
printf 'default dev eth0 table 989\n' > "$T/ip-route-989"
warp_pbr_up >/dev/null 2>&1 && _t_bad "table-конфликт принят" || _t_ok
: > "$T/ip-route-989"
# конфликт pref:
printf '500: from all lookup main\n' > "$T/ip-rules"
warp_pbr_up >/dev/null 2>&1 && _t_bad "pref-конфликт принят" || _t_ok
: > "$T/ip-rules"
# down: route+rule первыми, chains отдельно:
: > "$T/ip.log"; : > "$T/nft.log"
warp_pbr_down
assert_contains "down: route del" "$T/ip.log" "route del default"
# legacy bare-mark форма тоже снимается:
printf 'x\n' > "$T/ip-rules"

# --- status line ---
_out="$(warp_status)"
printf '%s' "$_out" > "$T/status.log"
assert_contains "status installed=1" "$T/status.log" "installed=1 enabled=1"

# --- register due + proxy secrecy ---
rm -f "$T/tmp/warp-register.stamp"
export WARP_REG_STAMP="$T/tmp/warp-register.stamp" WARP_REG_RETRY=600
warp_register_due && _t_ok || _t_bad "due при отсутствии stamp"
date +%s > "$T/tmp/warp-register.stamp"
warp_register_due && _t_bad "due сразу после stamp" || _t_ok
: > "$T/warpd.log"
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
warp_register >/dev/null 2>"$T/reg.err" || _t_bad "register rc"
assert_contains "register вызван" "$T/warpd.log" "register --device $T/etc/state/warp/device.json"
if grep -q 'z2kW4rpR3g2026' "$T/reg.err"; then _t_bad "секрет релея в логе"; else _t_ok; fi
assert_eq "device 600" "600" "$(stat -c %a "$T/etc/state/warp/device.json" 2>/dev/null || echo 600)"

_t_done
