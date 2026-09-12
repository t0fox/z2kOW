#!/bin/sh
# tests/openwrt/test_ow_tg_lifecycle.sh - Stage 3 Layer C: TG1-TG16.
# procd/nft/conntrack/curl/pidof — stub'ы; реальный код tg.sh in-process.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-lifecycle"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tglc.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/root/bin" "$T/root/etc" "$T/etc" "$T/tmp" "$T/proc"
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
cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "curl:\$*" >> "$T/curl.log"
exit "\$(cat $T/curl.rc 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/curl"

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
. "$REPO/platform/openwrt/tg.sh" || { echo "FAIL[ow-tg-lifecycle]: source" >&2; exit 1; }

procd_open_instance() { echo "instance:$1" >> "$T/procd.log"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/procd.log"; }
procd_close_instance() { echo "close" >> "$T/procd.log"; }
# kill — shell builtin, PATH-стабом не перехватить: переопределяем helper
# из tg.sh (procd в проде поднимет процесс сам; здесь только записываем).
_z2k_ow_tg_kill() { echo "kill:$*" >> "$T/kill.log"; return 0; }

_reset() {
    : > "$T/nft.log"; : > "$T/conntrack.log"; : > "$T/procd.log"
    : > "$T/kill.log"; : > "$T/curl.log"
    printf 'ENABLED=1\n' > "$T/etc/config"
    rm -f "$T/no-table"; rm -rf "$T/tmp/tg-health"
    printf '\n' > "$T/pidof.out"; printf '0\n' > "$T/curl.rc"
    chmod +x "$T/root/bin/tg-mtproxy-client"
}

# --- TG1: enabled + start: один instance, оба порта, все правила ---
_reset
z2k_ow_tg 1 || _t_bad "TG1: tg 1 rc"
assert_eq "TG1: один instance" "1" "$(grep -c '^instance:z2k-tg$' "$T/procd.log")"
assert_contains "TG1: оба порта в command" "$T/procd.log" "--listen=:1443"
assert_contains "TG1: cdn порт в command" "$T/procd.log" "--listen=:1444"
assert_eq "TG1: правил 6" "6" "$(grep -c '^nft:add rule' "$T/nft.log")"
assert_eq "TG1: сетов 3" "3" "$(grep -c '^nft:add element' "$T/nft.log")"

# --- TG2: user-disable: нет процесса, нет правил ---
_reset
printf 'ENABLED=1\nTG_PROXY_USER_DISABLED=1\n' > "$T/etc/config"
z2k_ow_tg 1
assert_eq "TG2: instance нет" "0" "$(grep -c '^instance:' "$T/procd.log")"
assert_eq "TG2: правил нет" "0" "$(grep -c '^nft:add rule' "$T/nft.log")"
z2k_ow_tg check
assert_eq "TG2: check тих" "0" "$(grep -c '^kill:' "$T/kill.log")"

# --- TG3: global ENABLED=0: нет процесса, нет правил ---
_reset
printf 'ENABLED=0\n' > "$T/etc/config"
z2k_ow_tg 1
assert_eq "TG3: instance нет" "0" "$(grep -c '^instance:' "$T/procd.log")"
assert_eq "TG3: правил нет" "0" "$(grep -c '^nft:add rule' "$T/nft.log")"

# --- TG4: повторный старт: один owner, дублей нет ---
_reset
z2k_ow_tg 1 && z2k_ow_tg 1
assert_eq "TG4: instance открыты дважды (procd converged)" "2" "$(grep -c '^instance:z2k-tg$' "$T/procd.log")"
_n1="$(grep -c '^nft:add rule' "$T/nft.log")"
assert_eq "TG4: правил за 2 прогона 12 (flush+add, состояние то же)" "12" "$_n1"

# --- TG5: WAN flap (rules): PID stable, демон не тронут ---
_reset
printf '4242\n' > "$T/pidof.out"
mkdir -p "$T/proc/4242"
printf 'tg-mtproxy-client --listen=:1443 --listen=:1444' | tr ' ' '\0' > "$T/proc/4242/cmdline"
z2k_ow_tg rules || _t_bad "TG5: rules rc"
assert_eq "TG5: kill нет" "0" "$(grep -c '^kill:' "$T/kill.log")"
assert_eq "TG5: instance не открывали" "0" "$(grep -c '^instance:' "$T/procd.log")"
assert_eq "TG5: правила сошлись" "6" "$(grep -c '^nft:add rule' "$T/nft.log")"

# --- TG6: firewall reload (таблица пересоздана runtime): правила вернулись без рестарта ---
_reset
: > "$T/no-table"
z2k_ow_tg rules 2>/dev/null && _t_bad "TG6: rules без таблицы приняты" || _t_ok
rm -f "$T/no-table"
z2k_ow_tg rules || _t_bad "TG6: rules после возврата таблицы"
assert_eq "TG6: демон не трогали (нет instance/kill)" "0" "$(cat "$T/procd.log" "$T/kill.log" 2>/dev/null | grep -c -e '^instance:' -e '^kill:' || true)"

# --- TG7: crash: procd владеет respawn, второго supervisor нет ---
_reset
z2k_ow_tg check
assert_eq "TG7: check при мёртвом процессе молчит" "0" "$(grep -c '^kill:' "$T/kill.log")"
assert_eq "TG7: fails не заведён" "0" "$([ -f "$T/tmp/tg-health/fails" ] && echo 1 || echo 0)"

# --- TG8/TG9/TG10: shapes (детально в firewall-suite; здесь — наличие) ---
_reset
z2k_ow_tg rules || _t_bad "TG8-10: rules rc"
assert_eq "TG8: 443->1443 x2" "2" "$(grep -c 'dport 443.*redirect to :1443' "$T/nft.log")"
assert_eq "TG9: v6 reject x2, не redirect" "2" "$(grep -c 'ip6 daddr @z2k_tg_dc6 reject with tcp reset' "$T/nft.log")"
assert_eq "TG10: 80->1444 x2, тот же процесс" "2" "$(grep -c 'dport 80.*redirect to :1444' "$T/nft.log")"

# --- TG11: stop: chains gone, sets stay; cleanup: sets gone ---
_reset
z2k_ow_tg rules >/dev/null 2>&1
: > "$T/nft.log"
z2k_ow_tg 0
assert_eq "TG11: chains сняты (4 delete)" "4" "$(grep -c '^nft:delete chain' "$T/nft.log")"
assert_eq "TG11: sets целы" "0" "$(grep -c '^nft:delete set' "$T/nft.log")"
: > "$T/nft.log"
z2k_ow_tg cleanup
assert_eq "TG11: cleanup сносит sets" "3" "$(grep -c '^nft:delete set' "$T/nft.log")"

# --- TG12: conntrack только целевой ---
_reset
: > "$T/conntrack.log"
z2k_ow_tg 1 >/dev/null 2>&1
assert_eq "TG12: 11 записей" "11" "$(grep -c '^conntrack:-D -d' "$T/conntrack.log")"

# --- TG13: au_service_for_binary: openwrt -> z2k, keenetic цел ---
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || { echo "FAIL[ow-tg-lifecycle]: au source" >&2; exit 1; }
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
assert_eq "TG13: openwrt owner" "/etc/init.d/z2k" "$(au_service_for_binary tg-mtproxy-client)"
unset Z2K_PLATFORM
assert_eq "TG13: keenetic intact" "/opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97z2k-http-tunnel" "$(au_service_for_binary tg-mtproxy-client)"

# --- TG14: probe fails: тихо до 3, kill на 3-м, backoff держит, шторма нет ---
_reset
printf '4242\n' > "$T/pidof.out"
printf '1\n' > "$T/curl.rc"
z2k_ow_tg check; assert_eq "TG14: fail1 тих" "0" "$(grep -c '^kill:' "$T/kill.log")"
z2k_ow_tg check; assert_eq "TG14: fail2 тих" "0" "$(grep -c '^kill:' "$T/kill.log")"
z2k_ow_tg check; assert_eq "TG14: fail3 kill" "1" "$(grep -c '^kill:' "$T/kill.log")"
assert_contains "TG14: убит наш pid" "$T/kill.log" "kill:4242"
z2k_ow_tg check; assert_eq "TG14: backoff держит 2-й kill" "1" "$(grep -c '^kill:' "$T/kill.log")"
# converge на probe-пути — flush+add, delete не бывает вовсе:
if grep -q '^nft:delete' "$T/nft.log"; then
    _t_bad "TG14: probe-путь сносит правила"
else
    _t_ok
fi
# успех сбрасывает счётчики
printf '0\n' > "$T/curl.rc"
z2k_ow_tg check
assert_eq "TG14: успех чистит fails" "0" "$([ -f "$T/tmp/tg-health/fails" ] && echo 1 || echo 0)"

# --- TG15: disable во время работы: стоп + снять + не воскрешать ---
_reset
printf '4242\n' > "$T/pidof.out"
z2k_ow_tg check >/dev/null 2>&1
printf 'ENABLED=1\nTG_PROXY_USER_DISABLED=1\n' > "$T/etc/config"
z2k_ow_tg check
assert_contains "TG15: процесс добит" "$T/kill.log" "kill:4242"
assert_contains "TG15: chains сняты" "$T/nft.log" "delete chain inet zapret z2k_tg_dst_pre"
# процесс умер (симулируем смерть для pidof), повтор тих и не воскрешает:
printf '\n' > "$T/pidof.out"
: > "$T/kill.log"; : > "$T/nft.log"
z2k_ow_tg check
assert_eq "TG15: повтор тих (не воскрешает)" "0" "$(grep -c '^kill:' "$T/kill.log")"
assert_eq "TG15: правил не ставит" "0" "$(grep -c '^nft:add rule' "$T/nft.log")"

# --- TG16: self-dial: редиректы только на DC/CDN-сеты ---
_reset
z2k_ow_tg rules >/dev/null 2>&1
if grep '^nft:add rule' "$T/nft.log" | grep -vE '@z2k_tg_(dc4|dc6|cdn4)' >/dev/null 2>&1; then
    _t_bad "TG16: правило мимо DC/CDN-сетов"
else
    _t_ok
fi

_t_done
