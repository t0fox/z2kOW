#!/bin/sh
# Конечная машина procd-жизненного цикла проверяется в Rust.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
cargo test --offline --manifest-path "$CRATE/Cargo.toml" lifecycle
printf 'SUITE[ow-warp-lifecycle]: pass=1 fail=0\n'
