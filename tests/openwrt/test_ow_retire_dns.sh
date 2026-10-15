#!/bin/sh
# No-QEMU contract test for the one-time legacy DNS retirement.
. "$(dirname "$0")/helper.sh"
_t_plan ow-retire-dns
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/state" "$T/bin"
retire="$REPO/platform/openwrt/retire-dns.sh"
: > "$T/calls"
cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_DNS_RETIRE_LOG"
case "$1 $2" in
  '-q export') printf 'edited external config\n' ;;
esac
exit 0
STUB
chmod +x "$T/bin/uci"
export Z2K_STATE="$T/state"
export Z2K_DNS_RETIRE_UCI_BIN="$T/bin/uci"
export Z2K_DNS_RETIRE_LOG="$T/calls"
sh "$retire" && _t_ok || _t_bad "clean state failed"
assert_eq "clean state: no DNS commands" "" "$(cat "$T/calls")"
printf 'noresolv=0\nroute_preexisting=0\n' > "$T/state/.dnsproxy-dnsmasq-snapshot"
printf 'customer-created profile\n' > "$T/state/.dnsproxy-config-backup"
sh "$retire" && _t_bad "external config was silently retired" || _t_ok
assert_file "external snapshot preserved" "$T/state/.dnsproxy-dnsmasq-snapshot"
assert_file "customer profile preserved" "$T/state/.dnsproxy-config-backup"
assert_eq "external config: no DNS commands" "" "$(cat "$T/calls")"
rm -f "$T/state/.dnsproxy-config-backup"
printf 'different baseline\n' > "$T/state/.dnsproxy-config-baseline"
sh "$retire" && _t_bad "edited dnsproxy config was silently retired" || _t_ok
assert_file "edited config preserves route snapshot" "$T/state/.dnsproxy-dnsmasq-snapshot"
: > "$T/calls"
rm -f "$T/state/.dnsproxy-dnsmasq-snapshot"
ln -s "$T/state" "$T/symlink"
Z2K_STATE="$T/symlink" sh "$retire" && _t_ok || _t_bad "symlink state guard failed"
assert_eq "symlink state: no DNS commands" "" "$(cat "$T/calls")"
_t_done
