#!/bin/sh
# Stable public CLI entrypoint installed by z2k-adapter.
set -eu
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
. "$Z2K_ROOT/platform/openwrt/paths.sh"
ENGINE="$Z2K_ROOT/platform/openwrt/product-update.sh"
[ -r "$ENGINE" ] || { echo "z2kow: product updater is missing" >&2; exit 1; }
_command="${1:-status}"
case "$_command" in
    update|u) shift 2>/dev/null || true; exec sh "$ENGINE" update "$@" ;;
    install|i) shift 2>/dev/null || true; exec sh "$ENGINE" install "$@" ;;
    status|s) shift 2>/dev/null || true; exec sh "$ENGINE" status "$@" ;;
    check) shift; exec sh "$ENGINE" check "$@" ;;
    info) shift; exec sh "$ENGINE" info "$@" ;;
    version|v) shift 2>/dev/null || true; exec sh "$ENGINE" version "$@" ;;
    diag|d) shift 2>/dev/null || true; exec sh "$ENGINE" diag "$@" ;;
    uninstall|remove) shift; exec sh "$ENGINE" uninstall "$@" ;;
    record) shift; exec sh "$ENGINE" record "$@" ;;
    help|-h|--help) exec sh "$ENGINE" help ;;
    *)
        echo "z2kow: unknown command: $1" >&2
        exec sh "$ENGINE" help
        ;;
esac
