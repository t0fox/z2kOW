#!/bin/sh
# tests/openwrt/test_ow_rt_lifecycle.sh - Stage 4 Layer C: RT1-RT20.
# Mock'и: uci, dnsmasq-init, nslookup, nft, pidof, /proc, procd.
# Реальный код rt.sh in-process (+ настоящий rt-proc.sh для RT7).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-rt-lifecycle"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtlc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/uci/dhcp" "$T/root/bin" "$T/root/lists" "$T/root/platform/openwrt" "$T/etc" "$T/tmp" "$T/proc"
export PATH="$T/bin:$PATH"
for _f in paths.sh env.sh rt.sh rt-proc.sh rt-check.sh tg.sh firewall.sh schedule.sh uninstall.sh; do
    ln -s "$REPO/platform/openwrt/$_f" "$T/root/platform/openwrt/$_f" 2>/dev/null
done

# --- mock uci (состояние — файлы dhcp/<sec>) ---
cat > "$T/bin/uci" <<EOF
#!/bin/sh
UCI_DIR="$T/uci/dhcp"
uci_show() {
    if [ ! -f "$T/uci/multi" ]; then
        printf 'dhcp.@dnsmasq[0]=dnsmasq\n'
    else
        printf 'dhcp.@dnsmasq[0]=dnsmasq\ndhcp.@dnsmasq[1]=dnsmasq\n'
    fi
    for _f in "\$UCI_DIR"/*; do
        [ -f "\$_f" ] || continue
        _s="\$(basename "\$_f")"
        _t=""; _n=""; _i=""
        while IFS='=' read -r _k _v; do
            case "\$_k" in
                type) _t="\$_v" ;; name) _n="\$_v" ;; ip) _i="\$_v" ;;
            esac
        done < "\$_f"
        printf 'dhcp.%s=%s\n' "\$_s" "\$_t"
        [ -n "\$_n" ] && printf 'dhcp.%s.name='\''%s'\''\n' "\$_s" "\$_n"
        [ -n "\$_i" ] && printf 'dhcp.%s.ip='\''%s'\''\n' "\$_s" "\$_i"
    done
}
cmd="\$1"; shift
case "\$cmd" in
    show) uci_show ;;
    -q)
        [ "\$1" = "get" ] || exit 1
        _p="\$2"; _rest="\${_p#dhcp.}"
        _s="\${_rest%%.*}"; _o="\${_rest#*.}"
        [ -f "\$UCI_DIR/\$_s" ] || exit 1
        _v="\$(sed -n "s/^\$_o=//p" "\$UCI_DIR/\$_s" | head -1)"
        [ -n "\$_v" ] || exit 1
        printf '%s\n' "\$_v"; exit 0 ;;
    set)
        _a="\$1"; _lhs="\${_a%%=*}"; _rhs="\${_a#*=}"
        _rest="\${_lhs#dhcp.}"
        case "\$_rest" in
            *.*) _s="\${_rest%%.*}"; _o="\${_rest#*.}" ;;
            *) _s="\$_rest"; _o="__type__" ;;
        esac
        mkdir -p "\$UCI_DIR"
        [ -f "\$UCI_DIR/\$_s" ] || printf 'type=\nname=\nip=\n' > "\$UCI_DIR/\$_s"
        if [ "\$_o" = "__type__" ]; then
            sed -i "s/^type=.*/type=\$_rhs/" "\$UCI_DIR/\$_s"
        else
            grep -q "^\$_o=" "\$UCI_DIR/\$_s" \
                && sed -i "s/^\$_o=.*/\$_o=\$_rhs/" "\$UCI_DIR/\$_s" \
                || printf '%s=%s\n' "\$_o" "\$_rhs" >> "\$UCI_DIR/\$_s"
        fi
        exit 0 ;;
    delete)
        _rest="\${1#dhcp.}"; _s="\${_rest%%.*}"
        rm -f "\$UCI_DIR/\$_s"; exit 0 ;;
    commit) echo "commit:\$1" >> "$T/uci.log"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
cat > "$T/dnsmasq-init" <<EOF
#!/bin/sh
echo "dnsmasq:\$1" >> "$T/dnsmasq.log"
exit 0
EOF
chmod +x "$T/dnsmasq-init"
cat > "$T/bin/nslookup" <<EOF
#!/bin/sh
if grep -qxF "\$1" "$T/nslookup-want" 2>/dev/null; then
    printf 'Name: %s\nAddress 1: 10.171.171.171\n' "\$1"
    exit 0
fi
exit 1
EOF
chmod +x "$T/bin/nslookup"
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

cat > "$T/root/bin/z2k-rt-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-rt-proxy"
printf 'ENABLED=1\n' > "$T/etc/config"
printf 'user-line.example\n' > "$T/root/lists/whitelist.txt"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_PROC_ROOT="$T/proc" Z2K_DNSMASQ_INIT="$T/dnsmasq-init"
export Z2K_RT_HEALTH_DIR="$T/tmp/rt-health"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/rt.sh" || { echo "FAIL[ow-rt-lifecycle]: source" >&2; exit 1; }
_z2k_ow_rt_kill() { echo "kill:$*" >> "$T/kill.log"; return 0; }
procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }

_reset() {
    rm -f "$T"/uci/dhcp/* "$T/uci/multi" "$T/nslookup-want"
    : > "$T/uci.log"; : > "$T/dnsmasq.log"
    : > "$T/nft.log"; : > "$T/procd.log"; : > "$T/kill.log"
    rm -rf "$T/tmp/rt-health"
    for _d in rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc; do
        printf '%s\n' "$_d" >> "$T/nslookup-want"
    done
    printf 'ENABLED=1\n' > "$T/etc/config"
    printf '\n' > "$T/pidof.out"
    rm -f "$T/no-table"
    chmod +x "$T/root/bin/z2k-rt-proxy"
    printf 'user-line.example\n' > "$T/root/lists/whitelist.txt"
}
_snap() { # $1 файл снимка: uci-секции + whitelist + nft.log
    ls "$T/uci/dhcp" 2>/dev/null | sort > "$1.uci"
    cksum "$T/root/lists/whitelist.txt" > "$1.wl"
    cp "$T/nft.log" "$1.nft" 2>/dev/null || : > "$1.nft"
}

# --- RT1: fresh start: DNS + whitelist + redirect + guard + процесс ---
_reset
_out="$(z2k_ow_rt 1 2>"$T/err")"
assert_eq "RT1 rc" "0" "$?"
printf '%s\n' "$_out" > "$T/out"
assert_eq "RT1: DNS-секций 5" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"
assert_eq "RT1: whitelist строк 6 (5+user)" "6" "$(wc -l < "$T/root/lists/whitelist.txt" | tr -d ' ')"
assert_eq "RT1: правил 4" "4" "$(grep -c '^nft:add rule' "$T/nft.log")"
assert_eq "RT1: один instance" "1" "$(grep -c '^instance:z2k-rt$' "$T/procd.log")"
assert_contains "RT1: mut DNS" "$T/out" "DNS_CREATED: rutracker.org"
assert_contains "RT1: mut NFT" "$T/out" "NFT_CREATED:"
assert_contains "RT1: mut PROC" "$T/out" "PROCESS_ACTION:"

# --- RT2: exactness: сабдомен не покрыт пином ---
_reset
printf 'type=hostrecord\nname=foo.rutracker.org\nip=1.2.3.4\n' > "$T/uci/dhcp/user_sub"
z2k_ow_rt 1 >/dev/null 2>&1 || _t_bad "RT2: apply rc"
assert_eq "RT2: чужой сабдомен цел" "1.2.3.4" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/user_sub")"

# --- RT3: legacy cleanup при старте ---
_reset
printf 'type=hostrecord\nname=www.rutracker.org\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_www_rutracker_org"
printf 'type=hostrecord\nname=rutracker.cc\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_rutracker_cc"
z2k_ow_rt 1 >/dev/null 2>&1
assert_eq "RT3: legacy gone, active 5" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"

# --- RT4: повторный старт: без дублей ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
_snap "$T/s4a"
: > "$T/nft.log"
z2k_ow_rt 1 >/dev/null 2>&1
assert_eq "RT4: секций те же 5" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"
assert_eq "RT4: whitelist без дублей" "6" "$(wc -l < "$T/root/lists/whitelist.txt" | tr -d ' ')"

# --- RT5: crash (transient): DNS/rules на месте, ничего не снято ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
: > "$T/nft.log"
printf '\n' > "$T/pidof.out"
z2k_ow_rt check >/dev/null 2>&1
assert_eq "RT5: DNS цел" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"
if grep -q '^nft:delete' "$T/nft.log"; then _t_bad "RT5: transient снял правила"; else _t_ok; fi
assert_eq "RT5: dead-tick заведён" "1" "$(cat "$T/tmp/rt-health/dead" 2>/dev/null)"

# --- RT6: proc-bounce: только процесс, DNS/rules/whitelist целы ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
printf '4242\n' > "$T/pidof.out"
mkdir -p "$T/proc/4242"
printf 'z2k-rt-proxy --listen=:1445 --timeout=15m' | tr ' ' '\0' > "$T/proc/4242/cmdline"
_snap "$T/s6"
: > "$T/kill.log"
z2k_ow_rt proc-bounce
assert_contains "RT6: kill был" "$T/kill.log" "kill:4242"
_snap "$T/s6b"
assert_eq "RT6: DNS не тронут" "$(cat "$T/s6.uci")" "$(cat "$T/s6b.uci")"
assert_eq "RT6: whitelist не тронут" "$(cat "$T/s6.wl")" "$(cat "$T/s6b.wl")"
if cmp -s "$T/s6.nft" "$T/nft.log"; then
    _t_ok
else
    _t_bad "RT6: nft тронут bounce'ом"
fi

# --- RT7: binary refresh через настоящий rt-proc.sh: DNS/rules целы ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
printf '4242\n' > "$T/pidof.out"
_snap "$T/s7"
sh "$T/root/platform/openwrt/rt-proc.sh" stop
cp -f "$T/root/bin/z2k-rt-proxy" "$T/root/bin/z2k-rt-proxy.new" 2>/dev/null
mv -f "$T/root/bin/z2k-rt-proxy.new" "$T/root/bin/z2k-rt-proxy"
sh "$T/root/platform/openwrt/rt-proc.sh" start
_snap "$T/s7b"
assert_eq "RT7: DNS цел" "$(cat "$T/s7.uci")" "$(cat "$T/s7b.uci")"
assert_eq "RT7: whitelist цел" "$(cat "$T/s7.wl")" "$(cat "$T/s7b.wl")"
assert_eq "RT7: nft цел (без delete)" "0" "$(grep -c '^nft:delete' "$T/nft.log" 2>/dev/null || true)"
assert_eq "RT7: процесс виден после" "4242" "$(z2k_ow_rt_pids | tr '\n' ' ' | tr -d ' ')"
# mapping updater -> rt-proc.sh на openwrt, S96 на keenetic:
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || { echo "FAIL[ow-rt-lifecycle]: au" >&2; exit 1; }
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
assert_eq "RT7: owner openwrt" "$T/root/platform/openwrt/rt-proc.sh" "$(au_service_for_binary z2k-rt-proxy)"
unset Z2K_PLATFORM
assert_eq "RT7: owner keenetic" "/opt/etc/init.d/S96z2k-rt-proxy" "$(au_service_for_binary z2k-rt-proxy)"

# --- RT8: full stop: процесс/DNS/правила/guard gone ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
printf '\n' > "$T/pidof.out"
: > "$T/nft.log"
z2k_ow_rt 0 >/dev/null 2>&1
assert_eq "RT8: DNS ours gone" "0" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_' || true)"
assert_eq "RT8: chains 3 delete" "3" "$(grep -c '^nft:delete chain' "$T/nft.log")"

# --- RT9: uninstall-композиция: cleanup + cron-remove, user-DNS цел ---
_reset
printf 'type=hostrecord\nname=my.home\nip=192.168.1.5\n' > "$T/uci/dhcp/user_home"
z2k_ow_rt 1 >/dev/null 2>&1
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/schedule.sh" >/dev/null 2>&1
Z2K_CRON_TAB="$T/crontab"; export Z2K_CRON_TAB
: > "$T/crontab"
z2k_ow_rt_cron_install >/dev/null 2>&1 || _t_bad "RT9: cron install"
z2k_ow_rt cleanup >/dev/null 2>&1
z2k_ow_rt_cron_remove >/dev/null 2>&1 || _t_bad "RT9: cron remove"
assert_eq "RT9: DNS ours gone" "0" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_' || true)"
assert_eq "RT9: user-DNS цел" "192.168.1.5" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/user_home")"
if grep -q 'z2k-rt-health' "$T/crontab"; then _t_bad "RT9: cron-строка осталась"; else _t_ok; fi

# --- RT10: WAN flap: PID stable, без commit, whitelist цел ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
printf '4242\n' > "$T/pidof.out"
: > "$T/kill.log"; : > "$T/uci.log"; : > "$T/nft.log"
_snap "$T/s10"
z2k_ow_rt rules || _t_bad "RT10: rules rc"
assert_eq "RT10: kill нет" "0" "$(grep -c '^kill:' "$T/kill.log" 2>/dev/null || true)"
assert_eq "RT10: commit нет (DNS untouched)" "0" "$(grep -c '^commit:' "$T/uci.log" 2>/dev/null || true)"
assert_eq "RT10: whitelist цел" "$(cat "$T/s10.wl")" "$(cksum "$T/root/lists/whitelist.txt")"
assert_eq "RT10: правила сошлись (4)" "4" "$(grep -c '^nft:add rule' "$T/nft.log")"

# --- RT11: пересоздание firewall: restore без churn DNS/процесса ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
: > "$T/no-table"
z2k_ow_rt rules 2>/dev/null && _t_bad "RT11: rules без таблицы приняты" || _t_ok
rm -f "$T/no-table"
: > "$T/uci.log"
z2k_ow_rt rules || _t_bad "RT11: rules после возврата"
assert_eq "RT11: commit нет" "0" "$(grep -c '^commit:' "$T/uci.log" 2>/dev/null || true)"

# --- RT12/13: guard drop + dnat-accept-до-drop ---
_reset
z2k_ow_rt rules >/dev/null 2>&1 || _t_bad "RT12: rules rc"
assert_contains "RT12: drop :1445" "$T/nft.log" 'z2k_rt_flt_in tcp dport 1445 drop'
_accept_ln="$(grep -n 'z2k_rt_flt_in tcp dport 1445 ct status dnat accept' "$T/nft.log" | head -1 | cut -d: -f1)"
_drop_ln="$(grep -n 'z2k_rt_flt_in tcp dport 1445 drop' "$T/nft.log" | head -1 | cut -d: -f1)"
if [ -n "$_accept_ln" ] && [ -n "$_drop_ln" ] && [ "$_accept_ln" -lt "$_drop_ln" ]; then
    _t_ok
else
    _t_bad "RT13: dnat-accept не до drop"
fi

# --- RT14/15: offload-структура + чужой трафик не задет ---
if grep -Ei 'flowtable|flow add|offload|PPE' "$T/nft.log" >/dev/null 2>&1; then
    _t_bad "RT14: offload-конструкции в наших объектах"
else
    _t_ok
fi
if grep '^nft:add rule' "$T/nft.log" | grep -vE '10\.171\.171\.171|dport 1445' >/dev/null 2>&1; then
    _t_bad "RT15: правило шире sentinel/:1445"
else
    _t_ok
fi

# --- RT16: конфликт -> отказ до старта ---
_reset
printf 'type=hostrecord\nname=api.rutracker.cc\nip=9.9.9.9\n' > "$T/uci/dhcp/user_x"
z2k_ow_rt 1 >/dev/null 2>&1 && _t_bad "RT16: конфликт принят" || _t_ok
assert_eq "RT16: instance нет" "0" "$(grep -c '^instance:' "$T/procd.log" 2>/dev/null || true)"

# --- RT17: dnsmasq failure -> не ready ---
_reset
cat > "$T/dnsmasq-init" <<EOF
#!/bin/sh
echo "dnsmasq:\$1" >> "$T/dnsmasq.log"
exit 1
EOF
chmod +x "$T/dnsmasq-init"
z2k_ow_rt 1 >/dev/null 2>&1 && _t_bad "RT17: dnsmasq-failure принят" || _t_ok
cat > "$T/dnsmasq-init" <<EOF
#!/bin/sh
echo "dnsmasq:\$1" >> "$T/dnsmasq.log"
exit 0
EOF
chmod +x "$T/dnsmasq-init"

# --- RT18: стойкая смерть -> teardown + latch, без flap; возврат -> reconverge ---
_reset
z2k_ow_rt 1 >/dev/null 2>&1
printf '\n' > "$T/pidof.out"
z2k_ow_rt check >/dev/null 2>&1
z2k_ow_rt check >/dev/null 2>&1
assert_eq "RT18: после 2 тиков пины целы" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"
z2k_ow_rt check >/dev/null 2>&1
assert_eq "RT18: после 3 тиков DNS снят" "0" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_' || true)"
assert_eq "RT18: latch стоит" "1" "$([ -f "$T/tmp/rt-health/halted" ] && echo 1 || echo 0)"
_snap "$T/s18"
z2k_ow_rt check >/dev/null 2>&1
_snap "$T/s18b"
assert_eq "RT18: 4-й тик без flap (uci)" "$(cat "$T/s18.uci")" "$(cat "$T/s18b.uci")"
# процесс вернулся (оператор поднял) -> reconverge + latch снят
printf '4242\n' > "$T/pidof.out"
z2k_ow_rt check >/dev/null 2>&1
assert_eq "RT18: reconverge DNS" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"
assert_eq "RT18: latch снят" "0" "$([ -f "$T/tmp/rt-health/halted" ] && echo 1 || echo 0)"

# --- RT19: ENABLED=0: ничего нет ---
_reset
printf 'ENABLED=0\n' > "$T/etc/config"
z2k_ow_rt 1
assert_eq "RT19: instance нет" "0" "$(grep -c '^instance:' "$T/procd.log" 2>/dev/null || true)"
assert_eq "RT19: правил нет" "0" "$(grep -c '^nft:add rule' "$T/nft.log" 2>/dev/null || true)"
assert_eq "RT19: DNS нет" "0" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_' || true)"

# --- RT20: shipped RKN содержит домены + effective whitelist держит 5 ---
if grep -qxF 'rutracker.org' "$REPO/files/lists/extra_strats/TCP/RKN/List.txt"; then
    _t_ok
else
    _t_bad "RT20: shipped RKN без rutracker.org (вычитание не нужно?)"
fi
_reset
z2k_ow_rt 1 >/dev/null 2>&1
for _d in rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc; do
    grep -qxF "$_d" "$T/root/lists/whitelist.txt" || _t_bad "RT20: нет $_d в effective whitelist"
done
_t_ok
assert_eq "RT20: effective == читаемый генератором" "$T/root/lists/whitelist.txt" "$Z2K_LISTS_DIR/whitelist.txt"

_t_done
