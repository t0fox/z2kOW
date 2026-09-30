#!/bin/sh
# Product CLI delegates service lifecycle to the native OpenWrt init script.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-product-cli"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-product-cli.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
ROOT="$T/root"
mkdir -p "$ROOT/platform/openwrt"
cp "$REPO/platform/openwrt/paths.sh" "$ROOT/platform/openwrt/paths.sh"
cp "$REPO/platform/openwrt/z2kow.sh" "$T/z2kow.sh"
cat > "$ROOT/platform/openwrt/product-update.sh" <<'ENGINE'
#!/bin/sh
echo "engine:$*" >> "$Z2K_TEST_LOG"
ENGINE
cat > "$T/init" <<'INIT'
#!/bin/sh
echo "init:$*" >> "$Z2K_TEST_LOG"
exit "${Z2K_TEST_INIT_RC:-0}"
INIT
chmod +x "$T/init"
export Z2K_ROOT="$ROOT" Z2K_INIT="$T/init" Z2K_TEST_LOG="$T/calls"

if sh "$T/z2kow.sh" restart >/dev/null 2>&1; then _t_ok; else _t_bad "restart delegates to the OpenWrt service"; fi
assert_eq "restart uses native init action" 'init:restart' "$(cat "$T/calls" 2>/dev/null)"

: > "$T/calls"
Z2K_TEST_INIT_RC=7 sh "$T/z2kow.sh" restart >/dev/null 2>&1
assert_eq "restart propagates service failure" '7' "$?"
assert_eq "failed restart still calls native init" 'init:restart' "$(cat "$T/calls" 2>/dev/null)"

: > "$T/calls"
sh "$T/z2kow.sh" restart unexpected >/dev/null 2>&1
assert_eq "restart rejects unexpected arguments" '2' "$?"
assert_eq "invalid restart does not call init" '' "$(cat "$T/calls" 2>/dev/null)"

_t_done
