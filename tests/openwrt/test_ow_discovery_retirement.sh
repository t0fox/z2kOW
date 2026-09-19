#!/bin/sh
# p-85.2: background discovery is retired from OpenWrt, while the detector
# binary remains available for explicit operator diagnostics.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-discovery-retirement"
ow_fixture_init || { echo "FAIL[ow-discovery-retirement]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"
. "$AD/paths.sh"
. "$AD/env.sh"
. "$AD/bootstrap.sh"

assert_not_contains "package no longer installs discovery init" \
    "$REPO/package/openwrt/Makefile" 'files/etc/init.d/z2k-detect'
assert_not_contains "package no longer enables discovery init" \
    "$REPO/package/openwrt/Makefile" '/etc/init.d/z2k-detect enable'
assert_not_contains "OpenWrt package has no discovery init" \
    "$REPO/package/openwrt/ownership.map" '/etc/init.d/z2k-detect package'
assert_not_contains "scheduler has no discovery watchdog" \
    "$REPO/files/z2k-scheduler.sh" 'detect-watchdog'

# The migration is allowed to operate on the package-owned OpenWrt paths only.
export Z2K_OW_LEGACY_DETECT_INIT="$T/etc/init.d/z2k-detect"
export Z2K_OW_PROC_ROOT="$T/proc"
export Z2K_OW_KILL_CMD="$T/kill-discovery"
mkdir -p "$T/etc/init.d" "$T/proc/100" "$T/proc/101" \
    "$Z2K_BIN" "$Z2K_STATE" "$Z2K_LISTS_DIR" "$T/foreign/lists" "$T/foreign/etc/init.d"
printf '#!/bin/sh\necho stopped > %s\n' "$T/old-service-stopped" > "$Z2K_OW_LEGACY_DETECT_INIT"
chmod +x "$Z2K_OW_LEGACY_DETECT_INIT"
printf '#!/bin/sh\nexit 0\n' > "$Z2K_BIN/z2k-detect"
chmod +x "$Z2K_BIN/z2k-detect"
printf '%s\0run\0' "$Z2K_BIN/z2k-detect" > "$T/proc/100/cmdline"
printf '%s\0probe\0example.test\0' "$Z2K_BIN/z2k-detect" > "$T/proc/101/cmdline"
printf '#!/bin/sh\nrm -rf "$Z2K_OW_PROC_ROOT/$1"\n' > "$Z2K_OW_KILL_CMD"
chmod +x "$Z2K_OW_KILL_CMD"
printf 'stale\n' > "$Z2K_STATE/discovered-domains.txt"
ln -s "$Z2K_STATE/discovered-domains.txt" "$Z2K_LISTS_DIR/discovered-domains.txt"
printf 'foreign\n' > "$T/foreign/lists/discovered-domains.txt"
printf 'foreign\n' > "$T/foreign/etc/init.d/S98z2k-detect"

z2k_ow_retire_discovery >/dev/null 2>&1
assert_eq "retirement succeeds" "0" "$?"
assert_eq "old init stopped" "1" "$(grep -q stopped "$T/old-service-stopped" 2>/dev/null && echo 1 || echo 0)"
assert_eq "old init removed" "0" "$(test -e "$Z2K_OW_LEGACY_DETECT_INIT" && echo 1 || echo 0)"
assert_eq "old state removed" "0" "$(test -e "$Z2K_STATE/discovered-domains.txt" && echo 1 || echo 0)"
assert_eq "old payload link removed" "0" "$(test -e "$Z2K_LISTS_DIR/discovered-domains.txt" && echo 1 || echo 0)"
assert_eq "manual probe process preserved" "1" "$(test -e "$T/proc/101/cmdline" && echo 1 || echo 0)"
assert_eq "manual detector binary preserved" "1" "$(test -x "$Z2K_BIN/z2k-detect" && echo 1 || echo 0)"
assert_eq "foreign list preserved" "1" "$(test -f "$T/foreign/lists/discovered-domains.txt" && echo 1 || echo 0)"
assert_eq "foreign init preserved" "1" "$(test -f "$T/foreign/etc/init.d/S98z2k-detect" && echo 1 || echo 0)"

# Manual diagnostics and picker endpoints remain part of the supported surface.
for _cmd in 'case "probe"' 'case "classify"' 'case "quic"' 'case "voice"' \
            'case "tcp16"' 'case "dnsms"'; do
    assert_contains "manual detector command $_cmd" "$REPO/z2k-detect/cmd/z2k-detect/main.go" "$_cmd"
done
assert_not_contains "run command retired" "$REPO/z2k-detect/cmd/z2k-detect/main.go" 'case "run"'
assert_contains "panel manual probe remains" "$REPO/webpanel/cgi/actions.sh" 'detect_probe_domain'
assert_contains "panel picker remains" "$REPO/webpanel/cgi/api.sh" 'strategy/pick'

_t_done
