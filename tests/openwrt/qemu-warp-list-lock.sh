#!/bin/sh
# Проверка сериализации cron-обновления списка и Shell WARP в OpenWrt QEMU.
set -eu

ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
UPDATER="${1:-$ROOT/z2k-update-lists.sh}"
BIN="${WARP_CONTROLLER_BIN:-$ROOT/platform/openwrt/bin/linux-x86_64/z2k-warp-controller}"
WARP="$ROOT/platform/openwrt/warp.sh"
RELEASE="$ROOT/platform/openwrt/release.sh"
T="$(mktemp -d /tmp/z2k-warp-list-lock.XXXXXX)"
trap 'rm -rf "$T"' EXIT HUP INT TERM

[ -r "$UPDATER" ] && [ -r "$WARP" ] && [ -r "$RELEASE" ] && [ -x "$BIN" ] \
    || { echo 'WARP updater, adapter или Rust-контроллер недоступен' >&2; exit 1; }

export Z2K_ROOT="$ROOT" Z2K_ADAPTER_DIR="$ROOT/platform/openwrt"
export ZAPRET2_DIR="$T/lists" CONFIG_FILE="$T/config" LOG_FILE="$T/update.log"
export Z2K_LISTS_DIR="$T/lists/lists"
export Z2K_TMP="$T/tmp" Z2K_OW_INSTALL_WORK="$T/install-work"
export WARP_LOCK_DIR="$T/mutate.lock" WARP_CONTROLLER_BIN="$BIN"
export WARP_INIT="$T/missing-init"
export Z2K_WARP_IPSET_SCRIPT="$WARP"
export Z2K_WARP_NFT_TABLE=z2k_warp_list_lock_test
mkdir -p "$ZAPRET2_DIR/lists/warp/games"
cp "$ROOT/z2k-warp-list-filter.awk" "$ZAPRET2_DIR/z2k-warp-list-filter.awk"
printf 'GAME_WARP_ENABLED=0\n' > "$CONFIG_FILE"
printf '{"game_map":{"LockProbe":["hint"]}}\n' > "$T/index.json"

Z2K_UL_SOURCE_ONLY=1
. "$UPDATER"
unset Z2K_UL_SOURCE_ONLY

z2k_fetch() { : > "$T/index-fetched"; cp "$T/index.json" "$2"; }
update_list() {
    local _probe
    sleep 30 &
    _probe=$!
    [ "$(cat "$WARP_LOCK_DIR/pid")" = "$$" ] || {
        kill "$_probe" 2>/dev/null || true
        wait "$_probe" 2>/dev/null || true
        return 1
    }
    if Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$BIN" lock-acquire "$_probe" 0 >/dev/null 2>&1; then
        Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$BIN" lock-release "$_probe" >/dev/null 2>&1 || true
        kill "$_probe" 2>/dev/null || true
        wait "$_probe" 2>/dev/null || true
        return 1
    fi
    kill "$_probe" 2>/dev/null || true
    wait "$_probe" 2>/dev/null || true
    : > "$T/update-started"
    sleep 5
    printf '8.8.8.8\n' > "$3"
    return 2
}

update_warp_game_list &
_updater_pid=$!
_waited=0
while [ ! -e "$T/update-started" ] && [ "$_waited" -lt 20 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
[ -e "$T/update-started" ] || { kill "$_updater_pid" 2>/dev/null || true; exit 1; }

Z2K_WARP_SOURCE_ONLY=1
. "$WARP"
unset Z2K_WARP_SOURCE_ONLY
_action_started="$(date +%s)"
# $$ у subshell остаётся PID родителя; проверяем конкуренцию отдельной sh.
sh -c 'Z2K_WARP_SOURCE_ONLY=1; . "$Z2K_ADAPTER_DIR/warp.sh"; unset Z2K_WARP_SOURCE_ONLY; z2k_ow_warp cleanup'
_action_finished="$(date +%s)"
[ "$((_action_finished - _action_started))" -ge 2 ] || {
    echo 'WARP cleanup не дождался окончания обновления игровых списков' >&2
    exit 1
}
wait "$_updater_pid"
[ ! -e "$WARP_LOCK_DIR" ]
grep -qx '8.8.8.8' "$ZAPRET2_DIR/lists/warp/games/LockProbe.txt"
rm -f "$T/index-fetched"
mkdir -p "$Z2K_OW_INSTALL_WORK"
: > "$Z2K_OW_INSTALL_WORK/transaction-active"
if update_warp_game_list; then
    echo 'cron-обновление продолжилось во время транзакции релиза' >&2
    exit 1
fi
[ ! -e "$T/index-fetched" ]
[ ! -e "$WARP_LOCK_DIR" ]
Z2K_OW_RELEASE_WARP_LOCK_HELD=0
. "$RELEASE"
z2k_ow_release_warp_lock_acquire "$Z2K_ADAPTER_DIR"
[ "$(cat "$WARP_LOCK_DIR/pid")" = "$$" ]
z2k_ow_release_warp_lock_release
[ ! -e "$WARP_LOCK_DIR" ]
if warp_disable > "$T/manual-disable.log" 2>&1; then
    echo 'ручной disable не отложен во время транзакции релиза' >&2
    exit 1
fi
grep -Fq 'идёт обновление z2kOW; действие WARP отложено' "$T/manual-disable.log"
[ ! -e "$WARP_LOCK_DIR" ]
grep -qx GAME_WARP_ENABLED=0 "$CONFIG_FILE"
printf 'SUITE[ow-warp-list-lock-openwrt-qemu]: pass\n'
