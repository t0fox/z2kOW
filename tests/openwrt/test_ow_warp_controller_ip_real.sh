#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
if [ "${1:-}" = --inside ]; then
    T="$2" CRATE="$3"
    ip link add z2ktun0 type dummy
    ip link set z2ktun0 up
    trap 'ip link del z2ktun0 2>/dev/null || true' EXIT HUP INT TERM
    Z2K_WARP_REAL_IPROUTE2=1 Z2K_WARP_REAL_STATE="$T/state" cargo test --offline \
        --manifest-path "$CRATE/Cargo.toml" --test real_routes -- --nocapture
    exit 0
fi
for tool in cargo unshare ip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "требуется реальный инструмент $tool" >&2; exit 1; }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-controller-ip.XXXXXX")"
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/state"
cargo test --manifest-path "$CRATE/Cargo.toml" --test real_routes --no-run
unshare -Urn "$0" --inside "$T" "$CRATE"
