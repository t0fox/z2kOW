#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export TMP
cat > "$TMP/iptables" <<'PY'
#!/usr/bin/env python3
import json,os,shlex,sys
from pathlib import Path
p=Path(os.environ['TMP'])/'live.json'
s=json.loads(p.read_text());args=sys.argv[1:]
if args==['-w','-S','OUTPUT']: print('\n'.join(s))
else:
 assert args[:3]==['-w','-D','OUTPUT'],args
 target=['-A',*args[2:]]
 i=next(i for i,line in enumerate(s) if shlex.split(line)==target)
 s.pop(i);p.write_text(json.dumps(s))
PY
cat > "$TMP/restore" <<'SH'
#!/bin/sh
[ "$1" = --test ] || exit 1
cat > /dev/null
SH
chmod +x "$TMP/iptables" "$TMP/restore"
python3 - <<'PY'
import json,os
from pathlib import Path
root=Path(os.environ['TMP'])
owned='-A OUTPUT -p udp --dport 443 -m comment --comment z2k-telegram-udp -j ACCEPT'
keep=['-A OUTPUT -p udp --dport 443 -j DROP','-A OUTPUT -m comment --comment z2k-telegram-udp-other -j ACCEPT']
lines=[owned,owned,*keep]
(root/'live.json').write_text(json.dumps(lines))
(root/'rules').write_text('*filter\n'+ '\n'.join(lines)+'\nCOMMIT\n')
(root/'rules').chmod(0o600)
(root/'expected').write_text('*filter\n'+ '\n'.join(keep)+'\nCOMMIT\n')
PY
for pass in 1 2; do
 RULES_FILE="$TMP/rules" IPTABLES="$TMP/iptables" IPTABLES_RESTORE="$TMP/restore" sh "$ROOT/vps/bin/telegram-udp-firewall.sh" --apply >/dev/null
done
cmp "$TMP/rules" "$TMP/expected"
python3 - <<'PY'
import json,os,stat
from pathlib import Path
p=Path(os.environ['TMP']);s=json.loads((p/'live.json').read_text())
assert len(s)==2 and s[0].endswith('-j DROP') and 'udp-other' in s[1],s
assert stat.S_IMODE((p/'rules').stat().st_mode)==0o600
assert (p/'rules.z2k-udp-retired.bak').exists()
PY
printf 'PASS: VPS retirement removes only exact tagged UDP exceptions, preserves QUIC block, file mode and backup; idempotent\n'
