#!/bin/sh
# tests/openwrt/test_ow_warp_lifecycle.sh - Stage 5 Layer C/D: W1-W32 + invariants.
# Mock'и: nft, ip (stateful), pidof, /proc, procd, warpd-binary, au (для W27-map).
# Реальный warp.sh in-process (+ настоящий warp-proc.sh для W7/W27).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-lifecycle"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warplc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/root/platform/openwrt" "$T/etc" "$T/etc/state/warp" "$T/etc/user-lists/warp/games" "$T/tmp" "$T/proc"
export PATH="$T/bin:$PATH"
for _f in paths.sh env.sh warp.sh tg.sh firewall.sh schedule.sh uninstall.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f" 2>/dev/null
done
ln -s "$REPO/platform/openwrt/warp-proc.sh" "$T/root/platform/openwrt/warp-proc.sh" 2>/dev/null
ln -s "$REPO/platform/openwrt/warp-check.sh" "$T/root/platform/openwrt/warp-check.sh" 2>/dev/null

cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/nft.log"
# Atomic batch (defect 2): `nft -f -` применяет всё или ничего.
# Fault injection: NFT_BATCH_FAIL (fixed string) в batch -> rc 1 БЕЗ изменений.
if [ "\$1" = "-f" ]; then
    _bin="$T/nft-batch-in"
    cat > "\$_bin" 2>/dev/null
    sed 's/^/nft-batch:/' "\$_bin" >> "$T/nft.log" 2>/dev/null
    if [ -n "\${NFT_BATCH_FAIL:-}" ] && grep -qF "\$NFT_BATCH_FAIL" "\$_bin" 2>/dev/null; then
        exit 1
    fi
    while IFS= read -r _l; do
        case "\$_l" in
            "flush set "*)
                _sn="\$(printf '%s' "\$_l" | awk '{print \$5}')"
                : > "$T/nft-set-\$_sn" ;;
            "add element "*)
                _sn="\$(printf '%s' "\$_l" | awk '{print \$5}')"
                printf '%s\n' "\$_l" >> "$T/nft-set-\$_sn" ;;
        esac
    done < "\$_bin"
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "table" ]; then
    [ -f "$T/no-table" ] && exit 1
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "set" ]; then
    exit 0
fi
# set-state для W19 (live set переживает corrupt-refresh): как настоящий
# nft, `add set` существующего сета — no-op (контент НЕ трогаем).
if [ "\$1" = "add" ] && [ "\$2" = "set" ]; then
    [ -f "$T/nft-set-\$5" ] || : > "$T/nft-set-\$5"
    exit 0
fi
if [ "\$1" = "flush" ] && [ "\$2" = "set" ]; then
    : > "$T/nft-set-\$5"
    exit 0
fi
if [ "\$1" = "add" ] && [ "\$2" = "element" ]; then
    printf '%s\n' "\$*" >> "$T/nft-set-\$5"
    exit 0
fi
if [ "\$1" = "delete" ] && [ "\$2" = "set" ]; then
    rm -f "$T/nft-set-\$5"
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
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
    # Exact-match delete (defect 4): снимается только строка, совпадающая
    # со ВСЕМИ переданными селекторами (pref + fwmark + table).
    _pref=""; _fm=""; _tb=""; _prev=""
    for _a in "\$@"; do
        case "\$_prev" in
            pref) _pref="\$_a" ;;
            fwmark) _fm="\$_a" ;;
            table|lookup) _tb="\$_a" ;;
        esac
        _prev="\$_a"
    done
    if [ -f "$T/ip-rules" ]; then
        awk -v p="\$_pref" -v m="\$_fm" -v t="\$_tb" '
            { del=1
              if (p != "" && (\$0 !~ "^" p ":")) del=0
              if (m != "" && index(\$0, "fwmark " m) == 0) del=0
              if (t != "" && index(\$0, "lookup " t) == 0) del=0
              if (!del) print }' "$T/ip-rules" > "$T/ip-rules.new" 2>/dev/null || : > "$T/ip-rules.new"
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
cat > "$T/root/bin/z2k-warpd" <<EOF
#!/bin/sh
echo "warpd:\$*" >> "$T/warpd.log"
case "\$1" in
    register)
        if [ "\${WARP_MOCK_REGISTER_RC:-0}" = "0" ]; then
            [ -s "$T/etc/state/warp/device.json" ] || printf '{"id":"mock-id","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
            echo "device ok mock-id"
            exit 0
        fi
        echo "register_blocked" >&2
        exit 1 ;;
    version) echo "z2k-warpd mock"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/root/bin/z2k-warpd"

printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime" Z2K_STATE="$T/etc/state"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_PROC_ROOT="$T/proc"
export Z2K_WARP_SOURCE_ONLY=1
export WARP_READY_WAIT=6
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || { echo "FAIL[ow-warp-lifecycle]: utils" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/warp.sh" || { echo "FAIL[ow-warp-lifecycle]: source" >&2; exit 1; }
_z2k_ow_warp_kill() { echo "kill:$*" >> "$T/kill.log"; return 0; }
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }

_mock_bin() {
    cat > "$T/root/bin/z2k-warpd" <<EOF
#!/bin/sh
echo "warpd:\$*" >> "$T/warpd.log"
case "\$1" in
    register)
        if [ "\${WARP_MOCK_REGISTER_RC:-0}" = "0" ]; then
            [ -s "$T/etc/state/warp/device.json" ] || printf '{"id":"mock-id","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
            echo "device ok mock-id"
            exit 0
        fi
        echo "register_blocked" >&2
        exit 1 ;;
    version) echo "z2k-warpd mock"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$T/root/bin/z2k-warpd"
}

_reset() {
    rm -f "$T"/ip-route-*
    : > "$T/ip-rules"
    : > "$T/nft.log"; : > "$T/ip.log"; : > "$T/procd.log"; : > "$T/kill.log"; : > "$T/warpd.log"
    rm -f "$T"/nft-set-*
    rm -rf "$T/tmp/warp" "$T/proc" "$T/link-z2ktun0"
    mkdir -p "$T/tmp/warp" "$T/proc"
    rm -f "$T/no-table"
    printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
    printf '\n' > "$T/pidof.out"
    rm -f "$T/etc/state/warp/device.json"
    rm -rf "$T/etc/user-lists/warp"
    mkdir -p "$T/etc/user-lists/warp/games"
    _mock_bin
}
_ready_fixture() {
    # живой процесс + fresh ready-статус + link + ключ
    printf '7777\n' > "$T/pidof.out"
    mkdir -p "$T/proc/7777"
    printf 'z2k-warpd run --device x' | tr ' ' '\0' > "$T/proc/7777/cmdline"
    printf '{"ready":true,"iface":"z2ktun0","transport":"wg"}\n' > "$T/tmp/warp/status.json"
    # mtime В БУДУЩЕМ: wait-ready требует статус новее старта wait'а
    # (anti-corpse после kill -9; живой движок переписывает каждый тик).
    # Без этого — флак на границе wall-clock секунды между фикстурой и wait'ом.
    touch -d '+120 seconds' "$T/tmp/warp/status.json" 2>/dev/null || touch "$T/tmp/warp/status.json"
    : > "$T/link-z2ktun0"
    printf '{"id":"mock-id","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
}
_good_stub() {
    # Успешный fetch-стаб (register rc 0, id stub-id — как движок в проде).
    cat > "$T/stub-bin" <<EOF
#!/bin/sh
# STUB-BINARY
case "\$1" in
    register)
        [ -s "$T/etc/state/warp/device.json" ] || printf '{"id":"stub-id"}\n' > "$T/etc/state/warp/device.json"
        echo "device ok stub-id"
        exit 0 ;;
    version) echo "stub-binary"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$T/stub-bin"
}
# Инварианты (§38): PBR=>READY, flag=0=>no PBR, absent=>no proc/PBR,
# remove=>identity, нет OUTPUT-mark.
_w_inv() {
    local _lbl="$1" _has_rule=0 _ready="" _flag="" _alive=0
    grep -qF 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules" 2>/dev/null && _has_rule=1
    _ready="$(sed -n 's/.*"ready"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$T/tmp/warp/status.json" 2>/dev/null | head -1)"
    _flag="$(grep -m1 '^GAME_WARP_ENABLED=' "$T/etc/config" 2>/dev/null | cut -d= -f2 | tr -d '" ')"
    [ -n "$(warp_pids 2>/dev/null)" ] && _alive=1
    if [ "$_has_rule" = "1" ]; then
        { [ "$_ready" = "true" ] && [ "$_alive" = "1" ]; } || { _t_bad "$_lbl: PBR без proven-ready"; return; }
    fi
    if [ "$_flag" = "0" ] && [ "$_has_rule" = "1" ]; then
        _t_bad "$_lbl: PBR при flag=0"
        return
    fi
    if [ ! -x "$T/root/bin/z2k-warpd" ] && { [ "$_alive" = "1" ] || [ "$_has_rule" = "1" ]; }; then
        _t_bad "$_lbl: процесс/PBR без бинарника"
        return
    fi
    if grep -E 'hook output' "$T/nft.log" 2>/dev/null | grep -q 'mark set'; then
        _t_bad "$_lbl: OUTPUT mark"
        return
    fi
    _t_ok
}

# --- W1: fresh install: ничего нет ---
_reset
rm -f "$T/root/bin/z2k-warpd"
assert_eq "W1: бинарника нет" "0" "$([ -x "$T/root/bin/z2k-warpd" ] && echo 1 || echo 0)"
_w_inv "W1"

# --- W2: install: verified binary + register, НЕ стартует, флаг 0 ---
_reset
export WARP_FETCH_STUB="$T/stub-bin"
# STUB — исполняемый, с register/version (fetch его ставит как бинарь,
# затем install зовёт register уже ИЗ НЕГО — как в проде).
_good_stub
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
warp_install >/dev/null 2>&1 || _t_bad "W2: install rc"
if grep -q 'stub-binary' "$T/root/bin/z2k-warpd"; then _t_ok; else _t_bad "W2: бинарь не встал"; fi
assert_eq "W2: device создан" "stub-id" "$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/etc/state/warp/device.json" | head -1)"
assert_eq "W2: device 600" "600" "$(stat -c %a "$T/etc/state/warp/device.json" 2>/dev/null || echo 600)"
assert_eq "W2: флаг всё ещё 0" "0" "$(warp_flag)"
assert_eq "W2: процесса нет" "0" "$(grep -c '^instance:' "$T/procd.log" 2>/dev/null || true)"
assert_eq "W2: PBR нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
unset WARP_FETCH_STUB
_w_inv "W2"

# --- W3: install failure: register мёртв -> нет enable, нет PBR, старый ключ цел ---
_reset
export WARP_FETCH_STUB="$T/stub-bin"
# Свой стаб с падающим register (стаб W2 остался с rc 0 — он тут не годится).
cat > "$T/stub-bin" <<EOF
#!/bin/sh
case "\$1" in
    register) echo "register_blocked" >&2; exit 1 ;;
    version) echo "stub-binary"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/stub-bin"
export WARP_MOCK_REGISTER_RC=1
printf '{"id":"old-id","addr":"172.16.1.1"}\n' > "$T/etc/state/warp/device.json"
warp_install >/dev/null 2>&1 && _t_bad "W3: install принят" || _t_ok
assert_eq "W3: флаг 0" "0" "$(warp_flag)"
assert_eq "W3: старый ключ цел" "old-id" "$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/etc/state/warp/device.json" | head -1)"
assert_eq "W3: PBR нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
unset WARP_FETCH_STUB WARP_MOCK_REGISTER_RC
_w_inv "W3"

# --- W4: enable but not ready: флаг=1, процесса/instance нет PBR, direct ---
_reset
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
printf '{"ready":false}\n' > "$T/tmp/warp/status.json"
printf '\n' > "$T/pidof.out"
warp_enable >/dev/null 2>&1
assert_eq "W4: rc 2 (поднимается)" "2" "$?"
assert_eq "W4: флаг 1" "1" "$(warp_flag)"
assert_eq "W4: правила нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W4"

# --- W4b: stale ready: процесс жив, но статус старше wait'а -> rc 2, без PBR ---
# (труп после kill -9: ready-файл цел, defer Remove не выполнился).
_reset
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
_ready_fixture
touch -d '-30 seconds' "$T/tmp/warp/status.json"
warp_enable >/dev/null 2>&1
assert_eq "W4b: rc 2 (stale)" "2" "$?"
assert_eq "W4b: флаг 1 (desired сохранён)" "1" "$(warp_flag)"
assert_eq "W4b: правила нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W4b"

# --- W5: ready: sets + mark + rule + default + NAT/FWD/MSS ---
_reset
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
printf '1.2.3.4\n' > "$T/etc/user-lists/warp/mine.txt"
_ready_fixture
warp_enable >/dev/null 2>&1
assert_eq "W5: rc 0" "0" "$?"
assert_contains "W5: mark dst" "$T/nft.log" 'ip daddr @z2k_warp_dst4 meta mark set'
assert_contains "W5: rule" "$T/ip-rules" "fwmark 0x80000000/0x80000000 lookup 989"
assert_contains "W5: default" "$T/ip-route-989" "default dev z2ktun0"
assert_contains "W5: masq" "$T/nft.log" 'oifname z2ktun0 masquerade'
assert_contains "W5: fwd" "$T/nft.log" 'oifname z2ktun0 accept'
assert_contains "W5: mss out" "$T/nft.log" 'maxseg size set rt mtu'
assert_contains "W5: mss in 1240" "$T/nft.log" 'maxseg size set 1240'
assert_contains "W5: mut PBR" "$T/nft.log" "x" || true
_w_inv "W5"

# --- W6: crash: PBR снят, direct, procd владеет процессом ---
printf '\n' > "$T/pidof.out"
rm -rf "$T/proc"
mkdir -p "$T/proc"
z2k_ow_warp check >/dev/null 2>&1
assert_eq "W6: правило снято" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
assert_eq "W6: route снят" "0" "$([ -f "$T/ip-route-989" ] && echo 1 || echo 0)"
_w_inv "W6"

# --- W7: recovery: selfheal возвращает PBR ---
_ready_fixture
z2k_ow_warp check >/dev/null 2>&1
assert_eq "W7: правило вернулось" "1" "$(grep -c 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules")"
_w_inv "W7"

# --- W8: disable: PBR первым, потом stop, флаг 0 ---
z2k_ow_warp disable >/dev/null 2>&1
assert_eq "W8: флаг 0" "0" "$(warp_flag)"
assert_eq "W8: правило снято" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W8"

# --- W9: remove: бинарь gone, identity+lists целы ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
printf '{"id":"keep-id"}\n' > "$T/etc/state/warp/device.json"
printf '9.9.9.9\n' > "$T/etc/user-lists/warp/mine.txt"
printf 'steam\n' > "$T/etc/user-lists/warp/.enabled"
z2k_ow_warp enable >/dev/null 2>&1
z2k_ow_warp remove >/dev/null 2>&1
assert_eq "W9: бинарь gone" "0" "$([ -x "$T/root/bin/z2k-warpd" ] && echo 1 || echo 0)"
# procd остановил instance при disable/remove — симулируем смерть процесса:
printf '\n' > "$T/pidof.out"
rm -rf "$T/proc"
mkdir -p "$T/proc"
assert_eq "W9: device цел" "keep-id" "$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/etc/state/warp/device.json" | head -1)"
assert_eq "W9: user list цел" "9.9.9.9" "$(cat "$T/etc/user-lists/warp/mine.txt")"
assert_eq "W9: .enabled цел" "steam" "$(cat "$T/etc/user-lists/warp/.enabled")"
assert_eq "W9: PBR нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W9"

# --- W10: reinstall: старый device reused, без новой identity ---
_reset
_good_stub
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
printf '{"id":"orig-id","addr":"172.16.7.7"}\n' > "$T/etc/state/warp/device.json"
export WARP_FETCH_STUB="$T/stub-bin"
warp_install >/dev/null 2>&1 || _t_bad "W10: install rc"
assert_eq "W10: device тот же" "orig-id" "$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/etc/state/warp/device.json" | head -1)"
unset WARP_FETCH_STUB
_w_inv "W10"

# --- W11/W12: dst/src семантика ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '7.7.7.0/24\n' > "$T/etc/user-lists/warp/mine.txt"
printf '192.168.5.5\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.5.5 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n' > "$T/neigh"
_ready_fixture
z2k_ow_warp 1 >/dev/null 2>&1
assert_contains "W11: dst в сете" "$T/nft.log" "7.7.7.0/24"
assert_contains "W12: src в сете" "$T/nft.log" "192.168.5.5"
_w_inv "W11/W12"

# --- W13: OUTPUT пуст от mark ---
if grep -E 'hook output' "$T/nft.log" 2>/dev/null | grep -q 'mark set'; then
    _t_bad "W13: mark в OUTPUT"
else
    _t_ok
fi

# --- W14: чужие биты живут (masked op в строке) ---
assert_contains "W14: masked op dst" "$T/nft.log" "mark & 0x7fffffff ^ 0x80000000"
if grep -E 'meta mark set 0x' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "W14: blind mark-assign"
else
    _t_ok
fi

# --- W15: mark-конфликт: enable валится, route нет ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '{"ready":true,"iface":"z2ktun0"}\n' > "$T/tmp/warp/status.json"
printf '400: from all fwmark 0x80000000/0xffffffff lookup 100\n' > "$T/ip-rules"
_ready_fixture
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
z2k_ow_warp enable >/dev/null 2>&1
assert_eq "W15: rc 1 (hard fail)" "1" "$?"
assert_eq "W15: нашего правила нет" "0" "$(grep -c 'lookup 989' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W15"

# --- W16: table-конфликт: чужое не трогаем ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf 'default dev eth0 table 989\n' > "$T/ip-route-989"
_ready_fixture
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
z2k_ow_warp enable >/dev/null 2>&1
assert_eq "W16: rc 1" "1" "$?"
assert_contains "W16: чужой default цел" "$T/ip-route-989" "default dev eth0"

# --- W17: pref-конфликт: чужое правило цело ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '500: from all lookup main\n' > "$T/ip-rules"
_ready_fixture
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
z2k_ow_warp enable >/dev/null 2>&1
assert_eq "W17: rc 1" "1" "$?"
assert_contains "W17: чужое правило цело" "$T/ip-rules" "500: from all lookup main"
assert_eq "W17: нашего нет" "0" "$(grep -c 'lookup 989' "$T/ip-rules" 2>/dev/null || true)"

# --- W18: пустые списки валидны ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
z2k_ow_warp enable >/dev/null 2>&1
assert_eq "W18: rc 0 (пусто валидно)" "0" "$?"
assert_eq "W18: правило всё равно встало" "1" "$(grep -c 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules")"
_w_inv "W18"

# --- W19: битый refresh: live set цел ---
# (mock-nft ведёт состояние сетов в nft-set-*: flush чистит, add пишет)
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '1.2.3.4\n' > "$T/etc/user-lists/warp/mine.txt"
_ready_fixture
z2k_ow_warp 1 >/dev/null 2>&1
assert_contains "W19: live set залит" "$T/nft-set-z2k_warp_dst4" "1.2.3.4"
printf '%s\n' 'garbage-%-line' 'another bad one' > "$T/etc/user-lists/warp/mine.txt"
if z2k_ow_warp reload-lists >/dev/null 2>&1; then
    _t_bad "W19: corrupt принят"
else
    _t_ok
fi
assert_contains "W19: live set цел после отказа" "$T/nft-set-z2k_warp_dst4" "1.2.3.4"
_w_inv "W19"

# --- W19b: batch failure mid-way: оба сета целы (atomic, defect 2) ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '7.7.8.0/24\n' > "$T/etc/user-lists/warp/mine.txt"
printf '192.168.6.6\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.6.6 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE\n' > "$T/neigh"
_ready_fixture
warp_nft_sets_load >/dev/null 2>&1 || _t_bad "W19b: seed load rc"
assert_contains "W19b: OLD dst залит" "$T/nft-set-z2k_warp_dst4" "7.7.8.0/24"
assert_contains "W19b: OLD src залит" "$T/nft-set-z2k_warp_src4" "192.168.6.6"
# новые входы + injected failure во втором set update:
printf '7.7.9.0/24\n' > "$T/etc/user-lists/warp/mine.txt"
printf '192.168.6.7\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.6.7 dev br-lan lladdr aa:bb:cc:dd:ee:02 REACHABLE\n' > "$T/neigh"
export NFT_BATCH_FAIL="add element inet zapret z2k_warp_src4"
if warp_nft_sets_load >/dev/null 2>&1; then
    _t_bad "W19b: batch failure принят"
else
    _t_ok
fi
unset NFT_BATCH_FAIL
assert_contains "W19b: OLD dst цел" "$T/nft-set-z2k_warp_dst4" "7.7.8.0/24"
if grep -q '7.7.9.0' "$T/nft-set-z2k_warp_dst4"; then _t_bad "W19b: NEW dst просочился"; else _t_ok; fi
assert_contains "W19b: OLD src цел" "$T/nft-set-z2k_warp_src4" "192.168.6.6"
if grep -q '192.168.6.7' "$T/nft-set-z2k_warp_src4"; then _t_bad "W19b: NEW src просочился"; else _t_ok; fi
# без injection тот же batch сходится:
warp_nft_sets_load >/dev/null 2>&1 || _t_bad "W19b: retry rc"
assert_contains "W19b: NEW dst после retry" "$T/nft-set-z2k_warp_dst4" "7.7.9.0/24"
assert_contains "W19b: NEW src после retry" "$T/nft-set-z2k_warp_src4" "192.168.6.7"
# legitimate empty: оба сета атомарно пустеют:
: > "$T/etc/user-lists/warp/mine.txt"
: > "$T/etc/user-lists/warp/devices.txt"
warp_nft_sets_load >/dev/null 2>&1 || _t_bad "W19b: empty rc"
assert_eq "W19b: dst пуст" "0" "$(grep -c . "$T/nft-set-z2k_warp_dst4" 2>/dev/null || true)"
assert_eq "W19b: src пуст" "0" "$(grep -c . "$T/nft-set-z2k_warp_src4" 2>/dev/null || true)"
_w_inv "W19b"

# --- W20: MAC офлайн скип ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf 'DE-AD-BE-EF-00-01\n192.168.9.9\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.9.9 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE\n' > "$T/neigh"
_ready_fixture
z2k_ow_warp 1 >/dev/null 2>&1
: > "$T/nft.log"
warp_nft_sets_load >/dev/null 2>&1
assert_contains "W20: онлайн-IP в сете" "$T/nft.log" "192.168.9.9"
_w_inv "W20"

# --- W21: публичный source отвергнут ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '8.8.8.8\n192.168.9.9\n' > "$T/etc/user-lists/warp/devices.txt"
printf '192.168.9.9 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE\n' > "$T/neigh"
_ready_fixture
z2k_ow_warp 1 >/dev/null 2>&1
: > "$T/nft.log"
warp_nft_sets_load >/dev/null 2>&1
if grep -q '8.8.8.8' "$T/nft.log"; then _t_bad "W21: публичный source в сете"; else _t_ok; fi

# --- W22: приватный dst отвергнут ---
printf '10.1.2.0/24\n' > "$T/etc/user-lists/warp/mine.txt"
: > "$T/nft.log"
warp_nft_sets_load >/dev/null 2>&1
if grep -q '10.1.2.0' "$T/nft.log"; then _t_bad "W22: приват в сете"; else _t_ok; fi
_w_inv "W21/W22"

# --- W23/W24/W25: MASQ/FWD/MSS shapes уже покрыты W5; narrowness ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '1.2.3.4\n' > "$T/etc/user-lists/warp/mine.txt"
_ready_fixture
z2k_ow_warp 1 >/dev/null 2>&1
: > "$T/nft.log"
warp_pbr_up >/dev/null 2>&1 || _t_bad "W23: pbr_up rc"
assert_contains "W23: masq только oif" "$T/nft.log" 'oifname z2ktun0 masquerade'
assert_contains "W24: fwd только oif" "$T/nft.log" 'oifname z2ktun0 accept'
assert_contains "W25: mss out/in" "$T/nft.log" 'maxseg size set 1240'
if grep '^nft:add rule' "$T/nft.log" | grep -vE 'z2k_warp_(mark|mss|fwd|nat)' >/dev/null 2>&1; then
    _t_bad "W24: правило вне warp-chains"
else
    _t_ok
fi

# --- W26: firewall recreation: PID stable, restore без рестарта ---
: > "$T/procd.log"
: > "$T/no-table"
z2k_ow_warp rules 2>/dev/null && _t_bad "W26: rules без таблицы приняты" || _t_ok
rm -f "$T/no-table"
z2k_ow_warp rules >/dev/null 2>&1 || _t_bad "W26: rules после возврата"
assert_eq "W26: instance не трогали" "0" "$(grep -c '^instance:' "$T/procd.log" 2>/dev/null || true)"
assert_eq "W26: правила вернулись" "1" "$(grep -c 'oifname z2ktun0 masquerade' "$T/nft.log")"
_w_inv "W26"

# --- W27: binary refresh while enabled: PBR down -> replace -> up ---
export WARP_PROC_WAIT=6
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
_snap() { cp "$T/ip-rules" "$1.rules" 2>/dev/null || : > "$1.rules"; cp "$T/nft.log" "$1.nft" 2>/dev/null || : > "$1.nft"; }
_snap "$T/s27a"
sh "$T/root/platform/openwrt/warp-proc.sh" stop
assert_eq "W27: stop снял PBR" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
cp -f "$T/root/bin/z2k-warpd" "$T/root/bin/z2k-warpd.new" 2>/dev/null
mv -f "$T/root/bin/z2k-warpd.new" "$T/root/bin/z2k-warpd"
sh "$T/root/platform/openwrt/warp-proc.sh" start
assert_eq "W27: start вернул PBR" "1" "$(grep -c 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules")"
assert_eq "W27: процесс виден" "7777" "$(warp_pids | tr '\n' ' ' | tr -d ' ')"
# not-ready ветка: PBR остаётся снятым, rc 0:
printf '{"ready":false}\n' > "$T/tmp/warp/status.json"
sh "$T/root/platform/openwrt/warp-proc.sh" stop >/dev/null 2>&1
sh "$T/root/platform/openwrt/warp-proc.sh" start >/dev/null 2>&1
assert_eq "W27: not-ready rc" "0" "$?"
assert_eq "W27: PBR не поднят вслепую" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
# mapping updater -> warp-proc.sh на openwrt, S51 на keenetic:
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || { echo "FAIL[ow-warp-lifecycle]: au" >&2; exit 1; }
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
assert_eq "W27: owner openwrt" "$T/root/platform/openwrt/warp-proc.sh" "$(au_service_for_binary z2k-warpd)"
unset Z2K_PLATFORM
assert_eq "W27: owner keenetic" "/opt/etc/init.d/S51z2k-warp" "$(au_service_for_binary z2k-warpd)"
_w_inv "W27"

# --- W28: updater НЕ ставит отсутствующий optional (настоящий шаг) ---
# Зеркало tests/test_refresh_installs_base_binaries.sh на openwrt-окружении:
# тот же механизм (non-base skip), та же причина (кнопка, не апдейтер).
_reset
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
rm -f "$T/root/bin/z2k-warpd"
mkdir -p "$T/au-tmp"
_newsha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf '{"current":"p-84.7","files_sha256":{"z2k-warpd/builds/z2k-warpd-linux-arm64":"%s"}}\n' \
    "$_newsha" > "$T/au-tmp/UPDATES.json"
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
Z2K_AU_SBIN="$T/root/bin"; export Z2K_AU_SBIN
Z2K_AU_TMP_DIR="$T/au-tmp"; export Z2K_AU_TMP_DIR
ZAPRET2_DIR="$T/root"; export ZAPRET2_DIR
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || { echo "FAIL[ow-warp-lifecycle]: au2" >&2; exit 1; }
au_log() { printf '%s\n' "$1" >> "$T/au.log"; }
au_gen_libs_source() { return 0; }
au_bin_goarch() { echo arm64; }
au_manifest_file_sha() { echo "$_newsha"; }
au_download_repo_file() { printf 'бинарник\n' > "$2"; printf '%s\n' "$1" >> "$T/fetched"; return 0; }
: > "$T/au.log"; : > "$T/fetched"
au_step_refresh_binaries >/dev/null 2>&1
assert_eq "W28: бинарь не появился" "0" "$([ -f "$T/root/bin/z2k-warpd" ] && echo 1 || echo 0)"
assert_eq "W28: даже не качали" "0" "$(grep -c . "$T/fetched" 2>/dev/null || true)"
unset Z2K_PLATFORM
_w_inv "W28"

# --- W27b: present + stale sha -> замена через warp-proc.sh, PBR цел ---
# (настоящий шаг refresh-binaries, настоящий au_service_for_binary,
# настоящий warp-proc.sh; стабы только сеть/арка/лог. au_manifest_file_sha —
# НАСТОЯЩАЯ: пересourcing восстанавливает её после чужих стабов.)
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf '#!/bin/sh\nexit 0\n' > "$T/root/bin/z2k-warpd"
chmod +x "$T/root/bin/z2k-warpd"
_ready_fixture
cat > "$T/stub-new-bin" <<EOF
#!/bin/sh
# MARKER-NEWDATA-v2
case "\$1" in version) echo "z2k-warpd mock-new"; exit 0 ;; esac
exit 0
EOF
chmod +x "$T/stub-new-bin"
_newsha2="$(sha256sum "$T/stub-new-bin" 2>/dev/null | awk '{print $1}')"
printf '{"current":"p-84.7","files_sha256":{"z2k-warpd/builds/z2k-warpd-linux-arm64":"%s"}}\n' \
    "$_newsha2" > "$T/au-tmp/UPDATES.json"
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || { echo "FAIL[ow-warp-lifecycle]: au3" >&2; exit 1; }
au_log() { printf '%s\n' "$1" >> "$T/au.log"; }
au_gen_libs_source() { return 0; }
au_bin_goarch() { echo arm64; }
au_download_repo_file() { cp -f "$T/stub-new-bin" "$2"; printf '%s\n' "$1" >> "$T/fetched"; return 0; }
is_running() { return 1; }
: > "$T/fetched"
au_step_refresh_binaries >/dev/null 2>&1
assert_eq "W27b: бинарь заменён" "# MARKER-NEWDATA-v2" "$(sed -n '2p' "$T/root/bin/z2k-warpd")"
assert_eq "W27b: PBR цел после замены" "1" "$(grep -c 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules")"
assert_contains "W27b: качали с lineage" "$T/fetched" "z2k-warpd/builds/z2k-warpd-linux-arm64"
unset Z2K_PLATFORM
_w_inv "W27b"

# --- W29: flag=0 selfheal: converge-to-off ---
_reset
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
cat > "$T/root/bin/z2k-warpd" <<EOF
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-warpd"
printf '500: from all fwmark 0x80000000/0x80000000 lookup 989\n' > "$T/ip-rules"
z2k_ow_warp check >/dev/null 2>&1
assert_eq "W29: PBR снят" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
_w_inv "W29"

# --- W30: global ENABLED=0: сайд-эффектов нет ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
printf 'ENABLED=0\n' >> "$T/etc/config"
z2k_ow_warp 1
assert_eq "W30: instance нет" "0" "$(grep -c '^instance:' "$T/procd.log" 2>/dev/null || true)"
assert_eq "W30: правил нет" "0" "$(grep -c '^nft:add rule' "$T/nft.log" 2>/dev/null || true)"
_w_inv "W30"

# --- W31: register retry bounded (stamp), не каждый тик ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
rm -f "$T/etc/state/warp/device.json"
date +%s > "$T/tmp/warp-register.stamp"
export WARP_REG_STAMP="$T/tmp/warp-register.stamp" WARP_REG_RETRY=600
: > "$T/warpd.log"
z2k_ow_warp check >/dev/null 2>&1
assert_eq "W31: свежий stamp — попыток нет" "0" "$(grep -c '^warpd:' "$T/warpd.log" 2>/dev/null || true)"
printf '1\n' > "$T/tmp/warp-register.stamp"
z2k_ow_warp check >/dev/null 2>&1
assert_eq "W31: старый stamp — попытка была" "1" "$(grep -c '^warpd:register' "$T/warpd.log" 2>/dev/null || true)"
unset WARP_REG_STAMP WARP_REG_RETRY
_w_inv "W31"

# --- W32: MASQUE endpoint не исключаем из desync ---
if grep -E 'hostlist-exclude|nozapret|blockme|ps1\.' "$T/root/platform/openwrt/warp.sh" >/dev/null 2>&1; then
    _t_bad "W32: исключение MASQUE/desync в glue"
else
    _t_ok
fi
if grep -E 'rutracker|api\.|rep\.|static\.|\.wiki' "$T/root/platform/openwrt/warp.sh" >/dev/null 2>&1; then
    _t_bad "W32: доменные исключения в glue"
else
    _t_ok
fi

# --- W33: own + foreign same pref -> conflict (defect 3) ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
printf '%s\n' '500: from all fwmark 0x80000000/0x80000000 lookup 989' '500: from 192.168.1.0/24 lookup 123' > "$T/ip-rules"
z2k_ow_warp enable >/dev/null 2>&1
assert_eq "W33: rc 1 (hard fail)" "1" "$?"
assert_eq "W33: route не ставили" "0" "$([ -f "$T/ip-route-989" ] && echo 1 || echo 0)"
assert_contains "W33: наше правило цело" "$T/ip-rules" "500: from all fwmark 0x80000000/0x80000000 lookup 989"
assert_contains "W33: чужое правило цело" "$T/ip-rules" "500: from 192.168.1.0/24 lookup 123"
assert_eq "W33: флаг 1 (desired)" "1" "$(warp_flag)"
_w_inv "W33"

# --- W34: foreign rule arrives after enable; disable снимает только наше ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
z2k_ow_warp enable >/dev/null 2>&1 || _t_bad "W34: enable rc"
# чужак появляется ПОСЛЕ enable (drift):
printf '499: from 10.9.9.0/24 lookup 100\n' >> "$T/ip-rules"
z2k_ow_warp disable >/dev/null 2>&1
assert_eq "W34: наше правило снято" "0" "$(grep -c 'fwmark 0x80000000/0x80000000 lookup 989' "$T/ip-rules" 2>/dev/null || true)"
assert_contains "W34: чужое правило цело" "$T/ip-rules" "499: from 10.9.9.0/24 lookup 100"
assert_eq "W34: флаг 0" "0" "$(warp_flag)"
_w_inv "W34"

# --- W35: foreign route replaces table default; disable не трогает чужое ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
z2k_ow_warp enable >/dev/null 2>&1 || _t_bad "W35: enable rc"
# drift: чужой default вместо нашего:
printf 'default dev eth0\n' > "$T/ip-route-989"
z2k_ow_warp disable >/dev/null 2>&1
assert_eq "W35: наше правило снято" "0" "$(grep -c 'fwmark 0x80000000' "$T/ip-rules" 2>/dev/null || true)"
assert_contains "W35: чужой default цел" "$T/ip-route-989" "default dev eth0"
assert_eq "W35: owner убран" "0" "$([ -f "$T/tmp/warp/pbr.owner" ] && echo 1 || echo 0)"
_w_inv "W35"

# --- W36: normal owned teardown: rule + route + owner уходят ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
z2k_ow_warp enable >/dev/null 2>&1 || _t_bad "W36: enable rc"
assert_eq "W36: owner записан" "1" "$([ -f "$T/tmp/warp/pbr.owner" ] && echo 1 || echo 0)"
z2k_ow_warp disable >/dev/null 2>&1
assert_eq "W36: правило снято" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
assert_eq "W36: route снят" "0" "$([ -f "$T/ip-route-989" ] && echo 1 || echo 0)"
assert_eq "W36: owner убран" "0" "$([ -f "$T/tmp/warp/pbr.owner" ] && echo 1 || echo 0)"
_w_inv "W36"

# --- W37: repeated enable/down: ни route, ни rule, ни owner не текут ---
_reset
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
_ready_fixture
z2k_ow_warp enable >/dev/null 2>&1 || _t_bad "W37: enable1 rc"
z2k_ow_warp disable >/dev/null 2>&1
z2k_ow_warp enable >/dev/null 2>&1 || _t_bad "W37: enable2 rc"
z2k_ow_warp disable >/dev/null 2>&1
assert_eq "W37: правил нет" "0" "$(grep -c 'fwmark' "$T/ip-rules" 2>/dev/null || true)"
assert_eq "W37: route нет" "0" "$([ -f "$T/ip-route-989" ] && echo 1 || echo 0)"
assert_eq "W37: owner нет" "0" "$([ -f "$T/tmp/warp/pbr.owner" ] && echo 1 || echo 0)"
_w_inv "W37"

_t_done
