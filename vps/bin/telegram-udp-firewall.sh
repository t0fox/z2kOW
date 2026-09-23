#!/bin/sh
# Retire only the UDP experiment's tagged exceptions. Keep the normal QUIC
# policy and every unrelated live/persistent rule unchanged.
set -eu
[ "${1:-}" = --apply ] || { echo "usage: $0 --apply" >&2; exit 2; }
RULES_FILE=${RULES_FILE:-/etc/iptables/rules.v4}
IPTABLES=${IPTABLES:-iptables}
IPTABLES_RESTORE=${IPTABLES_RESTORE:-iptables-restore}
tmp=$(mktemp "${RULES_FILE}.udp.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
python3 - "$RULES_FILE" "$tmp" <<'PY'
import shlex,sys
from pathlib import Path
src,out=map(Path,sys.argv[1:])
def owned(line):
    words=shlex.split(line)
    return any(words[i:i+2]==['--comment','z2k-telegram-udp'] for i in range(len(words)-1))
out.write_text('\n'.join(s for s in src.read_text().splitlines() if not owned(s))+'\n')
PY
"$IPTABLES_RESTORE" --test < "$tmp"
# Parse save output as arguments, never eval shell text from a rule.
python3 - "$IPTABLES" <<'PY'
import shlex,subprocess,sys
ipt=sys.argv[1]
for line in subprocess.check_output([ipt,'-w','-S','OUTPUT'],text=True).splitlines():
    words=shlex.split(line)
    if words[:2]!=['-A','OUTPUT']: continue
    if not any(words[i:i+2]==['--comment','z2k-telegram-udp'] for i in range(len(words)-1)): continue
    subprocess.run([ipt,'-w','-D',*words[1:]],check=True)
PY
if ! cmp -s "$tmp" "$RULES_FILE"; then
    [ -e "$RULES_FILE.z2k-udp-retired.bak" ] || cp -p "$RULES_FILE" "$RULES_FILE.z2k-udp-retired.bak"
    python3 - "$RULES_FILE" "$tmp" <<'PYMODE'
import os,stat,sys
src,dst=sys.argv[1:]
s=os.stat(src)
os.chmod(dst,stat.S_IMODE(s.st_mode))
os.chown(dst,s.st_uid,s.st_gid)
PYMODE
    mv "$tmp" "$RULES_FILE"
fi
echo 'Retired Telegram UDP exceptions removed'
