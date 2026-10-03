#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-stats-upload"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-stats.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/payload/extra_strats/cache/autocircular" "$T/etc/state"
cat > "$T/bin/curl" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" > "$T/curl.args"
exit 0
EOF
chmod 0755 "$T/bin/curl"
printf 'rkn_tcp\tprivate.example\t2\t1\n' > "$T/etc/state/state.tsv"
printf 'legacy_tcp\tshould-not-leak.example\t9\t1\n' > \
    "$T/payload/extra_strats/cache/autocircular/state.tsv"
cat > "$T/etc/config" <<'EOF'
Z2K_STATS=1
Z2K_STATS_ACK=1
Z2K_STATS_ENDPOINT=https://telemetry.invalid/stats
Z2K_STATS_TOKEN=test-token
EOF

Z2K_STUB_PATH="$T/bin" Z2K_STATS_NO_JITTER=1 ZAPRET2_DIR="$T/payload" \
    CONFIG_FILE="$T/etc/config" STATE_FILE="$T/etc/state/state.tsv" \
    sh "$REPO/files/z2k-stats-upload.sh"
assert_file "uploader used OpenWrt test transport" "$T/curl.args"
assert_contains "uploader targets the configured endpoint" "$T/curl.args" "https://telemetry.invalid/stats"
assert_contains "uploader includes canonical pool data" "$T/curl.args" 'rkn_tcp'
assert_not_contains "uploader omits visited domain" "$T/curl.args" 'private\.example'
assert_not_contains "uploader ignores legacy payload state" "$T/curl.args" 'legacy_tcp|should-not-leak'
assert_contains "uploader uses OpenWrt config override" "$REPO/files/z2k-stats-upload.sh" 'CONFIG_FILE:-'
assert_contains "uploader uses OpenWrt state override" "$REPO/files/z2k-stats-upload.sh" 'STATE_FILE:-'
_t_done
