#!/bin/sh
# Измеряет shell fallback и Rust nft-sync на одинаковом реальном nft-состоянии.
set -eu

BIN=/tmp/z2k-warp-controller
T=/tmp/z2k-warp-qemu-benchmark
FAMILY=inet
TABLE=z2k_warp_bench
ITERATIONS=30

cleanup() {
    nft delete table "$FAMILY" "$TABLE" >/dev/null 2>&1 || true
    rm -rf "$T"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$T/users" "$T/games"
printf '1.2.3.4\n' > "$T/users/public.txt"
printf '192.168.1.9\n' > "$T/users/devices.txt"
: > "$T/users/.enabled"
nft add table "$FAMILY" "$TABLE"
"$BIN" nft-sync "$T/users" "$T/games" "$T/users/.enabled" \
    "$T/users/devices.txt" "$FAMILY" "$TABLE" z2k_dst z2k_src

export Z2K_ADAPTER_DIR=/tmp/z2k-warp
export Z2K_ROOT=/tmp/z2k-warp
export Z2K_ETC="$T/etc" Z2K_STATE="$T/state" Z2K_TMP="$T/tmp"
export Z2K_LISTS_DIR="$T/games"
export WARP_LISTS_DIR="$T/users" WARP_GAMES_DIR="$T/games"
export WARP_ENABLED_FILE="$T/users/.enabled"
export WARP_DEVICES_FILE="$T/users/devices.txt"
export WARP_SET=z2k_dst WARP_SET_SRC=z2k_src
export Z2K_WARP_NFT_FAMILY="$FAMILY" Z2K_WARP_NFT_TABLE="$TABLE"
export WARP_DOMAIN_HELPER=/tmp/z2k-warp/warp-domain.sh
export WARP_DOMAIN_FILTER=/tmp/z2k-warp/z2k-warp-list-filter.awk
export WARP_DOMAIN_RUNTIME_BIN=/tmp/missing-z2k-warpd
export WARP_LOCK_DIR="$T/mutate.lock"
export Z2K_WARP_QUIET=1
export Z2K_WARP_SOURCE_ONLY=1

if ! WARP_CONTROLLER_BIN=/tmp/missing-warp-controller \
    /usr/bin/time -v sh -c '
        . /tmp/warp.sh
        i=0
        while [ "$i" -lt 30 ]; do
            warp_nft_sets_load >/dev/null || exit 1
            i=$((i + 1))
        done
    ' 2> "$T/shell.time"; then
    cat "$T/shell.time" >&2
    exit 1
fi

if ! WARP_CONTROLLER_BIN="$BIN" \
    /usr/bin/time -v sh -c '
        . /tmp/warp.sh
        i=0
        while [ "$i" -lt 30 ]; do
            warp_nft_sets_load >/dev/null || exit 1
            i=$((i + 1))
        done
    ' 2> "$T/rust.time"; then
    cat "$T/rust.time" >&2
    exit 1
fi

printf 'МЕТОД: 30 повторных вызовов warp_nft_sets_load; реальные nft и OpenWrt userspace\n'
printf 'Shell fallback:\n'
cat "$T/shell.time"
printf 'Rust controller path:\n'
cat "$T/rust.time"
printf 'Размер бинарника, байт: '
wc -c < "$BIN"
printf 'Размер Shell entrypoints, байт: '
wc -c /tmp/warp.sh /tmp/z2k-warp/warp-domain.sh \
    /tmp/z2k-warp/z2k-warp-list-filter.awk | tail -n 1 | awk '{print $1}'
printf 'SUITE[ow-warp-controller-openwrt-qemu-benchmark]: pass\n'
