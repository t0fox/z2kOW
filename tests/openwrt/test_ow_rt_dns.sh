#!/bin/sh
# tests/openwrt/test_ow_rt_dns.sh - Stage 4 Layer B: UCI DNS-пины.
# Mock'и: uci (состояние в файлах), /etc/init.d/dnsmasq (запись reload/restart),
# nslookup ( canned ответы). Реальный код rt.sh in-process.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-rt-dns"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtdns.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/uci/dhcp" "$T/root/bin" "$T/etc" "$T/tmp"
export PATH="$T/bin:$PATH"

# --- mock uci: секции dhcp/<sec> файлами type=.., name=.., ip=.. ---
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
    -q) # -q get <path> ($1 уже get: верхний shift съел -q)
        [ "\$1" = "get" ] || exit 1
        _p="\$2"; _rest="\${_p#dhcp.}"
        _s="\${_rest%%.*}"; _o="\${_rest#*.}"
        [ -f "\$UCI_DIR/\$_s" ] || exit 1
        _v="\$(sed -n "s/^\$_o=//p" "\$UCI_DIR/\$_s" | head -1)"
        [ -n "\$_v" ] || exit 1
        printf '%s\n' "\$_v"; exit 0 ;;
    set) # set <dhcp.sec=type | dhcp.sec.opt=val>
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
    delete) # delete <dhcp.sec>
        _rest="\${1#dhcp.}"; _s="\${_rest%%.*}"
        rm -f "\$UCI_DIR/\$_s"; exit 0 ;;
    commit) echo "commit:\$1" >> "$T/uci.log"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
# NOTE: sed -i выше — GNU/busybox sed на роутере и в WSL есть; на чистом
# POSIX без -i тест скипнется сам (uci mock упадёт -> rc тестов покажет).
cat > "$T/dnsmasq-init" <<EOF
#!/bin/sh
echo "dnsmasq:\$1" >> "$T/dnsmasq.log"
[ "\$1" = "reload" ] && [ -f "$T/dnsmasq-fail-reload" ] && exit 1
exit 0
EOF
chmod +x "$T/dnsmasq-init"
cat > "$T/bin/nslookup" <<EOF
#!/bin/sh
# Модель семантики dnsmasq 2.93 (баг-репорт): A отвечает sentinel4, если домен
# в want-v4; AAAA отвечает sentinel6, если в want-v6, ИНАЧЕ уходит upstream
# (want-leak — публичный ответ). Dual-record => оба типа локальны => no forward.
# \$1 домен, \$2 сервер.
echo "nslookup:\$1" >> "$T/nslookup.log"
_rc=1
if grep -qxF "\$1" "$T/nslookup-want-v4" 2>/dev/null; then
    printf 'Name: %s\nAddress 1: 10.171.171.171\n' "\$1"
    _rc=0
fi
if grep -qxF "\$1" "$T/nslookup-want-v6" 2>/dev/null; then
    printf 'Name: %s\nAddress 1: 2001:db8::1:1445\n' "\$1"
    _rc=0
fi
if grep -qxF "\$1" "$T/nslookup-want-leak" 2>/dev/null; then
    printf 'Name: %s\nAddress 1: 2001:db8:dead::1\n' "\$1"
    _rc=0
fi
exit \$_rc
EOF
chmod +x "$T/bin/nslookup"

cat > "$T/root/bin/z2k-rt-proxy" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/root/bin/z2k-rt-proxy"
printf 'ENABLED=1\n' > "$T/etc/config"

export Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_BIN="$T/root/bin" Z2K_RUN="$T/tmp/runtime"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_DNSMASQ_INIT="$T/dnsmasq-init"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/rt.sh" || { echo "FAIL[ow-rt-dns]: source" >&2; exit 1; }

_reset() {
    rm -f "$T"/uci/dhcp/* "$T/uci/multi" "$T/dnsmasq-fail-reload"
    rm -f "$T/nslookup-want-v4" "$T/nslookup-want-v6" "$T/nslookup-want-leak"
    : > "$T/uci.log"; : > "$T/dnsmasq.log"; : > "$T/nslookup.log"
    for _d in rutracker.org rutracker.wiki api.rutracker.cc rep.rutracker.cc static.rutracker.cc; do
        printf '%s\n' "$_d" >> "$T/nslookup-want-v4"
        printf '%s\n' "$_d" >> "$T/nslookup-want-v6"
    done
    printf 'ENABLED=1\n' > "$T/etc/config"
}

# --- BUG PROOF (dnsmasq 2.93): v4-only hostrecord НЕ подавляет AAAA ---
# Старая форма секций (только ip v4, как до fix) + live-DNS: A идёт в sentinel,
# а AAAA уходит upstream (публичный ответ) — bypass RT. Этот кейс КРАСНЕЕТ на
# старом коде (verify не проверял AAAA вовсе) и документирует дыру; следом
# apply лечит секции в dual и leak исчезает.
_reset
printf 'type=hostrecord\nname=rutracker.org\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_rutracker_org"
# v4-only форма: v6-sentinel dnsmasq НЕ обещан (want-v6 пуст для домена),
# upstream отдаёт публичный AAAA (want-leak) — модель dnsmasq 2.93.
grep -vxF 'rutracker.org' "$T/nslookup-want-v6" > "$T/nslookup-want-v6.new" 2>/dev/null || : > "$T/nslookup-want-v6.new"
mv -f "$T/nslookup-want-v6.new" "$T/nslookup-want-v6"
printf '%s\n' "rutracker.org" >> "$T/nslookup-want-leak"
_bug_out="$(nslookup rutracker.org 127.0.0.1 2>/dev/null)"
assert_contains "BUG: A идёт в sentinel" "$T/nslookup.log" "nslookup:rutracker.org"
if printf '%s' "$_bug_out" | grep -qF '2001:db8:dead::1'; then
    _t_ok
else
    _t_bad "BUG не воспроизвёлся: v4-only обязан течь AAAA upstream"
fi
if printf '%s' "$_bug_out" | grep -qF '2001:db8::1:1445'; then
    _t_bad "BUG: v4-only откуда-то отдаёт v6-sentinel"
else
    _t_ok
fi
# apply чинит секцию в dual — leak закрыт тем же моком
# (want-v6 возвращаем ДО apply: собственный verify apply требует обе семьи):
rm -f "$T/nslookup-want-leak"
printf '%s\n' "rutracker.org" >> "$T/nslookup-want-v6"
z2k_ow_rt_dns_apply >/dev/null 2>&1 || _t_bad "heal rc"
_heal_out="$(nslookup rutracker.org 127.0.0.1 2>/dev/null)"
assert_contains "heal: A sentinel" "$T/nslookup.log" "nslookup:rutracker.org"
if printf '%s' "$_heal_out" | grep -qF '2001:db8:dead::1'; then
    _t_bad "heal: leak остался"
else
    _t_ok
fi
if printf '%s' "$_heal_out" | grep -qF '2001:db8::1:1445'; then
    _t_ok
else
    _t_bad "heal: AAAA не отдаёт v6-sentinel"
fi
assert_contains "heal: секция dual" "$T/uci/dhcp/z2k_rt_rutracker_org" "10.171.171.171 2001:db8::1:1445"

# --- RT1-DNS: fresh apply: 5 created + commit + reload + verify ---
_reset
_out="$(z2k_ow_rt_dns_apply 2>"$T/err")"
assert_eq "apply rc" "0" "$?"
printf '%s\n' "$_out" > "$T/out"
assert_eq "5 секций" "5" "$(ls "$T/uci/dhcp" | wc -l | tr -d ' ')"
assert_eq "commit один" "1" "$(grep -c '^commit:dhcp$' "$T/uci.log")"
assert_contains "reload вызван" "$T/dnsmasq.log" "dnsmasq:reload"
assert_contains "CREATED rutracker.org (stdout)" "$T/out" "DNS_CREATED: rutracker.org"
[ -s "$T/err" ] && _t_bad "диагностика утекла в stdout" || _t_ok
# содержимое секций точное (dual: v4 + v6 в одной option ip)
assert_eq "имя секции" "rutracker.org" "$(sed -n 's/^name=//p' "$T/uci/dhcp/z2k_rt_rutracker_org")"
assert_eq "ip секции dual" "10.171.171.171 2001:db8::1:1445" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/z2k_rt_rutracker_org")"
if grep -q 'ipv6' "$T"/uci/dhcp/*; then _t_bad "AAAA в секциях"; else _t_ok; fi

# --- идемпотентность: повтор без commit/reload, все PRESERVED ---
: > "$T/uci.log"; : > "$T/dnsmasq.log"
_out="$(z2k_ow_rt_dns_apply 2>/dev/null)"
assert_eq "повтор rc" "0" "$?"
assert_eq "повтор: commit нет" "0" "$(grep -c '^commit:' "$T/uci.log" 2>/dev/null || true)"
assert_eq "повтор: reload нет" "0" "$(grep -c . "$T/dnsmasq.log" 2>/dev/null || true)"
assert_eq "PRESERVED x5" "5" "$(printf '%s' "$_out" | grep -c '^DNS_PRESERVED: ')"

# --- RT2 exactness: foo.rutracker.org не трогаем и не создаём ---
_reset
printf 'type=hostrecord\nname=foo.rutracker.org\nip=1.2.3.4\n' > "$T/uci/dhcp/user_sub"
z2k_ow_rt_dns_apply >/dev/null 2>&1
assert_eq "чужой сабдомен цел" "1.2.3.4" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/user_sub")"
[ -f "$T/uci/dhcp/z2k_rt_foo_rutracker_org" ] && _t_bad "создана секция сабдомена" || _t_ok

# --- RT3 legacy: старые ours удаляются ---
_reset
printf 'type=hostrecord\nname=www.rutracker.org\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_www_rutracker_org"
printf 'type=hostrecord\nname=rutracker.cc\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_rutracker_cc"
z2k_ow_rt_dns_apply >/dev/null 2>&1
[ -f "$T/uci/dhcp/z2k_rt_www_rutracker_org" ] && _t_bad "legacy www не удалён" || _t_ok
[ -f "$T/uci/dhcp/z2k_rt_rutracker_cc" ] && _t_bad "legacy cc не удалён" || _t_ok
assert_eq "active все стоят" "5" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_')"

# --- RT16 conflict: чужой same-domain другой IP -> громкий отказ без записи ---
_reset
printf 'type=hostrecord\nname=rutracker.org\nip=9.9.9.9\n' > "$T/uci/dhcp/user_pin"
z2k_ow_rt_dns_apply >/dev/null 2>"$T/err" && _t_bad "конфликт принят" || _t_ok
assert_contains "конфликт объяснён" "$T/err" "конфликт DNS"
[ -f "$T/uci/dhcp/z2k_rt_rutracker_org" ] && _t_bad "наша секция создана поверх конфликта" || _t_ok
assert_eq "commit при конфликте нет" "0" "$(grep -c '^commit:' "$T/uci.log" 2>/dev/null || true)"
assert_eq "чужой цел" "9.9.9.9" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/user_pin")"
# тот же IP под чужим именем — тоже конфликт (duplicate ambiguity)
_reset
printf 'type=hostrecord\nname=RUTRACKER.ORG\nip=10.171.171.171 2001:db8::1:1445\n' > "$T/uci/dhcp/user_same"
z2k_ow_rt_dns_apply >/dev/null 2>&1 && _t_bad "дубликат принят" || _t_ok
# чужой v4-correct, но без v6 — тоже конфликт (дописать в чужую нельзя)
_reset
printf 'type=hostrecord\nname=api.rutracker.cc\nip=10.171.171.171\n' > "$T/uci/dhcp/user_v4only"
z2k_ow_rt_dns_apply >/dev/null 2>&1 && _t_bad "чужой v4-only принят" || _t_ok
# своя v4-only секция (pre-dual эпоха) — лечится stage-fix, не конфликт
_reset
printf 'type=hostrecord\nname=rep.rutracker.cc\nip=10.171.171.171\n' > "$T/uci/dhcp/z2k_rt_rep_rutracker_cc"
z2k_ow_rt_dns_apply >/dev/null 2>&1 || _t_bad "heal v4-only rc"
assert_eq "heal дописал v6" "10.171.171.171 2001:db8::1:1445" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/z2k_rt_rep_rutracker_cc")"

# --- multi-instance и отсутствие uci ---
_reset
: > "$T/uci/multi"
z2k_ow_rt_dns_apply >/dev/null 2>&1 && _t_bad "multi-instance принят" || _t_ok
rm -f "$T/uci/multi"
mv "$T/bin/uci" "$T/bin/uci.hidden"
PATH="/usr/bin:/bin" z2k_ow_rt_dns_apply >/dev/null 2>&1 && _t_bad "без uci принят" || _t_ok
mv "$T/bin/uci.hidden" "$T/bin/uci"

# --- remove: только ours, чужие целы ---
_reset
printf 'type=hostrecord\nname=my.home\nip=192.168.1.5\n' > "$T/uci/dhcp/user_home"
z2k_ow_rt_dns_apply >/dev/null 2>&1 || _t_bad "setup apply"
_out="$(z2k_ow_rt_dns_remove 2>/dev/null)"
assert_eq "remove rc" "0" "$?"
assert_eq "наших не осталось" "0" "$(ls "$T/uci/dhcp" | grep -c '^z2k_rt_' || true)"
assert_eq "чужой цел" "192.168.1.5" "$(sed -n 's/^ip=//p' "$T/uci/dhcp/user_home")"
assert_eq "REMOVED x5" "5" "$(printf '%s' "$_out" | grep -c '^DNS_REMOVED: z2k_rt_')"

# --- reload недостаточен -> restart fallback ---
_reset
: > "$T/dnsmasq-fail-reload"
_out="$(z2k_ow_rt_dns_apply 2>/dev/null)"
assert_eq "fallback rc" "0" "$?"
assert_contains "restart вызван" "$T/dnsmasq.log" "dnsmasq:restart"

_t_done
