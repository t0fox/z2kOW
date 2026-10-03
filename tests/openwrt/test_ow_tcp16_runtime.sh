#!/bin/sh
# Exercise the shared upstream TCP16 probe through OpenWrt's canonical paths,
# generated config, Lua argv, first-result adapter, and persistent state.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tcp16-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tcp16.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
R="$T/root" E="$T/etc" TMPROOT="$T/tmp"
mkdir -p "$R/platform" "$R/lib" "$R/bin" "$R/lists" "$R/lua" \
    "$E/state" "$E/user-lists" "$TMPROOT"
ln -s "$REPO/platform/openwrt" "$R/platform/openwrt"
ln -s "$E/config" "$R/config"
printf 'ENABLED=1\nZ2K_SNI_STALL=1\n' > "$E/config"
printf 'target\n' > "$R/lists/tcp16_targets.txt"
printf 'net\n' > "$R/lists/tcp16_nets.txt"
printf 'test.example\n' > "$R/lists/sni_wl_candidates.txt"
cp "$REPO/files/lua/z2k-tcp16.lua" "$R/lua/z2k-tcp16.lua"
cat > "$R/lib/utils.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$R/lib/strategies.sh" <<'EOF'
#!/bin/sh
EOF
cat > "$R/lib/config_official.sh" <<'EOF'
#!/bin/sh
create_official_config() {
    if [ "$(cat "$Z2K_TCP16_FLAG" 2>/dev/null)" = 1 ]; then
        printf 'ENABLED=1\nNFQWS2_OPT="\n--lua-desync=z2k_sni_pick\n"\n' > "$1"
    else
        printf 'ENABLED=1\nNFQWS2_OPT="\n--filter-tcp=443\n"\n' > "$1"
    fi
}
EOF
cat > "$R/z2k-config-validator.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$R/z2k-config-validator.sh"
cat > "$R/bin/z2k-detect" <<'EOF'
#!/bin/sh
[ "$1" = tcp16 ] || exit 2
shift
[ "${1:-}" = -h ] && exit 0
_scan=0 _out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -scan) _scan=1; shift ;;
        -asn-out|-sni-out) _out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ "$_scan" = 1 ]; then
    printf '24940\ttest.example\n' > "$_out"
    exit 0
fi
printf '24940\n' > "$_out"
printf '%s\n' "$(( $(cat "${TCP16_COUNT_FILE:?}" 2>/dev/null || echo 0) + 1 ))" > "$TCP16_COUNT_FILE"
exit "${TCP16_RESULT:-1}"
EOF
chmod 0755 "$R/bin/z2k-detect"

Z2K_PLATFORM=openwrt Z2K_ROOT="$R" Z2K_ETC="$E" Z2K_TMP="$TMPROOT" \
    Z2K_BIN="$R/bin" Z2K_TCP16_PROBE="$REPO/files/z2k-tcp16-probe.sh" \
    Z2K_TCP16_LOG="$TMPROOT/tcp16.log" Z2K_TCP16_LOCK="$TMPROOT/locks/tcp16" \
    TCP16_COUNT_FILE="$T/count" TCP16_RESULT=1 Z2K_TCP16_WAIT_BIN=0 \
    sh "$R/platform/openwrt/tcp16-check.sh" > "$T/first.log" 2>&1
assert_eq "first service-result check runs the probe once" "1" "$(cat "$T/count" 2>/dev/null)"
assert_eq "blocked line verdict is persistent" "1" "$(cat "$E/state/tcp16.flag" 2>/dev/null)"
assert_eq "probe writes persistent SNI map" "$(printf '24940\ttest.example')" "$(cat "$E/state/tcp16_sni.txt" 2>/dev/null)"
case "$(cat "$E/state/tcp16.flag.ts" 2>/dev/null)" in
    ''|*[!0-9]*) _t_bad "probe publishes numeric timestamp" ;;
    *) _t_ok ;;
esac
case "$(cat "$E/state/tcp16.duration" 2>/dev/null)" in
    ''|*[!0-9]*) _t_bad "probe publishes numeric duration" ;;
    *) _t_ok ;;
esac
assert_contains "blocked verdict regenerates canonical config" "$E/config" "--lua-desync=z2k_sni_pick"

# A check after reboot must trust persistent state and avoid a second first-run
# probe. The full nightly/manual entry still calls z2k-tcp16-probe.sh directly.
rm -rf "$TMPROOT"
mkdir -p "$TMPROOT"
Z2K_PLATFORM=openwrt Z2K_ROOT="$R" Z2K_ETC="$E" Z2K_TMP="$TMPROOT" \
    Z2K_BIN="$R/bin" Z2K_TCP16_PROBE="$REPO/files/z2k-tcp16-probe.sh" \
    Z2K_TCP16_LOG="$TMPROOT/tcp16.log" Z2K_TCP16_LOCK="$TMPROOT/locks/tcp16" \
    TCP16_COUNT_FILE="$T/count" TCP16_RESULT=0 Z2K_TCP16_WAIT_BIN=0 \
    sh "$R/platform/openwrt/tcp16-check.sh" > "$T/reboot-check.log" 2>&1
assert_eq "persistent verdict survives reboot check" "1" "$(cat "$T/count" 2>/dev/null)"
assert_eq "persistent state still says blocked" "1" "$(cat "$E/state/tcp16.flag" 2>/dev/null)"

# Nightly/manual invocation is the same full probe and updates the result only
# after success, which also removes the TCP16 config integration.
Z2K_PLATFORM=openwrt Z2K_ROOT="$R" Z2K_ETC="$E" Z2K_TMP="$TMPROOT" \
    Z2K_BIN="$R/bin" Z2K_TCP16_PROBE="$REPO/files/z2k-tcp16-probe.sh" \
    Z2K_TCP16_LOG="$TMPROOT/tcp16.log" Z2K_TCP16_LOCK="$TMPROOT/locks/tcp16" \
    TCP16_COUNT_FILE="$T/count" TCP16_RESULT=0 Z2K_TCP16_WAIT_BIN=0 \
    sh "$REPO/files/z2k-tcp16-probe.sh" > "$T/nightly.log" 2>&1
assert_eq "nightly probe refreshes clear verdict" "0" "$(cat "$E/state/tcp16.flag" 2>/dev/null)"
assert_not_contains "clear verdict removes generated TCP16 config" "--lua-desync=z2k_sni_pick" "$(cat "$E/config")"

# The actual OpenWrt procd command line includes TCP16 Lua, and the lifecycle
# exposes the first successful service start plus native 03:30 scheduling.
Z2K_ROOT="$R" Z2K_ETC="$E" Z2K_TMP="$TMPROOT"
export Z2K_ROOT Z2K_ETC Z2K_TMP
. "$REPO/platform/openwrt/paths.sh"
. "$REPO/platform/openwrt/env.sh"
. "$REPO/platform/openwrt/optbase.sh"
_argv=$(z2k_ow_optbase)
printf '%s\n' "$_argv" > "$T/nfqws2-argv"
assert_contains "nfqws2 argv loads the TCP16 Lua module" "$T/nfqws2-argv" "z2k-tcp16.lua"
assert_contains "successful service-start path calls first-result adapter" \
    "$REPO/platform/openwrt/files/etc/init.d/z2k" "tcp16-check.sh"
grep -qF 'Z2K_TCP16_NIGHTLY_CRON_LINE="30 3 * * * sh $Z2K_ROOT/z2k-tcp16-probe.sh' \
    "$REPO/platform/openwrt/schedule.sh" \
    && _t_ok || _t_bad "OpenWrt cron keeps upstream 03:30 probe"

_t_done
