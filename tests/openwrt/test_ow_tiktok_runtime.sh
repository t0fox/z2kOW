#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tiktok-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tiktok.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/state"
export PATH="$T/bin:$PATH"
export UCI_TEST_DB="$T/uci.db" UCI_TEST_LOG="$T/uci.log" DNSMASQ_TEST_LOG="$T/dnsmasq.log"
export Z2K_STATE="$T/state"
export Z2K_TIKTOK_HOSTS_FILE="$T/state/tiktok-cdn-hosts"
export Z2K_TIKTOK_UCI_MARKER="$T/state/.tiktok-addnhosts-owned"
export Z2K_TIKTOK_STATE_FILE="$T/state/tiktok-cdn.state"
export Z2K_TIKTOK_DISABLED_FILE="$T/state/.tiktok-disabled"
export Z2K_TIKTOK_DNSMASQ_INIT="$T/dnsmasq-init"
export Z2K_TIKTOK_UCI_BIN=uci Z2K_TIKTOK_CURL_BIN=curl Z2K_TIKTOK_NSLOOKUP_BIN=nslookup
printf "dhcp.cfg0001='dnsmasq'\n" > "$UCI_TEST_DB"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$UCI_TEST_LOG"
case "$*" in
    "-q show dhcp.@dnsmasq[0]") exit 0 ;;
    "-q show dhcp") cat "$UCI_TEST_DB" ;;
    "commit dhcp") exit 0 ;;
    "add_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#*=}
        printf "dhcp.@dnsmasq[0].addnhosts='%s'\n" "$_path" >> "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#*=}
        awk -v path="$_path" 'index($0, ".addnhosts=\047" path "\047") == 0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/nslookup" <<'STUB'
#!/bin/sh
printf 'Server: %s\nAddress 1: %s\nName: %s\nAddress 1: 143.244.42.18\n' "$2" "$2" "$1"
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
_resolve=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --resolve ]; then _resolve=$2; shift 2; continue; fi
    shift
done
_ip=${_resolve##*:}
case "$_ip" in
    143.244.42.18) printf '0.020000 0.080000'; exit 0 ;;
    *) exit 28 ;;
esac
STUB
cat > "$Z2K_TIKTOK_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_TEST_LOG"
[ "${1:-}" = reload ]
STUB
chmod 0755 "$T/bin/uci" "$T/bin/nslookup" "$T/bin/curl" "$Z2K_TIKTOK_DNSMASQ_INIT"

# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/tiktok.sh"
z2k_ow_tiktok_check || _t_bad "initial TikTok CDN selection succeeds"
assert_contains "owned dnsmasq include is registered" "$UCI_TEST_DB" "$Z2K_TIKTOK_HOSTS_FILE"
assert_contains "verified CDN is pinned with hosts syntax" "$Z2K_TIKTOK_HOSTS_FILE" '143.244.42.18 v77.tiktokcdn.com'
assert_contains "state records healthy selection" "$Z2K_TIKTOK_STATE_FILE" 'state=healthy'
assert_contains "state records selected CDN" "$Z2K_TIKTOK_STATE_FILE" 'selected_ip=143.244.42.18'
assert_file "ownership marker is persistent" "$Z2K_TIKTOK_UCI_MARKER"

# A user/upstream dnsmasq override has priority. The OpenWrt extension removes
# only its own hosts record and does not delete the foreign setting.
printf "dhcp.@dnsmasq[0].address='/v77.tiktokcdn.com/203.0.113.10'\n" >> "$UCI_TEST_DB"
z2k_ow_tiktok_check || _t_bad "external TikTok DNS owner is accepted"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "owned pin is cleared when an external owner appears"
assert_contains "foreign DNS override remains untouched" "$UCI_TEST_DB" '203.0.113.10'
assert_contains "state exposes external ownership" "$Z2K_TIKTOK_STATE_FILE" 'state=external'

grep -v '\.address=' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"; mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
z2k_ow_tiktok_disable || _t_bad "TikTok autofix disables cleanly"
assert_file "disabled choice is persistent" "$Z2K_TIKTOK_DISABLED_FILE"
[ ! -s "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "disable clears only the owned pin"
z2k_ow_tiktok_enable || _t_bad "TikTok autofix re-enables and probes"
assert_contains "re-enable restores verified CDN" "$Z2K_TIKTOK_HOSTS_FILE" '143.244.42.18 v77.tiktokcdn.com'

z2k_ow_tiktok_uninstall || _t_bad "TikTok adapter cleanup succeeds"
assert_not_contains "uninstall removes only its addnhosts reference" "$UCI_TEST_DB" 'tiktok-cdn-hosts'
[ ! -e "$Z2K_TIKTOK_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes owned TikTok hosts file"
[ ! -e "$Z2K_TIKTOK_UCI_MARKER" ] && _t_ok || _t_bad "uninstall removes TikTok ownership marker"

_t_done
