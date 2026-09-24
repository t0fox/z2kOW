#!/bin/sh
# The OpenWrt shell producer/API must use z2k-warpd's real observer paths.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-warp-domain-paths"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DOMAIN="$REPO/platform/openwrt/warp-domain.sh"
DAEMON="$REPO/z2k-warpd/cmd/z2k-warpd/main.go"

unset WARP_DOMAIN_RULES WARP_DOMAIN_SNAPSHOT WARP_DOMAIN_STATUS WARP_DOMAIN_ERROR
. "$DOMAIN" || { _t_bad "source OpenWrt WARP domain adapter"; exit 1; }
assert_eq "rules use daemon tmpfs contract" "/tmp/z2k-warp/domains.v1" "$WARP_DOMAIN_RULES"
assert_eq "snapshot uses daemon tmpfs contract" "/tmp/z2k-warp/domain-pairs.v1" "$WARP_DOMAIN_SNAPSHOT"
assert_eq "health status uses daemon tmpfs contract" "/tmp/z2k-warp/domain-status.json" "$WARP_DOMAIN_STATUS"
assert_eq "setup error uses same tmpfs directory" "/tmp/z2k-warp/domain-setup-error" "$WARP_DOMAIN_ERROR"

# Cross-component contract: these are the paths the running observer actually
# opens and writes; a shell-only path refactor must not drift from them.
assert_contains "daemon reads the shared domain rules path" "$DAEMON" \
    'DomainPath: "/tmp/z2k-warp/domains.v1"'
assert_contains "daemon writes the shared pair snapshot" "$DAEMON" \
    'SnapshotPath: "/tmp/z2k-warp/domain-pairs.v1"'
assert_contains "daemon writes the shared health status" "$DAEMON" \
    'StatusPath: "/tmp/z2k-warp/domain-status.json"'

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-warp-paths.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
WARP_DOMAIN_RULES="$T/domains.v1"
WARP_DOMAIN_SNAPSHOT="$T/domain-pairs.v1"
WARP_DOMAIN_STATUS="$T/domain-status.json"
WARP_DOMAIN_ERROR="$T/domain-setup-error"
export WARP_DOMAIN_RULES WARP_DOMAIN_SNAPSHOT WARP_DOMAIN_STATUS WARP_DOMAIN_ERROR
. "$DOMAIN" || { _t_bad "source with isolated runtime overrides"; exit 1; }
assert_eq "test rules override remains supported" "$T/domains.v1" "$WARP_DOMAIN_RULES"
assert_eq "test status override remains supported" "$T/domain-status.json" "$WARP_DOMAIN_STATUS"

_t_done
