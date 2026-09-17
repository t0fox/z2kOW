#!/bin/sh
# tests/openwrt/test_ow_dns_detect_path.sh - the OpenWrt DNS probe must call
# the package-owned detector path, without requiring a /opt symlink.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-dns-detect-path"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-dns.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"

cat > "$T/bin/z2k-detect" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$Z2K_DNS_TEST_ARGS"
printf '37\n'
EOF
cat > "$T/bin/head" <<'EOF'
#!/bin/sh
IFS= read -r _line || true
printf '%s\n' "$_line"
EOF
chmod +x "$T/bin/z2k-detect" "$T/bin/head"

_args="$T/args"
_ms="$(Z2K_DNS_LIB=1 Z2K_DETECT_BIN="$T/bin/z2k-detect" \
    Z2K_DNS_TEST_ARGS="$_args" ZAPRET2_DIR="$T/no-opt" PATH="$T/bin" \
    /bin/sh -c '. "$1"; udp_ms "$2" "$3"' sh \
    "$REPO/files/z2k-dns-check.sh" 1.1.1.1 example.com)"
assert_eq "OpenWrt detector result" "37" "$_ms"
assert_contains "detector server argument" "$_args" "1.1.1.1"
assert_contains "detector name argument" "$_args" "example.com"
assert_contains "detector timeout argument" "$_args" "5s"
if sed -n '/^udp_ms()/,/^}/p' "$REPO/files/z2k-dns-check.sh" | grep -q 'Z2K_DETECT_BIN'; then
    _t_ok
else
    _t_bad "OpenWrt path is explicit: Z2K_DETECT_BIN отсутствует в udp_ms"
fi

_t_done
