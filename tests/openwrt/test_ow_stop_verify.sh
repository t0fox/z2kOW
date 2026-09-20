#!/bin/sh
# tests/openwrt/test_ow_stop_verify.sh - fail-closed stop (audit F).
# core-ready снимается FIRST (даже при провале teardown), ошибки teardown
# агрегируются (молчаливого частичного стопа нет), stop_verify доказывает
# отсутствие owned redirect/DNS/PBR/jumps. INIT_APPLY_FW=0: чужой fw не
# судим — ложного nonzero нет.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-stop-verify"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-stopv.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/uci"
export PATH="$T/bin:/usr/bin:/bin"

# --- stub nft: dirty программируется флагами ---
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft:$*" >> "$CALLS"
if [ "$1" = "list" ] && [ "$2" = "chain" ]; then
    _c="$5"
    _found=0
    if [ -f "$DIRTY/dirty-jump" ]; then
        case "$_c" in
            postnat_hook) echo 'meta mark and 0x40000000 == 0 jump postnat'; _found=1 ;;
            prenat_hook) echo 'meta mark and 0x40000000 == 0 jump prenat'; _found=1 ;;
        esac
    fi
    if [ -f "$DIRTY/dirty-chain" ]; then
        case "$_c" in
            z2k_tg_dst_pre|z2k_rt_dst_pre) echo 'placeholder'; _found=1 ;;
        esac
    fi
    # Чисто: chain ОТСУТСТВУЕТ (teardown удаляет) -> exit 1.
    [ "$_found" = "1" ] && exit 0 || exit 1
fi
exit 0
EOF
chmod +x "$T/bin/nft"
# --- stub uci ---
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
echo "uci:$*" >> "$CALLS"
if [ -f "$DIRTY/uci-fail" ]; then exit 1; fi
case "$1" in
    show) [ -f "$DIRTY/dirty-dns" ] && echo 'dhcp.z2k_rt_rutracker_org=hostrecord'; exit 0 ;;
    -q) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/uci"
# --- stub ip ---
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "ip:$*" >> "$CALLS"
if [ "$1" = "rule" ] && [ "$2" = "show" ]; then
    [ -f "$DIRTY/dirty-pbr" ] && echo '500: from all fwmark 0x80000000/0x80000000 lookup 989'
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/ip"
export CALLS="$T/calls" DIRTY="$T"
: > "$T/calls"

# --- грузим настоящий init, лоадер — настоящее нужное ---
# (fw_remove НАСТОЯЩИЙ — идёт через fixture functions ниже, как в start_gate:
# стаб здесь перезатёр бы лоадер внутри stop_service).
export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
export Z2K_RUN="$T/run" Z2K_CONFIG="$T/etc/config"
export Z2K_ZAPRET2_RUNTIME="$T/rt"
mkdir -p "$T/etc" "$T/tmp" "$T/tmp/locks" "$T/run" "$T/rt/init.d/openwrt"
printf 'ENABLED=1\nQNUM=200\n' > "$T/etc/config"
printf '#!/bin/sh\nexit 0\n' > "$T/dnsmasq-init"
chmod +x "$T/dnsmasq-init"
export Z2K_DNSMASQ_INIT="$T/dnsmasq-init"
cat > "$T/rt/init.d/openwrt/functions" <<EOF
#!/bin/sh
zapret_apply_firewall() { echo "fw:apply" >> "$T/calls"; return 0; }
zapret_unapply_firewall() { echo "fw:remove" >> "$T/calls"; [ -f "$T/fw-remove-fail" ] && return 1; return 0; }
zapret_reload_ifsets() { return 0; }
EOF
# shellcheck disable=SC1090,SC1091
. "$REPO/package/openwrt/files/etc/init.d/z2k" || { echo "FAIL[ow-stop-verify]: source init" >&2; exit 1; }
z2k_load_adapter() {
    # shellcheck disable=SC1090,SC1091
    . "$REPO/platform/openwrt/firewall.sh" || return 1
    . "$REPO/platform/openwrt/customd.sh" || return 1
    . "$REPO/platform/openwrt/tg.sh" || return 1
    . "$REPO/platform/openwrt/rt.sh" || return 1
    Z2K_WARP_SOURCE_ONLY=1; export Z2K_WARP_SOURCE_ONLY
    . "$REPO/platform/openwrt/warp.sh" || return 1
    return 0
}

_run_stop() { : > "$T/calls"; : > "$T/run/core-ready"; stop_service >/dev/null 2>&1; echo "rc=$?" >> "$T/calls"; }

# --- 1. чистый стоп: rc 0, ready снят ---
_run_stop
assert_contains "clean rc 0" "$T/calls" "rc=0"
[ -f "$T/run/core-ready" ] && _t_bad "clean: ready остался" || _t_ok

# --- 2. teardown-провал (fw-remove): rc 1, ready ВСЁ РАВНО снят FIRST ---
printf '' > "$T/fw-remove-fail"
_run_stop
assert_contains "teardown-fail rc" "$T/calls" "rc=1"
[ -f "$T/run/core-ready" ] && _t_bad "fail: ready остался" || _t_ok
rm -f "$T/fw-remove-fail"

# --- 3. verify находит jump: rc 1 ---
printf '' > "$T/dirty-jump"
_run_stop
assert_contains "dirty-jump rc" "$T/calls" "rc=1"
rm -f "$T/dirty-jump"

# --- 4. verify находит chain: rc 1 ---
printf '' > "$T/dirty-chain"
_run_stop
assert_contains "dirty-chain rc" "$T/calls" "rc=1"
rm -f "$T/dirty-chain"

# --- 5. verify находит DNS-пин: rc 1 ---
printf '' > "$T/dirty-dns"
_run_stop
assert_contains "dirty-dns rc" "$T/calls" "rc=1"
rm -f "$T/dirty-dns"

# --- 6. verify находит PBR: rc 1 ---
printf '' > "$T/dirty-pbr"
_run_stop
assert_contains "dirty-pbr rc" "$T/calls" "rc=1"
rm -f "$T/dirty-pbr"

# --- 7. INIT_APPLY_FW=0 + грязный fw: rc 0 (чужое не судим) ---
printf '' > "$T/dirty-jump"
INIT_APPLY_FW=0; export INIT_APPLY_FW
_run_stop
assert_contains "no-fw rc 0" "$T/calls" "rc=0"
unset INIT_APPLY_FW
rm -f "$T/dirty-jump"

_t_done
