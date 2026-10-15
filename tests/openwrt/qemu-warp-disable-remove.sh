#!/bin/sh
# Проверяет teardown WARP через настоящий OpenWrt userspace в QEMU.
set -eu

BIN=/usr/bin/z2k-warp-controller
WARP=/tmp/warp.sh
HELPER=/tmp/z2k-warp/warp-domain.sh
T=/tmp/z2k-warp-disable-remove
IFACE=z2ktun0
ADDR=172.16.9.9
NFT_FAMILY=inet
NFT_TABLE=z2k_warp_lifecycle
NFT_BIN="$(command -v nft)"
MASTER=""
RENAMED=0
ADDR_CREATED=0
NFT_TABLE_CREATED=0
FW4_RULE_CREATED=0
NFT_EXEC_DISABLED=0

# iproute2 возвращает status 2, когда таблица ещё не создана. Это пустое
# состояние; ошибки чтения или вывода должны оставаться ошибками теста.
ip_routes_989() {
    local _routes _status
    if _routes=$(ip -4 route show table 989 2>&1); then
        [ -n "$_routes" ] && printf '%s\n' "$_routes"
        return 0
    else
        _status=$?
    fi
    if [ "$_status" -eq 2 ] && [ "$_routes" = 'Error: ipv4: FIB table does not exist.' ]; then
        return 0
    fi
    printf '%s\n' "$_routes" >&2
    return "$_status"
}

restore_master() {
    [ -n "$MASTER" ] || return 0
    _attempt=0
    while ! ip link show dev "$MASTER" >/dev/null 2>&1 && [ "$_attempt" -lt 10 ]; do
        sleep 1
        _attempt=$((_attempt + 1))
    done
    ip link show dev "$MASTER" >/dev/null 2>&1 || return 1
    _current_master="$(ip -o link show dev eth0 | sed -n 's/.* master \([^ ]*\).*/\1/p')" || return 1
    [ "$_current_master" = "$MASTER" ] || ip link set eth0 master "$MASTER"
}

cleanup() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "$NFT_EXEC_DISABLED" = 1 ]; then
        chmod 755 "$NFT_BIN" >/dev/null 2>&1 || _rc=1
        NFT_EXEC_DISABLED=0
    fi
    "$BIN" route-remove-owned "$IFACE" "$ADDR" 989 500 499 \
        0x80000000 0x80000000 "$T/tmp/warp/pbr.owner" \
        "$T/tmp/warp/probe-route.owner" >/dev/null 2>&1 || _rc=1
    if [ "$FW4_RULE_CREATED" = 1 ]; then
        "$BIN" nft-fw4-forward-remove inet fw4 forward "!z2k: WARP forwarded traffic" \
            >/dev/null 2>&1 || _rc=1
    fi
    if [ "$NFT_TABLE_CREATED" = 1 ]; then
        nft delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    if [ "$ADDR_CREATED" = 1 ]; then
        ip addr del "$ADDR/32" dev "$IFACE" >/dev/null 2>&1 || _rc=1
    fi
    if [ "$RENAMED" = 1 ]; then
        ip link set "$IFACE" down >/dev/null 2>&1 || _rc=1
        ip link set "$IFACE" name eth0 >/dev/null 2>&1 || _rc=1
        ip link set eth0 up >/dev/null 2>&1 || _rc=1
        restore_master >/dev/null 2>&1 || _rc=1
        RENAMED=0
    fi
    rm -rf "$T"
    exit "$_rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ -x "$BIN" ] && [ -r "$WARP" ] && [ -r "$HELPER" ]
[ ! -e "$IFACE" ] || { echo 'z2ktun0 уже занят в QEMU' >&2; exit 1; }
[ -z "$(ip_routes_989)" ] || {
    echo 'таблица 989 занята до начала QEMU teardown-теста' >&2; exit 1;
}
! ip -4 rule show | grep -Eq '^(499|500):' || {
    echo 'приоритет WARP занят до начала QEMU teardown-теста' >&2; exit 1;
}
! nft list chain inet fw4 forward | grep -F '!z2k: WARP forwarded traffic' || {
    echo 'правило WARP уже существует в fw4 до начала QEMU teardown-теста' >&2; exit 1;
}
[ -z "$(nft list tables | grep -F "table $NFT_FAMILY $NFT_TABLE" || true)" ] || {
    echo 'таблица WARP teardown-теста уже существует в QEMU' >&2; exit 1;
}
[ -z "$(ubus -S call service list 2>/dev/null | grep '"z2k":{' || true)" ] || {
    echo 'тест требует гостя без установленной службы z2k' >&2
    exit 1
}

mkdir -p "$T/etc/user-lists/warp/games" "$T/etc/state/warp" "$T/tmp/warp" \
    "$T/lists/warp/games" "/tmp/z2k-warp"
printf 'GAME_WARP_ENABLED=1\nENABLED=1\n' > "$T/etc/config"
printf 'device sentinel\n' > "$T/etc/state/warp/device.json"
printf 'license sentinel\n' > "$T/etc/state/warp/license"
printf '192.168.1.8\n' > "$T/etc/user-lists/warp/custom.txt"
touch "$T/etc/user-lists/warp/.legacy-aggregate-purged"

export Z2K_ROOT=/usr/lib/z2k
export Z2K_ADAPTER_DIR=/usr/lib/z2k/platform/openwrt
export Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp"
export Z2K_LISTS_DIR="$T/lists" CONFIG_FILE="$T/etc/config"
export WARP_LISTS_DIR="$T/etc/user-lists/warp"
export WARP_GAMES_DIR="$T/etc/user-lists/warp/games"
export WARP_ENABLED_FILE="$T/etc/user-lists/warp/.enabled"
export WARP_DEVICE="$T/etc/state/warp/device.json"
export WARP_CONTROLLER_BIN="$BIN" WARP_DOMAIN_RUNTIME_BIN="$T/z2k-warpd"
export WARP_DOMAIN_HELPER="$HELPER" WARP_DOMAIN_FILTER=/tmp/z2k-warp/z2k-warp-list-filter.awk
export WARP_LOCK_DIR="$T/tmp/warp/mutate.lock" Z2K_WARP_LOCK_DIR="$T/tmp/warp/mutate.lock"
export Z2K_INIT="$T/missing-init" Z2K_WARP_NFT_FAMILY="$NFT_FAMILY"
export Z2K_WARP_NFT_TABLE="$NFT_TABLE" WARP_FW4_FAMILY=inet WARP_FW4_TABLE=fw4
export WARP_FW4_CHAIN=forward WARP_FW4_RULE_COMMENT='!z2k: WARP forwarded traffic'
export WARP_ROUTE_ERROR_FILE="$T/tmp/warp/route-error"
export WARP_DOMAIN_NFT_FAMILY=inet WARP_DOMAIN_NFT_TABLE=z2k_warp_lifecycle_dns
export WARP_DOMAIN_SET=z2k_warp_domain4 WARP_DOMAIN_ERROR="$T/tmp/warp/domain-error"

MASTER="$(ip -o link show dev eth0 | sed -n 's/.* master \([^ ]*\).*/\1/p')"
ip link set eth0 down
ip link set eth0 name "$IFACE"
RENAMED=1
ip link set "$IFACE" up
ip addr add "$ADDR/32" dev "$IFACE"
ADDR_CREATED=1

ip link show dev "$IFACE" >/dev/null
ip addr show dev "$IFACE" | grep -F "$ADDR/32" >/dev/null
ip -4 rule show > "$T/rules.initial"
ip_routes_989 > "$T/routes.initial"
"$BIN" route-reconcile "$IFACE" "$ADDR" 989 500 499 0x80000000 0x80000000 \
    "$T/tmp/warp/pbr.owner" "$T/tmp/warp/probe-route.owner" | grep -qx 'changed=1'
"$BIN" route-verify "$IFACE" "$ADDR" 989 500 499 0x80000000 0x80000000 \
    "$T/tmp/warp/pbr.owner" "$T/tmp/warp/probe-route.owner" | grep -qx 'ready=1'

nft add table "$NFT_FAMILY" "$NFT_TABLE"
NFT_TABLE_CREATED=1
"$BIN" nft-tun-apply "$NFT_FAMILY" "$NFT_TABLE" \
    z2k_warp_mss z2k_warp_fwd z2k_warp_nat "$IFACE"
nft add chain "$NFT_FAMILY" "$NFT_TABLE" z2k_warp_mark
nft add rule "$NFT_FAMILY" "$NFT_TABLE" z2k_warp_mark counter
nft add set "$NFT_FAMILY" "$NFT_TABLE" z2k_warp_dst4 '{ type ipv4_addr; }'
nft add set "$NFT_FAMILY" "$NFT_TABLE" z2k_warp_src4 '{ type ipv4_addr; }'
"$BIN" nft-fw4-forward-apply inet fw4 forward "$IFACE" \
    0x80000000 0x80000000 '!z2k: WARP forwarded traffic'
FW4_RULE_CREATED=1
nft list chain inet fw4 forward | grep -F '!z2k: WARP forwarded traffic' >/dev/null

# Ошибка владения маршрутом не должна фиксировать выключенное состояние и
# удалять остальную настройку. После восстановления записи очистка повторяется.
cp "$T/tmp/warp/pbr.owner" "$T/tmp/warp/pbr.owner.saved"
printf 'foreign-owner\n' > "$T/tmp/warp/pbr.owner"
if sh "$WARP" disable > "$T/disable-route-error.log" 2>&1; then
    echo 'disable принял чужую запись владельца маршрута' >&2
    exit 1
fi
grep -qx GAME_WARP_ENABLED=1 "$T/etc/config"
grep -q '^warp-disable-pbr-remove-failed ' "$T/tmp/warp/route-error"
ip -4 rule show | grep -q 'lookup 989'
[ -n "$(ip_routes_989)" ]
nft list chain inet fw4 forward | grep -F '!z2k: WARP forwarded traffic' >/dev/null
mv "$T/tmp/warp/pbr.owner.saved" "$T/tmp/warp/pbr.owner"

# Недоступный nft оставляет флаг включённым даже после снятия PBR: следующий
# запуск повторяет очистку, не возвращая маршрутизацию.
chmod 000 "$NFT_BIN"
NFT_EXEC_DISABLED=1
if sh "$WARP" disable > "$T/disable-nft-error.log" 2>&1; then
    echo 'disable скрыл ошибку выполнения nft' >&2
    exit 1
fi
chmod 755 "$NFT_BIN"
NFT_EXEC_DISABLED=0
grep -qx GAME_WARP_ENABLED=1 "$T/etc/config"
grep -q '^warp-disable-' "$T/tmp/warp/route-error"
! ip -4 rule show | grep -q 'lookup 989'
[ -z "$(ip_routes_989)" ]

# Rust формирует disable-state и передаёт конфигурацию дочерней команде через stdin.
sh "$WARP" disable
[ "$(grep '^GAME_WARP_ENABLED=' "$CONFIG_FILE" | cut -d= -f2)" = 0 ]
"$BIN" route-verify "$IFACE" "$ADDR" 989 500 499 0x80000000 0x80000000 \
    "$T/tmp/warp/pbr.owner" "$T/tmp/warp/probe-route.owner" | grep -qx 'ready=0'
ip -4 rule show | grep -E 'lookup 989' && { echo 'PBR правило осталось после disable' >&2; exit 1; }
[ -z "$(ip_routes_989)" ]
! nft list chain inet fw4 forward | grep -F '!z2k: WARP forwarded traffic'
! nft list chain "$NFT_FAMILY" "$NFT_TABLE" z2k_warp_mark | grep -q counter

sh "$WARP" remove
if nft list table "$NFT_FAMILY" "$NFT_TABLE" | \
    grep -Eq '^[[:space:]]+(chain|set) z2k_warp_(mark|mss|fwd|nat|dst4|src4)'; then
    echo 'полный remove оставил nft-объекты WARP' >&2
    exit 1
fi
grep -qx 'device sentinel' "$T/etc/state/warp/device.json"
grep -qx 'license sentinel' "$T/etc/state/warp/license"
grep -qx '192.168.1.8' "$T/etc/user-lists/warp/custom.txt"
[ "$(grep '^GAME_WARP_ENABLED=' "$CONFIG_FILE" | cut -d= -f2)" = 0 ]
printf 'SUITE[ow-warp-disable-remove-openwrt-qemu]: pass\n'
