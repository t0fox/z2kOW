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
 elif a[:2]==['route','flush']:s['routes']=[v for v in s['routes'] if not (v[0]==fam and v[1][-1]==a[-1])]
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
Z2K_TG_UDP_READY="$TMP/ready"
ip() { python3 "$TMP/mock.py" ip "$@"; }
_z2k_tg_ipt() { python3 "$TMP/mock.py" 4 "$@"; }
_z2k_tg_ipt6() { python3 "$TMP/mock.py" 6 "$@"; }
python3 - <<'SEED'
import json,os
s={'rules':[],'chains':[],'routes':[],'policy':[]}
for f in ['-4','-6']:
 for mask in ['0x8000000','0xffffffff']:
  s['policy'] += [[f,['rule','add','pref','89','fwmark','0x8000000/'+mask,'table','988']]]*2
 s['policy'].append([f,['rule','add','pref','89','fwmark','0x1234','table','999']])
 for table in ['988','999']:
  s['routes'].append([f,['route','replace','default','dev','z2ktg0' if table=='988' else 'nwg0','table',table]])
for f,ipset in [('4','z2k_tg_dc'),('6','z2k_tg_dc6')]:
 s['chains'].append([f,'mangle','Z2K_TG_UDP'])
 for tab,chain,rule in [
 ('mangle','PREROUTING',['-i','br+','-p','udp','-m','set','--match-set',ipset,'dst','-j','Z2K_TG_UDP']),
 ('mangle','PREROUTING',['-i','z2ktg0','-j','ACCEPT']),
 ('filter','FORWARD',['-o','z2ktg0','-p','udp','-m','set','--match-set',ipset,'dst','-j','ACCEPT']),
 ('filter','FORWARD',['-i','z2ktg0','-p','udp','-m','set','--match-set',ipset,'src','-m','conntrack','--ctstate','ESTABLISHED','-j','ACCEPT']),
 ('nat','POSTROUTING',['-o','z2ktg0','-j','ACCEPT']),
 ('mangle','Z2K_TG_UDP',['-j','MARK','--set-xmark','0x8000000/0x8000000'])]:
  s['rules'] += [[f,tab,chain,rule]]*2
 s['rules'].append([f,'mangle','PREROUTING',['-i','nwg0','-j','OTHER']])
for chain in ['PREROUTING','OUTPUT']:
 s['rules'] += [['4','nat',chain,['-p','tcp','-m','multiport','--dports','80,443,5222','-m','set','--match-set','z2k_tg_dc','dst','-j','REDIRECT','--to-port','1443']]]*2
s['rules'].append(['4','nat','OUTPUT',['-p','tcp','--dport','443','-j','REDIRECT','--to-port','1443']])
json.dump(s,open(os.environ['TMP']+'/state.json','w'))
SEED
: > "$Z2K_TG_UDP_READY"
z2k_tg_udp_down
z2k_tg_remove_retired_tcp_rules
z2k_tg_udp_down
z2k_tg_remove_retired_tcp_rules
[ ! -f "$Z2K_TG_UDP_READY" ]
python3 - <<'CHECK'
import json,os
s=json.load(open(os.environ['TMP']+'/state.json'))
assert not s['chains'],s
assert len(s['policy'])==2 and all(r[-1]=='999' for f,r in s['policy']),s
assert len(s['routes'])==2 and all(r[-1]=='999' for f,r in s['routes']),s
assert len(s['rules'])==3,s
assert all('OTHER' in r[3] or '443' in r[3] for r in s['rules']),s
print('PASS: retired UDP cleaned for both families, duplicates and repeat cleanup; native policies and TCP preserved')
CHECK
