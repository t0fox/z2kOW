#!/bin/sh
# tests/openwrt/test_ow_warp_parity.sh - OpenWrt/procd и Go-контракт WARP.
# Сетевое состояние, списки, блокировки и планы переходов проверяются Rust.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-parity"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cargo build --offline --locked --manifest-path "$REPO/platform/openwrt/warp-controller/Cargo.toml" --bin z2k-warp-controller
WARP_CONTROLLER_BIN="$REPO/platform/openwrt/warp-controller/target/debug/z2k-warp-controller"
export WARP_CONTROLLER_BIN
. "$REPO/tests/lib/common.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpar.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/etc" "$T/tmp" "$T/tmp/warp" "$T/proc" "$T/root/bin"
export PATH="$T/bin:/usr/bin:/bin"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft:$*" >> "$CALLS"
if [ "$1" = "list" ] && [ "$2" = "chain" ] && \
   [ "$4" = fw4 ] && [ "$5" = forward ]; then
    [ -f "$FW4_RULE" ] && cat "$FW4_RULE"
    exit 0
fi
if [ "$1" = "-a" ] && [ "$2" = "list" ] && [ "$3" = "chain" ] && \
   [ "$5" = fw4 ] && [ "$6" = forward ]; then
    [ -f "$FW4_RULE" ] && cat "$FW4_RULE"
    exit 0
fi
if [ "$1" = "insert" ] && [ "$2" = "rule" ] && \
   [ "$4" = fw4 ] && [ "$5" = forward ]; then
    _prev=""; _iface=""
    for _arg in "$@"; do
        [ "$_prev" = oifname ] && _iface="$_arg"
        _prev="$_arg"
    done
    printf 'meta mark & 0x80000000 == 0x80000000 oifname "%s" accept comment "!z2k: WARP forwarded traffic" # handle 91\n' "$_iface" > "$FW4_RULE"
    exit 0
fi
if [ "$1" = "delete" ] && [ "$2" = "rule" ] && \
   [ "$4" = fw4 ] && [ "$5" = forward ]; then
    rm -f "$FW4_RULE"
    exit 0
fi
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "ip:$*" >> "$CALLS"
if [ "$1" = "rule" ] && [ "$2" = "show" ]; then
    # have-pbr: существующее exact-наше правило (для pbr_down-пути).
    [ -f "$HAVE_PROBE" ] && echo '499: from 172.16.9.9/32 lookup 989'
    [ -f "$HAVE_PBR" ] && echo '500: from all fwmark 0x80000000/0x80000000 lookup 989'
    exit 0
fi
if [ "$1" = "rule" ] && [ "$2" = "add" ]; then
    case "$*" in *' from '*) touch "$HAVE_PROBE" ;; esac
    exit 0
fi
if [ "$1" = "rule" ] && [ "$2" = "del" ]; then
    case "$*" in
        *' pref 499 '*) rm -f "$HAVE_PROBE" ;;
        *' pref 500 '*) rm -f "$HAVE_PBR" ;;
    esac
    exit 0
fi
if [ "$1" = "route" ] && [ "$2" = "show" ]; then
    case "$*" in
        *'table 989'*) [ -f "$HAVE_ROUTE" ] && echo "default dev z2ktun0" ;;
    esac
    exit 0
fi
if [ "$1" = "route" ] && [ "$2" = "del" ] && [ "$3" = "default" ]; then
    rm -f "$HAVE_ROUTE"
    exit 0
fi
if [ "$1" = "link" ]; then exit 0; fi
exit 0
EOF
chmod +x "$T/bin/ip"
export HAVE_PBR="$T/have-pbr"
export HAVE_PROBE="$T/have-probe"
export HAVE_ROUTE="$T/have-route"
cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
cat "$PIDOF_OUT" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"
export CALLS="$T/calls" PIDOF_OUT="$T/pidof.out" FW4_RULE="$T/fw4-rule"
: > "$T/calls"

export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_STATE="$T/etc/state"
export WARP_DOMAIN_RULES="$T/tmp/warp/domains.v1"
export WARP_DOMAIN_SNAPSHOT="$T/tmp/warp/domain-pairs.v1"
export WARP_DOMAIN_STATUS="$T/tmp/warp/domain-status.json"
export WARP_DOMAIN_ERROR="$T/tmp/warp/domain-setup-error"
export Z2K_BIN="$T/root/bin" Z2K_LISTS_DIR="$T/root/lists"
export WARP_PBR_OWNER="$T/tmp/warp/pbr.owner" WARP_PROBE_OWNER="$T/tmp/warp/probe-route.owner"
mkdir -p "$T/etc/state/warp" "$T/root/lists" "$T/etc/user-lists/warp"
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
export CONFIG_FILE="$T/etc/config"
Z2K_WARP_SOURCE_ONLY=1; export Z2K_WARP_SOURCE_ONLY
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/warp.sh" || { echo "FAIL[ow-warp-parity]: source" >&2; exit 1; }

# --- 1. transport: конфиг -> валидация -> procd env ---
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=wg\n' > "$T/etc/config"
assert_eq "transport wg" "wg" "$(warp_transport)"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=h2\n' > "$T/etc/config"
assert_eq "transport h2" "h2" "$(warp_transport)"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=quic\n' > "$T/etc/config"
assert_eq "transport garbage -> auto" "auto" "$(warp_transport)"
printf 'GAME_WARP_ENABLED=1\n' > "$T/etc/config"
assert_eq "transport default auto" "auto" "$(warp_transport)"
# procd instance несёт transport env (daemon читает его сам).
procd_open_instance() { echo "instance:$1" >> "$T/calls"; }
procd_set_param() { printf 'param:%s\n' "$*" >> "$T/calls"; }
procd_close_instance() { :; }
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=h2\n' > "$T/etc/config"
: > "$T/calls"
warp_start_instance >/dev/null 2>&1
assert_contains "instance env transport" "$T/calls" "Z2K_WARP_TRANSPORT=h2"
assert_eq "instance env is one procd block" "1" "$(grep -c '^param:env ' "$T/calls")"
assert_contains "instance env carries runtime tuning" "$T/calls" "param:env GODEBUG=asyncpreemptoff=1"
assert_contains "instance env binds probe source" "$T/calls" "Z2K_WARP_PROBE_SOURCE=1"
# В старых конфигах OpenWrt может сохраниться адрес отключённого VPS-релея.
# Адаптер игнорирует его, но оставляет прочие пользовательские proxy.
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=h2\nZ2K_WARP_VPS_PROXY=http://z2kwarp:old@213.176.74.63:8119\n' > "$T/etc/config"
: > "$T/calls"
warp_start_instance >/dev/null 2>&1
if grep -q 'Z2K_WARP_VPS_PROXY=' "$T/calls"; then
    _t_bad "старый VPS proxy не удалён из окружения procd"
else
    _t_ok
fi
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_VPS_PROXY=http://proxy.example:8080\n' > "$T/etc/config"
: > "$T/calls"
warp_start_instance >/dev/null 2>&1
assert_contains "окружение экземпляра сохраняет пользовательский proxy" "$T/calls" "Z2K_WARP_VPS_PROXY=http://proxy.example:8080"

# --- 2. procd transition планирует Rust ---
assert_eq "restart выключенного WARP не пересобирает службу" "none" \
    "$($WARP_CONTROLLER_BIN service-plan restart 0 1 1)"
assert_eq "restart включённого WARP пересобирает instance" "rebuild" \
    "$($WARP_CONTROLLER_BIN service-plan restart 1 1 1)"
assert_eq "непрочитанное состояние procd откладывает restart" "defer" \
    "$($WARP_CONTROLLER_BIN service-plan restart 1 unreadable 1)"

# --- 3. license: rc-контракт + ключ не в логах ---
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
export WARP_BIN="$T/root/bin/z2k-warpd" WARP_DEVICE="$T/etc/state/warp/device.json"
mkdir -p "$T/etc/state/warp"
rm -f "$WARP_BIN"
printf 'SECRETKEY' | warp_license >/dev/null 2>&1
assert_eq "license без движка rc 4" "4" "$?"
cat > "$WARP_BIN" <<'EOF'
#!/bin/sh
if [ "$1" = "license" ]; then
    _k=$(cat)
    case "$_k" in
        GOOD*) echo "license ok"; exit 0 ;;
        WEIRD*) echo "bad format"; exit 2 ;;
        REJECT*) echo "license_rejected: test: no"; exit 3 ;;
        *) echo "net fail"; exit 1 ;;
    esac
fi
exit 0
EOF
chmod +x "$WARP_BIN"
printf 'GOOD-KEY-123' | warp_license > "$T/lic.out" 2>&1
assert_eq "license ok rc" "0" "$?"
assert_contains "license ok msg" "$T/lic.out" "license ok"
printf 'WEIRD??' | warp_license >/dev/null 2>&1
assert_eq "license bad rc 2" "2" "$?"
printf 'REJECT-X' | warp_license >/dev/null 2>&1
assert_eq "license reject rc 3" "3" "$?"
# Пользовательский прокси остаётся доступен как явный fallback.
cat > "$WARP_BIN" <<'EOF'
#!/bin/sh
case "$*" in
    *--proxy*) echo "via relay ok"; exit 0 ;;
    *) echo "net fail"; exit 1 ;;
esac
EOF
chmod +x "$WARP_BIN"
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_VPS_PROXY=http://proxy.example:8080\n' > "$T/etc/config"
printf 'GOOD-KEY-123' | warp_license > "$T/lic2.out" 2>&1
assert_eq "license relay retry rc" "0" "$?"
assert_contains "license relay msg" "$T/lic2.out" "via relay ok"

# Старый встроенный VPS адрес из установленного конфига не используется даже
# когда прямой запрос падает.
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_VPS_PROXY=http://z2kwarp:old@213.176.74.63:8119\n' > "$T/etc/config"
WARP_CALLS="$T/warpd-calls"; export WARP_CALLS
: > "$WARP_CALLS"
cat > "$WARP_BIN" <<'EOF'
#!/bin/sh
echo "$*" >> "$WARP_CALLS"
echo "net fail"
exit 1
EOF
chmod +x "$WARP_BIN"
printf 'GOOD-KEY-123' | warp_license > "$T/lic3.out" 2>&1
assert_eq "старый VPS proxy не используется повторно" "1" "$?"
assert_eq "лицензия отправлена только напрямую" "1" "$(wc -l < "$WARP_CALLS" | tr -d ' ')"
assert_not_contains "в запрос лицензии не добавлен старый proxy" "$WARP_CALLS" '--proxy'

# --- 3. supersession и lock выполняет Rust, Shell-функций больше нет. ---
export WARP_OP_FILE="$T/warp-op" WARP_LOCK_DIR="$T/warp-lock" \
    Z2K_WARP_LOCK_DIR="$T/warp-lock" WARP_LOCK_WAIT=2
rm -rf "$T/warp-lock" "$T/warp-op"
"$WARP_CONTROLLER_BIN" op-begin "$T/warp-op" "$$"
assert_eq "Rust op file == caller" "$$" "$(cat "$T/warp-op")"
assert_eq "Rust считает владельца current" current \
    "$("$WARP_CONTROLLER_BIN" op-current "$T/warp-op" "$$")"
printf '99999999\n' > "$T/warp-op"
assert_eq "Rust замечает supersession" superseded \
    "$("$WARP_CONTROLLER_BIN" op-current "$T/warp-op" "$$")"
rm -f "$T/warp-op"
assert_eq "отсутствующее намерение остаётся current" current \
    "$("$WARP_CONTROLLER_BIN" op-current "$T/warp-op" "$$")"
"$WARP_CONTROLLER_BIN" op-begin "$T/warp-op" "$$"
printf 'malformed\n' > "$T/warp-op"
assert_eq "повреждённое намерение не маскируется" unreadable \
    "$("$WARP_CONTROLLER_BIN" op-current "$T/warp-op" "$$")"
"$WARP_CONTROLLER_BIN" op-clear "$T/warp-op" "$$"

# Lock с умершим владельцем безопасно удаляется по проверке /proc identity.
mkdir -p "$T/warp-lock"
printf '4294967295 1\n' > "$T/warp-lock/owner"
printf '4294967295\n' > "$T/warp-lock/pid"
"$WARP_CONTROLLER_BIN" lock-acquire "$$" 2 >/dev/null && _t_ok || _t_bad "Rust не забрал lock после умершего владельца"
"$WARP_CONTROLLER_BIN" lock-release "$$" && _t_ok || _t_bad "Rust не снял lock своего владельца"

# --- 4. status несёт license/plan-поля ---
export WARP_DEVICE="$T/etc/state/warp/device.json"
: > "$WARP_DEVICE"
mkdir -p "$T/etc/state/warp"
printf '{"account_type":"plus","error":""}\n' > "$T/etc/state/warp/account.json"
printf 'KEYDATA' > "$T/etc/state/warp/license"
chmod 600 "$T/etc/state/warp/license" 2>/dev/null
_st="$(warp_status)"
case "$_st" in
    *' plan=plus '*|*' plan=plus'*) _t_ok ;;
    *) _t_bad "status без plan=plus: [$_st]" ;;
esac
case "$_st" in
    *' license=1'*) _t_ok ;;
    *) _t_bad "status без license=1: [$_st]" ;;
esac
case "$_st" in
    *'mem='*) _t_ok ;;
    *) _t_bad "status без mem=: [$_st]" ;;
esac
# Ключ НИКОГДА не в статусе.
case "$_st" in
    *'KEYDATA'*) _t_bad "ключ утёк в status!" ;;
    *) _t_ok ;;
esac

_t_done
