#!/bin/sh
# tests/openwrt/test_ow_fw_check.sh - p-84.20 parity: periodic сверка КАЖДОГО
# required инварианта (не count). Фикстура: удалить ОДИН required rule —
# verifier обязан найти ровно его; reconvergence восстанавливает / degraded.
# На live правила не трогаем (только fixture/CI).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-fw-check"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-fwchk.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin"
export PATH="$T/bin:/usr/bin:/bin"
# stateful nft: healthy|drift-one-jump|broken (флаги).
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft:$*" >> "$CALLS"
if [ "$1" = "list" ] && [ "$2" = "set" ]; then
    case "$5" in
        wanif) echo 'set wanif { type ifname; elements = { "wan" } }' ;;
        wanif6) echo 'set wanif6 { type ifname; }' ;;
        *) echo "set $5 { type ipv4_addr; elements = { 10.0.0.0/8 } }" ;;
    esac
    exit 0
fi
if [ "$1" = "list" ] && [ "$2" = "chain" ]; then
    _c="$5"
    case "$_c" in
        postnat_hook)
            echo 'meta mark and 0x40000000 == 0 jump postnat'
            ;;
        prenat_hook)
            if [ -f "$DIRTY/drop-prenat" ]; then
                echo 'empty chain'
            else
                echo 'meta mark and 0x40000000 == 0 jump prenat'
            fi
            ;;
        postnat|prenat) echo 'queue flags bypass to 200' ;;
        *) echo "empty chain" ;;
    esac
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
export CALLS="$T/calls" DIRTY="$T"
: > "$T/calls"

export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_RUN="$T/run"
export Z2K_CONFIG="$T/etc/config" QNUM=200 INIT_APPLY_FW=1
mkdir -p "$T/etc" "$T/tmp" "$T/run"
printf 'ENABLED=1\nQNUM=200\n' > "$T/etc/config"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/firewall.sh" || exit 1
# ready без сервиса: предикат через INIT_SCRIPT-стаб.
printf '#!/bin/sh\nexit 0\n' > "$T/init-stub"
chmod +x "$T/init-stub"
export INIT_SCRIPT="$T/init-stub"
: > "$T/run/core-ready"
# apply-стаб: чинит дрейф (убирает флаг), считает вызовы.
z2k_ow_fw_apply() { echo "fw:apply" >> "$T/calls"; rm -f "$T/drop-prenat"; return 0; }

# --- 1. healthy: rc 0, apply не звали ---
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "healthy rc" "0" "$?"
grep -q 'fw:apply' "$T/calls" && _t_bad "healthy: лишний apply" || _t_ok

# --- 2. дрейф одного jump: apply ОДИН раз, затем ok ---
printf '' > "$T/drop-prenat"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "drift rc" "0" "$?"
assert_eq "drift: ровно один apply" "1" "$(grep -c 'fw:apply' "$T/calls")"
[ -f "$T/run/core-ready" ] && _t_ok || _t_bad "drift: ready снят зря"
rm -f "$T/drop-prenat"

# --- 3. упорный провал: ready снят, демон не тронут ---
z2k_ow_fw_apply() { echo "fw:apply" >> "$T/calls"; return 0; }
printf '' > "$T/drop-prenat"
: > "$T/run/core-ready"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "broken rc" "0" "$?"
[ -f "$T/run/core-ready" ] && _t_bad "broken: ready остался" || _t_ok
rm -f "$T/drop-prenat"

# --- 4. no-ready: немедленный возврат, nft не трогаем ---
rm -f "$T/run/core-ready"
: > "$T/calls"
z2k_ow_fw_check >/dev/null 2>&1
assert_eq "no-ready rc" "0" "$?"
grep -q '^nft:' "$T/calls" && _t_bad "no-ready: полезли в nft" || _t_ok

# --- 5. INIT_APPLY_FW=0: чужой fw, скип ---
: > "$T/run/core-ready"
: > "$T/calls"
INIT_APPLY_FW=0 z2k_ow_fw_check >/dev/null 2>&1
assert_eq "no-fw rc" "0" "$?"
grep -q '^nft:' "$T/calls" && _t_bad "no-fw: полезли в nft" || _t_ok

_t_done
