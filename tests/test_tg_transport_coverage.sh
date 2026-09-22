#!/bin/sh
# Exercise rule migration and independent IPv6 recovery without real netfilter.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
. "$ROOT/files/z2k-tg-redirect.sh"
: > "$TMP/rules"; : > "$TMP/log"
mock_ipt() {
    family=$1; shift
    [ "${1:-}" != -t ] || shift 2
    op=$1; chain=$2; shift 2
    if [ "$op" = -I ]; then shift; fi
    rule="$family $chain $*"
    printf '%s %s\n' "$op" "$rule" >> "$TMP/log"
    case "$op" in
        -C) grep -Fxq -- "$rule" "$TMP/rules" ;;
        -I) if [ "${FAIL_OUTPUT:-0}" = 1 ] && [ "$family:$chain" = '4:OUTPUT' ]; then return 1; fi
            printf '%s\n' "$rule" >> "$TMP/rules" ;;
        -D) grep -Fxv -- "$rule" "$TMP/rules" > "$TMP/new" || true; mv "$TMP/new" "$TMP/rules" ;;
        *) echo "unexpected netfilter operation $op" >&2; return 1 ;;
    esac
}
_z2k_tg_ipt() { mock_ipt 4 "$@"; }
_z2k_tg_ipt6() { mock_ipt 6 "$@"; }
ipset() { printf 'ipset %s\n' "$*" >> "$TMP/log"; }
sleep() { :; }
check() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
old_rule() { printf '4 %s -p tcp --dport 443 -m set --match-set z2k_tg_dc dst -j REDIRECT --to-port 1443\n' "$1"; }
old_rule PREROUTING >> "$TMP/rules"; old_rule OUTPUT >> "$TMP/rules"
z2k_tg_ensure_rules
check z2k_tg_rule_present PREROUTING
check z2k_tg_rule_present OUTPUT
check z2k_tg_rule6_present FORWARD
check z2k_tg_rule6_present OUTPUT
check test "$(wc -l < "$TMP/rules" | tr -d ' ')" = 4
check grep -q -- '--dports 80,443,5222' "$TMP/rules"
# Migration retains both old rules until both new rules have passed checks.
check awk '/^-I 4 OUTPUT /{installed=1} /^-D 4 /&&!installed{exit 1}' "$TMP/log"
z2k_tg_ensure_rules
check test "$(wc -l < "$TMP/rules" | tr -d ' ')" = 4
# A wiped IPv6 filter must be repairable independently of IPv4 NAT.
grep '^4 ' "$TMP/rules" > "$TMP/new"; mv "$TMP/new" "$TMP/rules"
z2k_tg_ensure_rules6
check z2k_tg_rule6_present FORWARD
check z2k_tg_rule6_present OUTPUT
check grep -q 'ipset add z2k_tg_dc6 2a0a:f280::/32' "$TMP/log"
z2k_tg_remove_rules
check test ! -s "$TMP/rules"
# Failure to install the second replacement rule leaves legacy 443 usable.
old_rule PREROUTING > "$TMP/rules"; old_rule OUTPUT >> "$TMP/rules"
FAIL_OUTPUT=1
if z2k_tg_ensure_rules; then echo 'FAIL: accepted failed installation'; exit 1; fi
check grep -Fxq -- "$(old_rule PREROUTING)" "$TMP/rules"
check grep -Fxq -- "$(old_rule OUTPUT)" "$TMP/rules"
unset FAIL_OUTPUT
z2k_tg_remove_rules
check test ! -s "$TMP/rules"
# Execute the NDM hook using an isolated lib, configuration and pidof.
mkdir "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/pidof"; chmod +x "$TMP/bin/pidof"
cat > "$TMP/lib" <<'LIB'
z2k_tg_udp_ensure() { :; }
z2k_tg_ensure_rules6() { echo ipv6; }
z2k_tg_ensure_rules() { echo ipv4; }
z2k_tg_remove_legacy_rules() { :; }
z2k_tg_flush_conntrack() { echo conntrack; }
LIB
printf 'TG_PROXY_USER_DISABLED=0\n' > "$TMP/config"
sed -e '/^export PATH=/d' -e "s|CONFIG_FILE=\"/opt/zapret2/config\"|CONFIG_FILE=\"$TMP/config\"|" \
    -e "s|LIB=\"/opt/zapret2/z2k-tg-redirect.sh\"|LIB=\"$TMP/lib\"|" \
    "$ROOT/files/ndm/90-z2k-tg-redirect.sh" > "$TMP/hook"
out=$(PATH="$TMP/bin:$PATH" type=ip6tables table=filter sh "$TMP/hook")
check test "$out" = ipv6
out=$(PATH="$TMP/bin:$PATH" type=ip6tables table=nat sh "$TMP/hook")
check test -z "$out"
printf 'TG_PROXY_USER_DISABLED=1\n' > "$TMP/config"
out=$(PATH="$TMP/bin:$PATH" type=ip6tables table=filter sh "$TMP/hook")
check test -z "$out"
printf 'PASS: multiport migration, idempotence, failed install, stop, IPv6 repair and NDM events\n'
