#!/bin/sh
# CLI install/update commands must converge through the one install_release entry.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-cli"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-cli.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
cat > "$T/install_release" <<'INSTALL'
#!/bin/sh
printf 'install_release:%s\n' "$*" >> "$Z2K_TEST_LOG"
exit "${Z2K_TEST_INSTALL_RC:-0}"
INSTALL
cat > "$T/update" <<'UPDATE'
#!/bin/sh
printf 'update:%s\n' "$*" >> "$Z2K_TEST_LOG"
UPDATE
cat > "$T/init" <<'INIT'
#!/bin/sh
printf 'init:%s\n' "$*" >> "$Z2K_TEST_LOG"
exit "${Z2K_TEST_INIT_RC:-0}"
INIT
chmod +x "$T/install_release" "$T/update" "$T/init"
export Z2K_INSTALL_RELEASE_BIN="$T/install_release" Z2K_UPDATE_BIN="$T/update" \
    Z2K_INIT="$T/init" Z2K_TEST_LOG="$T/calls"

if sh "$REPO/platform/openwrt/z2kow.sh" install p-86.13 >/dev/null 2>&1; then _t_ok; else _t_bad "CLI install dispatch"; fi
assert_eq "CLI install calls the canonical installer" 'install_release:p-86.13' "$(cat "$T/calls")"
: > "$T/calls"
if sh "$REPO/platform/openwrt/z2kow.sh" update >/dev/null 2>&1; then _t_ok; else _t_bad "CLI update dispatch"; fi
assert_eq "CLI update goes to update adapter, whose apply path uses installer" 'update:apply' "$(cat "$T/calls")"
: > "$T/calls"
Z2K_TEST_INSTALL_RC=7 sh "$REPO/platform/openwrt/z2kow.sh" install p-86.13 >/dev/null 2>&1
assert_eq "CLI propagates install failure" '7' "$?"
assert_eq "failed CLI install still uses the canonical installer" 'install_release:p-86.13' "$(cat "$T/calls")"
: > "$T/calls"
sh "$REPO/platform/openwrt/z2kow.sh" install >/dev/null 2>&1
assert_eq "CLI rejects a missing release tag" '2' "$?"
assert_eq "invalid CLI call never starts another engine" '' "$(cat "$T/calls")"
[ ! -e "$REPO/platform/openwrt/product-update.sh" ] && _t_ok || _t_bad "no component updater remains"
_t_done
