#!/bin/sh
# tests/openwrt/test_ow_warp_parity.sh - p-84.18 parity на OW-адаптере.
# Upstream semantics -> platform/openwrt/warp.sh (НЕ копия files/z2k-warp.sh):
# transport auto/wg/h2, restart/license глаголы, .disabled списков,
# supersession последнего действия, status-поля license/plan.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-parity"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-wpar.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/etc" "$T/tmp" "$T/tmp/warp" "$T/proc" "$T/root/bin"
export PATH="$T/bin:/usr/bin:/bin"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft:$*" >> "$CALLS"
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
    case "$*" in *' pref 499 '*) rm -f "$HAVE_PROBE" ;; esac
    exit 0
fi
if [ "$1" = "route" ] && [ "$2" = "show" ]; then
    case "$*" in
        *'table 989'*) echo "default dev z2ktun0" ;;
    esac
    exit 0
fi
if [ "$1" = "link" ]; then exit 0; fi
exit 0
EOF
chmod +x "$T/bin/ip"
export HAVE_PBR="$T/have-pbr"
export HAVE_PROBE="$T/have-probe"
cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
cat "$PIDOF_OUT" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/pidof"
: > "$T/pidof.out"
export CALLS="$T/calls" PIDOF_OUT="$T/pidof.out"
: > "$T/calls"

export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp" Z2K_STATE="$T/etc/state"
export Z2K_BIN="$T/root/bin" Z2K_LISTS_DIR="$T/root/lists"
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
assert_contains "instance env carries relay" "$T/calls" "Z2K_WARP_VPS_PROXY=http://"

# --- 2. restart: disabled = noop; enabled = pbr-down, bounce, wait ---
printf 'GAME_WARP_ENABLED=0\n' > "$T/etc/config"
warp_restart >/dev/null 2>&1
assert_eq "restart disabled rc" "0" "$?"
# enabled-путь: ставим флаг, живой демон, ready-статус.
printf 'GAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=auto\n' > "$T/etc/config"
mkdir -p "$T/proc/4242"
printf 'z2k-warpd run' | tr ' ' '\0' > "$T/proc/4242/cmdline"
printf '4242\n' > "$T/pidof.out"
export Z2K_PROC_ROOT="$T/proc"
printf '{"ready":true,"transport":"auto","iface":"z2ktun0","addr":"172.16.9.9"}\n' > "$T/tmp/warp-status.json"
export WARP_STATUS="$T/tmp/warp-status.json"
_z2k_ow_warp_kill() { echo "kill:$*" >> "$T/calls"; return 0; }
: > "$T/calls"
: > "$T/have-pbr"
warp_restart >/dev/null 2>&1
assert_eq "restart enabled rc" "0" "$?"
# PBR down раньше kill (fail open: сначала снять маршрут).
_pb="$(grep -n 'ip:rule del\|ip:route del' "$T/calls" | head -1 | cut -d: -f1)"
_kill="$(grep -n '^kill:' "$T/calls" | head -1 | cut -d: -f1)"
if [ -n "$_pb" ] && [ -n "$_kill" ] && [ "$_pb" -lt "$_kill" ]; then _t_ok
else _t_bad "restart: PBR down не первым (pbr=$_pb kill=$_kill)"; fi

# Активный procd должен пересобрать instance, иначе respawn сохранит старый
# transport env. Сервисный рестарт здесь stubbed, но порядок и повторный
# захват feature-lock остаются реальными.
WARP_READY_WAIT=4
_z2k_ow_service_running() { return 0; }
_z2k_ow_warp_service_restart() { touch "$WARP_STATUS"; echo "service-restart" >> "$T/calls"; return 0; }
: > "$T/calls"
warp_restart >/dev/null 2>&1
assert_eq "restart active service rc" "0" "$?"
assert_contains "restart rebuilds procd instance" "$T/calls" "service-restart"

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
# proxy-retry: rc 1 без прокси, успех с прокси.
cat > "$WARP_BIN" <<'EOF'
#!/bin/sh
case "$*" in
    *--proxy*) echo "via relay ok"; exit 0 ;;
    *) echo "net fail"; exit 1 ;;
esac
EOF
chmod +x "$WARP_BIN"
export WARP_VPS_PROXY="http://relay.invalid/"
printf 'GOOD-KEY-123' | warp_license > "$T/lic2.out" 2>&1
assert_eq "license relay retry rc" "0" "$?"
assert_contains "license relay msg" "$T/lic2.out" "via relay ok"

# --- 4. lists: .disabled respected ---
mkdir -p "$T/etc/user-lists/warp"
export WARP_LISTS_DIR="$T/etc/user-lists/warp" WARP_GAMES_DIR="$T/root/lists/warp/games"
export WARP_DEVICES_FILE="$T/etc/user-lists/warp/devices.txt"
printf '1.2.3.0/24\n' > "$T/etc/user-lists/warp/mygame.txt"
printf '5.6.7.0/24\n' > "$T/etc/user-lists/warp/other.txt"
if warp_active_lists | grep -q mygame.txt; then _t_ok
else _t_bad "active без disabled потерял mygame"; fi
printf 'mygame\n' > "$T/etc/user-lists/warp/.disabled"
if warp_active_lists | grep -q mygame.txt; then
    _t_bad "disabled mygame всё ещё active"
else
    _t_ok
fi
if warp_active_lists | grep -q other.txt; then _t_ok
else _t_bad "disabled задел соседа other"; fi
rm -f "$T/etc/user-lists/warp/.disabled"

# --- 5. supersession: op-file + current + preemption ---
export WARP_OP_FILE="$T/warp-op" WARP_LOCK_DIR="$T/warp-lock" WARP_LOCK_WAIT=2
rm -rf "$T/warp-lock" "$T/warp-op"
warp_op_begin
assert_eq "op file == self" "$$" "$(cat "$T/warp-op")"
warp_op_current && _t_ok || _t_bad "self не current"
printf '99999999\n' > "$T/warp-op"
warp_op_current && _t_bad "чужой pid current" || _t_ok
rm -f "$T/warp-op"
warp_op_current && _t_ok || _t_bad "без op-file не current (lifecycle сломан)"
# wait прерывается чужим действием с кодом 3.
printf '{"ready":false}\n' > "$T/tmp/warp-status.json"
printf '4242\n' > "$T/pidof.out"
warp_op_begin
( printf '123456\n' > "$T/warp-op"; sleep 3 ) &
export WARP_READY_WAIT=8
if _warp_wait_ready 8 >/dev/null 2>&1; then
    _t_bad "superseded wait прошёл"
else
    [ "$?" = "3" ] && _t_ok || _t_bad "superseded wait код не 3"
fi
wait 2>/dev/null
rm -f "$T/warp-op"
# lock preemption: живой чужой holder + мы current + stale -> забираем.
# (stale по смерти holder'а; живой holder без current -> fail как раньше.)
mkdir -p "$T/warp-lock"
(false &) ; _dead=$!; wait "$_dead" 2>/dev/null
printf '%s' "$_dead" > "$T/warp-lock/pid"
warp_op_begin
_z2k_ow_warp_lock 2 >/dev/null && _t_ok || _t_bad "stale lock не взят текущим"
_z2k_ow_warp_unlock

# --- 6. status несёт license/plan-поля ---
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
