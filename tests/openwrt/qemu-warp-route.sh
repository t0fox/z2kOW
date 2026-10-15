#!/bin/sh
# Проверяет Rust route controller против реального iproute2 в OpenWrt QEMU.
set -eu

BIN=/tmp/z2k-warp-controller
T=/tmp/z2k-warp-qemu-route
IFACE=z2ktun0
ADDR_CREATED=0
RENAMED=0
MASTER=""

restore_master() {
    [ -z "$MASTER" ] && return 0
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
    "$BIN" route-remove "$IFACE" 172.16.9.9 989 500 499 \
        0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner" \
        >/dev/null 2>&1 || true
    if [ "$ADDR_CREATED" = 1 ]; then
        ip addr del 172.16.9.9/32 dev "$IFACE" >/dev/null 2>&1 || true
    fi
    if [ "$RENAMED" = 1 ]; then
        ip link set "$IFACE" down >/dev/null 2>&1 || true
        ip link set "$IFACE" name eth0 >/dev/null 2>&1 || true
        ip link set eth0 up >/dev/null 2>&1 || true
        restore_master >/dev/null 2>&1 || true
    fi
    rm -rf "$T"
}
trap '_rc=$?; trap - EXIT; cleanup; exit "$_rc"' EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$T"
if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
    MASTER="$(ip -o link show dev eth0 | sed -n 's/.* master \([^ ]*\).*/\1/p')"
    ip link set eth0 down
    if ip link set eth0 name "$IFACE"; then
        RENAMED=1
    else
        ip link set eth0 up >/dev/null 2>&1 || true
        exit 1
    fi
    ip link set "$IFACE" up
fi
if ! ip -4 addr show dev "$IFACE" | grep -Fq '172.16.9.9/32'; then
    ip addr add 172.16.9.9/32 dev "$IFACE"
    ADDR_CREATED=1
fi

_apply=$("$BIN" route-reconcile "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_apply" = changed=1 ]
_verify=$("$BIN" route-verify "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_verify" = ready=1 ]
ip -4 rule show > "$T/rules.before"
ip -4 route show table 989 > "$T/routes.before"
_apply=$("$BIN" route-reconcile "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_apply" = changed=0 ]
ip -4 rule show > "$T/rules.after"
ip -4 route show table 989 > "$T/routes.after"
cmp "$T/rules.before" "$T/rules.after"
cmp "$T/routes.before" "$T/routes.after"
grep -F 'from 172.16.9.9 lookup 989' "$T/rules.after"
grep -F 'fwmark 0x80000000/0x80000000 lookup 989' "$T/rules.after"
grep -F "default dev $IFACE" "$T/routes.after"

# A crash between publishing the PBR owner and the probe owner must recover
# the missing owner file without rewriting an already correct route state.
rm "$T/probe.owner"
ip -4 rule show > "$T/rules.owner-repair.before"
ip -4 route show table 989 > "$T/routes.owner-repair.before"
_apply=$("$BIN" route-reconcile "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_apply" = changed=1 ]
[ -s "$T/probe.owner" ]
_verify=$("$BIN" route-verify "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_verify" = ready=1 ]
ip -4 rule show > "$T/rules.owner-repair.after"
ip -4 route show table 989 > "$T/routes.owner-repair.after"
cmp "$T/rules.owner-repair.before" "$T/rules.owner-repair.after"
cmp "$T/routes.owner-repair.before" "$T/routes.owner-repair.after"

cp "$T/probe.owner" "$T/probe.owner.saved"
printf 'iface=z2ktun1\naddr=172.16.9.10\n' > "$T/probe.owner"
cp "$T/probe.owner" "$T/probe.owner.foreign"
ip -4 rule show > "$T/rules.probe-conflict.before"
ip -4 route show table 989 > "$T/routes.probe-conflict.before"
if "$BIN" route-reconcile "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner"; then
    echo 'route-reconcile перезаписал чужую запись владельца probe' >&2
    exit 1
fi
cmp "$T/probe.owner.foreign" "$T/probe.owner"
mv "$T/probe.owner.saved" "$T/probe.owner"
ip -4 rule show > "$T/rules.probe-conflict.after"
ip -4 route show table 989 > "$T/routes.probe-conflict.after"
cmp "$T/rules.probe-conflict.before" "$T/rules.probe-conflict.after"
cmp "$T/routes.probe-conflict.before" "$T/routes.probe-conflict.after"

cp "$T/pbr.owner" "$T/pbr.owner.saved"
printf 'foreign-owner\n' > "$T/pbr.owner"
if "$BIN" route-apply "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner" 1; then
    echo 'чужая запись владельца маршрута принята' >&2
    exit 1
fi
mv "$T/pbr.owner.saved" "$T/pbr.owner"
ip -4 rule show > "$T/rules.after-conflict"
ip -4 route show table 989 > "$T/routes.after-conflict"
cmp "$T/rules.after" "$T/rules.after-conflict"
cmp "$T/routes.after" "$T/routes.after-conflict"

"$BIN" route-remove-owned '' '' 989 500 499 0x80000000 0x80000000 \
    "$T/pbr.owner" "$T/probe.owner"
_verify=$("$BIN" route-verify "$IFACE" 172.16.9.9 989 500 499 \
    0x80000000 0x80000000 "$T/pbr.owner" "$T/probe.owner")
[ "$_verify" = ready=0 ]
if ip -4 rule show | grep -E 'lookup 989'; then
    echo 'правило осталось после route-remove' >&2
    exit 1
fi
[ -z "$(ip -4 route show table 989)" ]
if [ "$RENAMED" = 1 ]; then
    if [ "$ADDR_CREATED" = 1 ]; then
        ip addr del 172.16.9.9/32 dev "$IFACE"
        ADDR_CREATED=0
    fi
    ip link set "$IFACE" down
    ip link set "$IFACE" name eth0
    ip link set eth0 up
    restore_master
    RENAMED=0
    if [ -n "$MASTER" ]; then
        _attempt=0
        # Виртуальный e1000 сообщает carrier после поднятия bridge-port.
        while [ "$_attempt" -lt 5 ]; do
            if ip -o link show dev eth0 | grep -qF LOWER_UP; then
                break
            fi
            sleep 1
            _attempt=$((_attempt + 1))
        done
        ip -o link show dev eth0 | grep -qF LOWER_UP
        ip neigh flush dev "$MASTER"
        ip -o link show dev eth0 | grep -q "master $MASTER"
    fi
fi
printf 'SUITE[ow-warp-controller-openwrt-qemu-routes]: pass\n'
