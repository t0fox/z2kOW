#!/bin/sh
# fw4 теперь меняет только Rust-контроллер; проверяем его на настоящем nft.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec sh "$ROOT/tests/openwrt/test_ow_warp_controller_nft_real.sh"
