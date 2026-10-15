#!/bin/sh
# Rust — единственный владелец состояния WARP; запускаем его unit/CLI-набор.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
cargo test --offline --manifest-path "$CRATE/Cargo.toml"
printf 'SUITE[ow-warp-functional]: pass=1 fail=0\n'
