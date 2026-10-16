#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "ожидается положительный PID z2k-warpd" >&2
    exit 2
fi
case "$1" in
    ''|*[!0-9]*)
        echo "ожидается положительный PID z2k-warpd" >&2
        exit 2
        ;;
esac

_adapter="${Z2K_ADAPTER_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
Z2K_ADAPTER_DIR="$_adapter"
export Z2K_ADAPTER_DIR
. "$_adapter/paths.sh"
. "$_adapter/arch.sh"
. "$_adapter/env.sh"
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
. "$_adapter/warp.sh"

Z2K_WARP_PROTOCOL_VERSION=1
Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR"
export Z2K_WARP_PROTOCOL_VERSION Z2K_WARP_LOCK_DIR
exec "$WARP_CONTROLLER_BIN" ready-event "$1"
