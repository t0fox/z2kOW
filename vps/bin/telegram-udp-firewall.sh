#!/bin/sh
# Permit our nobody-owned relay to reach Telegram UDP/443, ahead of the
# existing general QUIC block. Preserve every unrelated live/persistent rule.
set -eu
[ "${1:-}" = --apply ] || { echo "usage: $0 --apply" >&2; exit 2; }
CIDRS_FILE=${CIDRS_FILE:-/etc/z2k/telegram-udp-cidrs.txt}
RULES_FILE=${RULES_FILE:-/etc/iptables/rules.v4}
IPTABLES=${IPTABLES:-iptables}
IPTABLES_RESTORE=${IPTABLES_RESTORE:-iptables-restore}
RELAY_UID=${RELAY_UID:-$(id -u nobody)}
tmp=$(mktemp "${RULES_FILE}.udp.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
python3 - "$RULES_FILE" "$CIDRS_FILE" "$RELAY_UID" "$tmp" <<'PY'
import ipaddress,sys
from pathlib import Path
rules,cidrs,uid,out=sys.argv[1:]
assert uid.isdecimal(), 'non-numeric relay UID'
prefixes=[str(ipaddress.IPv4Network(s)) for s in Path(cidrs).read_text().split()]
assert prefixes and len(set(prefixes))==len(prefixes)
lines=Path(rules).read_text().splitlines()
anchor='-A OUTPUT -p udp -m udp --dport 443 -j DROP'
assert lines.count(anchor)==1, 'expected exactly one existing UDP/443 block'
lines=[s for s in lines if '--comment z2k-telegram-udp ' not in s]
i=lines.index(anchor)
extra=[f'-A OUTPUT -d {p} -p udp -m udp --dport 443 -m owner --uid-owner {uid} -m comment --comment z2k-telegram-udp -j ACCEPT' for p in prefixes]
lines[i:i]=extra
Path(out).write_text('\n'.join(lines)+'\n')
PY
"$IPTABLES_RESTORE" --test < "$tmp"
while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    "$IPTABLES" -w -C OUTPUT -d "$cidr" -p udp --dport 443 -m owner --uid-owner "$RELAY_UID" -m comment --comment z2k-telegram-udp -j ACCEPT 2>/dev/null || \
        "$IPTABLES" -w -I OUTPUT 1 -d "$cidr" -p udp --dport 443 -m owner --uid-owner "$RELAY_UID" -m comment --comment z2k-telegram-udp -j ACCEPT
done < "$CIDRS_FILE"
if ! cmp -s "$tmp" "$RULES_FILE"; then
    [ -e "$RULES_FILE.z2k-udp.bak" ] || cp -p "$RULES_FILE" "$RULES_FILE.z2k-udp.bak"
    chmod --reference="$RULES_FILE" "$tmp"
    chown --reference="$RULES_FILE" "$tmp"
    mv "$tmp" "$RULES_FILE"
fi
echo 'Telegram UDP/443: scoped relay exception installed and persisted'
