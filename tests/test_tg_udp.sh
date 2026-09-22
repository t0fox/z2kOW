#!/bin/sh
# Exercise routing installation, repeat repair, rollback and cleanup with
# stateful netfilter/ip stubs; the live router test is recorded in docs.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export TMP
cat > "$TMP/mock.py" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(os.environ['TMP'])/'state.json'
s=json.loads(p.read_text()) if p.exists() else {'rules':[],'chains':[],'routes':[],'policy':[]}
a=sys.argv[1:];kind=a.pop(0);rc=0
if kind=='ip':
 fam=a.pop(0) if a[0] in ('-4','-6') else ''
 if a[:2]==['link','show'] or a[:2]==['link','set']:pass
 elif a[:2]==['route','replace']:
  if fam=='-6' and os.environ.get('FAIL6')=='1':rc=1
  else:
   s['routes']=[v for v in s['routes'] if not (v[0]==fam and (v[1][3] if v[1][2]=='throw' else v[1][2])==(a[3] if a[2]=='throw' else a[2]))]
   s['routes'].append([fam,a])
 elif a[:2]==['route','flush']:s['routes']=[v for v in s['routes'] if v[0]!=fam]
 elif a[:2]==['rule','show']:
  for f,r in s['policy']:
   if f==fam:print(r[3]+': from all fwmark '+r[r.index('fwmark')+1]+' lookup '+r[r.index('table')+1])
 elif a[:2]==['rule','add']:s['policy'].append([fam,a])
 elif a[:2]==['rule','del']:
  key=[fam,['rule','add']+a[2:]]
  if key in s['policy']:s['policy'].remove(key)
  else:rc=1
 else:raise RuntimeError(a)
else:
 tab='filter'
 if a[0]=='-t':tab=a[1];a=a[2:]
 op,chain=a[:2];rule=a[2:]
 if op=='-I':rule=rule[1:]
 key=[kind,tab,chain,rule];ck=[kind,tab,chain]
 if op=='-C':rc=0 if key in s['rules'] else 1
 elif op=='-A':s['rules'].append(key)
 elif op=='-I':
  at=next((i for i,r in enumerate(s['rules']) if r[:3]==ck),len(s['rules']))
  s['rules'].insert(at,key)
 elif op=='-D':s['rules'].remove(key)
 elif op=='-N':
  if ck in s['chains']:rc=1
  else:s['chains'].append(ck)
 elif op=='-F':s['rules']=[r for r in s['rules'] if r[:3]!=ck]
 elif op=='-X':
  if ck in s['chains']:s['chains'].remove(ck)
 else:raise RuntimeError(a)
p.write_text(json.dumps(s));sys.exit(rc)
PY
. "$ROOT/files/z2k-tg-redirect.sh"
# shellcheck disable=SC2034 # consumed by the sourced helper
Z2K_TG_UDP_IF=lab0
Z2K_TG_UDP_READY="$TMP/ready"
ip() { python3 "$TMP/mock.py" ip "$@"; }
ipset() { :; }
_z2k_tg_ipt() { python3 "$TMP/mock.py" 4 "$@"; }
_z2k_tg_ipt6() { python3 "$TMP/mock.py" 6 "$@"; }
z2k_tg_udp_ensure
[ ! -e "$TMP/state.json" ] # no authenticated capability => no routing
: > "$Z2K_TG_UDP_READY"
z2k_tg_udp_ensure
cp "$TMP/state.json" "$TMP/first.json"
z2k_tg_udp_ensure
cmp "$TMP/state.json" "$TMP/first.json"
python3 - <<'PY'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'))
assert sorted(f for f,r in s['policy'])==['-4','-6']
# A native Keenetic policy must not match our routing selector. This caught
# p-85.6 sending unrelated VPN/game traffic into a UDP-only tunnel.
for family,rule in s['policy']:
 value=rule[rule.index('fwmark')+1].split('/')
 mark=int(value[0],16);mask=int(value[1],16) if len(value)>1 else 0xffffffff
 assert not any((native & mask)==mark for native in [0xffffaaa,0xffffaab,0xfffffd00]), 'native Keenetic policy captured by Telegram route'
 assert (0x8000000 & mask)==mark, 'Telegram-tagged traffic no longer selected'
# Defense in depth: even an accidentally matching mark cannot send arbitrary
# destinations into the tunnel. No forwarding default route is allowed.
assert not any(r[2]=='default' for f,r in s['routes']), 'unrestricted tunnel default route'
assert any('149.154.160.0/20' in r for f,r in s['routes'])
assert any('2001:67c:4e8::/48' in r for f,r in s['routes'])
for family in ['4','6']:
 rules=[r for r in s['rules'] if r[0]==family]
 divert=[r for r in rules if r[2]=='PREROUTING' and r[3][-1]=='Z2K_TG_UDP']
 assert len(divert)==1
 assert divert[0][3][:4]==['-i','br+','-p','udp']
 assert '--match-set' in divert[0][3] and 'dst' in divert[0][3]
 assert not any(r[2]=='OUTPUT' for r in rules)
 assert any(r[1:3]==['nat','POSTROUTING'] for r in rules)
 # Execute the mark/RETURN/ACCEPT chain against native policy marks. The
 # production guard must precede MARK and ACCEPT, including during migration.
 chain=[r[3] for r in rules if r[2]=='Z2K_TG_UDP']
 for native in [0,0xffffaaa,0xffffaab,0xfffffd00,0x989]:
  mark=native
  for r in chain:
   if '--mark' in r:
    val=r[r.index('--mark')+1].split('/');mask=int(val[1],16) if len(val)>1 else 0xffffffff
    match=(mark & mask)==int(val[0],16)
    if '!' in r:match=not match
    if not match:continue
   target=r[r.index('-j')+1]
   if target=='MARK':
    value,mask=(int(x,16) for x in r[r.index('--set-xmark')+1].split('/'))
    mark=(mark & ~mask)^value
   if target in ('RETURN','ACCEPT'):break
  assert mark==(0x8000000 if native==0 else native), (native,mark)
  if native:assert target=='RETURN', 'policy traffic skips NDM chains'

PY
z2k_tg_udp_down
python3 - <<'PY'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'));assert all(not v for v in s.values()),s
PY
# Upgrade from duplicate p-85.6 rules/default routes. Another service sharing
# priority 89 must survive both migration and shutdown.
python3 - <<'PYSEED'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'))
for f in ['-4','-6']:
 s['policy'] += [[f,['rule','add','pref','89','fwmark','0x8000000/0x8000000','table','988']]]*2
 s['policy'] += [[f,['rule','add','pref','89','fwmark','0x1234','table','999']]]
 s['routes'].append([f,['route','replace','default','dev','lab0','table','988']])
json.dump(s,open(os.environ['TMP']+'/state.json','w'))
PYSEED
: > "$Z2K_TG_UDP_READY"
z2k_tg_udp_ensure
python3 - <<'PYSEED'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'))
assert len(s['policy'])==4,s['policy']
assert not any('0x8000000/0x8000000' in r for f,r in s['policy'])
assert not any(r[2]=='default' for f,r in s['routes'])
PYSEED
z2k_tg_udp_down
python3 - <<'PYSEED'
import json,os
p=os.environ['TMP']+'/state.json';s=json.load(open(p))
assert len(s['policy'])==2 and all('0x1234' in r for f,r in s['policy'])
s['policy']=[]
assert all(not v for v in s.values()),s
json.dump(s,open(p,'w'))
PYSEED
: > "$Z2K_TG_UDP_READY"
export FAIL6=1
if z2k_tg_udp_ensure; then echo 'FAIL: IPv6 failure silently accepted'; exit 1; fi
python3 - <<'PY'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'));assert all(not v for v in s.values()),s
PY
[ ! -e "$Z2K_TG_UDP_READY" ]
echo 'PASS: UDP capability gate, IPv4/IPv6 routes, idempotence, LAN-only scope, cleanup, rollback'

for flag in 'Z2K_TG_UDP_RELAY=1' 'Z2K_TG_UDP_RELAY="1"'; do
    printf '%s\n' "$flag" > "$TMP/config"
    z2k_tg_udp_enabled "$TMP/config"
done
printf 'Z2K_TG_UDP_RELAY=0\n' > "$TMP/config"
if z2k_tg_udp_enabled "$TMP/config"; then exit 1; fi
z2k_tg_udp_enabled "$TMP/missing"
printf 'TG_PROXY_USER_DISABLED=0\n' > "$TMP/config"
z2k_tg_udp_enabled "$TMP/config"
