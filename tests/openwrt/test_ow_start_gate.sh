#!/bin/sh
# tests/openwrt/test_ow_start_gate.sh - fail-closed старт (live-урок p-84.17).
# apply вернул 0 без hook jumps, старт продолжил в TG/RT/WARP и отдал success
# при мёртвом dataplane. Теперь транзакция (порядок E): preflight → instance
# → wait consumer → fw apply → fw verify → TG → RT → WARP → core-ready LAST;
# любой required-провал = rollback (consumer убит, partial fw снят) + rc 1,
# TG/RT/WARP дальше провала не стартуют. Плюс preflight ловит 0644 runtime
# executables (runtime_not_executable с точным путём).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-start-gate"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-sgate.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/rt"
: > "$T/calls" || exit 1
export PATH="$T/bin:/usr/bin:/bin"

# --- stub nft: ответы программируются файлами-флагами ---
cat > "$T/bin/nft" <<EOF
#!/bin/sh
echo "nft:\$*" >> "$T/calls"
if [ "\$1" = "list" ] && [ "\$2" = "set" ]; then
    [ -f "$T/nft-noset" ] && exit 1
    case "\$5" in
        wanif) echo 'set wanif { type ifname; elements = { "wan" } }' ;;
        wanif6) echo 'set wanif6 { type ifname; }' ;;
        *) echo "set \$5 { type ipv4_addr; elements = { 10.0.0.0/8 } }" ;;
    esac
    exit 0
fi
if [ "\$1" = "list" ] && [ "\$2" = "chain" ]; then
    _c="\$5"
    if [ -f "$T/nft-nojump" ]; then echo "empty chain"; exit 0; fi
    case "\$_c" in
        postnat_hook) echo 'meta mark and 0x40000000 == 0 jump postnat' ;;
        prenat_hook) echo 'meta mark and 0x40000000 == 0 jump prenat' ;;
        postnat) echo 'queue flags bypass to 200' ;;
        prenat) echo 'queue flags bypass to 200' ;;
        *) echo "empty chain" ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"

# --- fixture runtime (functions со stub zapret_*) ---
mkdir -p "$T/rt/init.d/openwrt" "$T/rt/nfq2" "$T/rt/ip2net" "$T/rt/mdig" \
         "$T/rt/lua" "$T/rt/common" "$T/rt/ipset" "$T/abindir"
cat > "$T/rt/init.d/openwrt/functions" <<EOF
#!/bin/sh
zapret_apply_firewall() { echo "fw:apply" >> "$T/calls"; [ -f "$T/fw-apply-fail" ] && return 1; return 0; }
zapret_unapply_firewall() { echo "fw:remove" >> "$T/calls"; return 0; }
zapret_reload_ifsets() { return 0; }
EOF
for _b in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
    printf '#!/bin/sh\nexit 0\n' > "$T/rt/$_b"; chmod +x "$T/rt/$_b"
done
printf 'x\n' > "$T/rt/lua/zapret-lib.lua"
printf 'x\n' > "$T/rt/lua/zapret-antidpi.lua"
printf 'x\n' > "$T/rt/lua/zapret-auto.lua"
for _c in base.sh fwtype.sh linux_iphelper.sh ipt.sh nft.sh linux_fw.sh linux_daemons.sh list.sh custom.sh; do
    printf '# stub\n' > "$T/rt/common/$_c"
done
printf '#!/bin/sh\nexit 0\n' > "$T/rt/ipset/create_ipset.sh"
chmod +x "$T/rt/ipset/create_ipset.sh"
printf '# stub\n' > "$T/rt/ipset/def.sh"
for _b in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    printf '#!/bin/sh\n# stub (rt: so-mark capable, см. preflight)\n# so-mark\nexit 0\n' > "$T/abindir/$_b"; chmod +x "$T/abindir/$_b"
done

# --- грузим настоящий init, но адаптер-лоадер подменяем: старту нужен
# ТОЛЬКО настоящий firewall.sh (preflight/fw_apply/fw_verify); остальное —
# стабы ниже. (Полный load покрыт test_ow_source_order; здесь важен порядок
# гейтов, а не загрузка. Прямая подмена обязательна: настоящий лоадер,
# вызванный внутри start_service, перезатёр бы стабы реальными функциями.)
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_ZAPRET2_RUNTIME="$T/rt" Z2K_BIN="$T/abindir" Z2K_NFQWS2="$T/rt/nfq2/nfqws2"
export Z2K_RUN="$T/run" Z2K_CONFIG="$T/etc/config"
mkdir -p "$T/etc" "$T/tmp" "$T/run"
printf 'ENABLED=1\nQNUM=200\n' > "$T/etc/config"
# Consumer-фикстура (порядок E: instance → wait consumer → fw → TG/RT):
# живой pid в pidfile + fake nfnetlink_queue с очередью 200.
sleep 60 & _BG=$!
trap 'kill "$_BG" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
printf '%s\n' "$_BG" > "$T/run/nfqws2.pid"
printf '200 4242 0 2 65531 0 0 0 1\n' > "$T/nfqueue"
export Z2K_NFQUEUE_PROC="$T/nfqueue" Z2K_START_CONSUMER_TIMEOUT=3
# shellcheck disable=SC1090,SC1091
. "$REPO/package/openwrt/files/etc/init.d/z2k" || { echo "FAIL[ow-start-gate]: source init" >&2; exit 1; }
# Стабы тяжёлого (порядок/гейты настоящие: preflight/fw_apply/fw_verify/procd):
z2k_load_adapter() {
    # shellcheck disable=SC1090,SC1091
    . "$REPO/platform/openwrt/firewall.sh" || return 1
    return 0
}
z2k_ow_bootstrap() { echo "boot" >> "$T/calls"; return 0; }
z2k_ow_generate() { echo "gen" >> "$T/calls"; return 0; }
z2k_ow_optbase() { echo "95-optbase-stub"; return 0; }
z2k_ow_custom_daemons() { echo "custom:$1" >> "$T/calls"; return 0; }
z2k_ow_tg() { echo "tg:$1" >> "$T/calls"; return 0; }
z2k_ow_rt() { echo "rt:$1" >> "$T/calls"; return 0; }
z2k_ow_tg_verify() { echo "tg-verify" >> "$T/calls"; [ -f "$T/tg-verify-fail" ] && return 1; return 0; }
z2k_ow_rt_verify() { echo "rt-verify" >> "$T/calls"; [ -f "$T/rt-verify-fail" ] && return 1; return 0; }
z2k_ow_warp() { echo "warp:$1" >> "$T/calls"; return 0; }
z2k_ow_lan() { printf 'br-lan'; return 0; }
procd_open_instance() { echo "instance:$1" >> "$T/calls"; return 0; }
procd_set_param() { echo "param:$*" >> "$T/calls"; return 0; }
procd_close_instance() { echo "instance-close" >> "$T/calls"; return 0; }

_run() {
    # Свежий живой consumer на каждый прогон (rollback прошлого кейса его убил).
    kill "$_BG" 2>/dev/null
    sleep 60 & _BG=$!
    printf '%s\n' "$_BG" > "$T/run/nfqws2.pid"
    : > "$T/calls"; start_service >/dev/null 2>&1; echo "rc=$?" >> "$T/calls"
}
_consumer_dead() {
    # rollback убил consumer'а: pid из pidfile мёртв.
    _p="$(cat "$T/run/nfqws2.pid" 2>/dev/null)"
    [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null
}

# --- 1. всё хорошо: rc 0, instance открыт, все фичи стартовали ---
_run
assert_contains "happy rc 0" "$T/calls" "rc=0"
assert_contains "happy instance" "$T/calls" "instance:z2k"
assert_contains "happy tg" "$T/calls" "tg:1"
assert_contains "happy rt" "$T/calls" "rt:1"
assert_contains "happy warp" "$T/calls" "warp:1"
assert_contains "happy fw applied" "$T/calls" "fw:apply"

# --- 2. fw_apply FAIL: rc 1, rollback, TG/RT/WARP не стартовали ---
# (порядок E: instance УЖЕ открыт до гейта — по дизайну; rollback обязан
# убить consumer и снять partial fw).
: > "$T/fw-apply-fail" 2>/dev/null; printf '' > "$T/fw-apply-fail"
_run
assert_contains "apply-fail rc" "$T/calls" "rc=1"
assert_contains "apply-fail rollback" "$T/calls" "fw:remove"
assert_contains "apply-fail instance был открыт" "$T/calls" "instance:z2k"
for _s in "tg:1" "rt:1" "warp:1" "custom:1"; do
    grep -qF "$_s" "$T/calls" && _t_bad "apply-fail: стартовало $_s" || _t_ok
done
_consumer_dead && _t_ok || _t_bad "apply-fail: consumer не убит rollback'ом"
rm -f "$T/fw-apply-fail"

# --- 3. apply ok + verify FAIL (нет jumps): то же самое ---
printf '' > "$T/nft-nojump"
_run
assert_contains "verify-fail rc" "$T/calls" "rc=1"
assert_contains "verify-fail rollback" "$T/calls" "fw:remove"
for _s in "tg:1" "rt:1" "warp:1"; do
    grep -qF "$_s" "$T/calls" && _t_bad "verify-fail: стартовало $_s" || _t_ok
done
_consumer_dead && _t_ok || _t_bad "verify-fail: consumer не убит rollback'ом"
rm -f "$T/nft-nojump"

# --- 4. apply ok + verify FAIL (нет сетов) ---
printf '' > "$T/nft-noset"
_run
assert_contains "noset rc" "$T/calls" "rc=1"
assert_contains "noset rollback" "$T/calls" "fw:remove"
rm -f "$T/nft-noset"

# --- 4b. required TG FAIL: rc 1, rollback, RT/WARP не стартовали ---
printf '' > "$T/tg-verify-fail"
_run
assert_contains "tg-fail rc" "$T/calls" "rc=1"
assert_contains "tg-fail rollback" "$T/calls" "fw:remove"
for _s in "rt:1" "warp:1"; do
    grep -qF "$_s" "$T/calls" && _t_bad "tg-fail: стартовало $_s" || _t_ok
done
assert_contains "tg-fail tg был" "$T/calls" "tg:1"
_consumer_dead && _t_ok || _t_bad "tg-fail: consumer не убит rollback'ом"
rm -f "$T/tg-verify-fail"

# --- 4c. required RT FAIL: rc 1, rollback, WARP не стартовал ---
printf '' > "$T/rt-verify-fail"
_run
assert_contains "rt-fail rc" "$T/calls" "rc=1"
assert_contains "rt-fail rollback" "$T/calls" "fw:remove"
grep -qF "warp:1" "$T/calls" && _t_bad "rt-fail: стартовал warp" || _t_ok
assert_contains "rt-fail tg был" "$T/calls" "tg:1"
assert_contains "rt-fail rt был" "$T/calls" "rt:1"
rm -f "$T/rt-verify-fail"

# --- 5. preflight ловит 0644 create_ipset.sh ДО всего ---
chmod 0644 "$T/rt/ipset/create_ipset.sh"
_out="$(z2k_ow_runtime_preflight 2>&1)"; _rc=$?
assert_eq "preflight 0644 rc" "1" "$_rc"
case "$_out" in
    *"runtime_not_executable: $T/rt/ipset/create_ipset.sh"*) _t_ok ;;
    *) _t_bad "preflight 0644 без точного пути: [$_out]" ;;
esac
chmod +x "$T/rt/ipset/create_ipset.sh"
z2k_ow_runtime_preflight >/dev/null 2>&1 \
    && _t_ok || _t_bad "preflight 0755 упал"

# --- 6. preflight ловит 0644 nfqws2 ---
chmod 0644 "$T/rt/nfq2/nfqws2"
z2k_ow_runtime_preflight >/dev/null 2>&1 \
    && _t_bad "preflight 0644 nfqws2 прошёл" || _t_ok
chmod +x "$T/rt/nfq2/nfqws2"

_t_done
