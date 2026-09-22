#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMP
ZAPRET_BASE="$TMP"
cp "$ROOT/files/z2k-tg-redirect.sh" "$TMP/z2k-tg-redirect.sh"
for fn in z2k_tg_nfq_exclude _fw_nfqws_post4 _fw_nfqws_post6 _fw_nfqws_pre4 _fw_nfqws_pre6; do
 eval "$(sed -n "/^$fn()/,/^}/p" "$ROOT/files/S99zapret2.new")"
done
DISABLE_IPV4=0 DISABLE_IPV6=0 Z2K_CONNMARK_OK4=1 Z2K_CONNMARK_OK6=1
Z2K_CONNMARK_EXCLUDE=0x20000000/0x20000000 DESYNC_MARK=0x40000000
IPSET_EXCLUDE='-m set ! --match-set nozapret'
IPSET_EXCLUDE6='-m set ! --match-set nozapret6'
TG_PROXY_USER_DISABLED=0
ipt_print_op() { :; }
ipt_mark_filter() { :; }
ipset() { [ "${FAIL_SET:-0}" = 0 ]; }
logger() { :; }
ipt_add_del() { printf '4 %s\n' "$*" >> "$TMP/rules"; }
ipt6_add_del() { printf '6 %s\n' "$*" >> "$TMP/rules"; }
for proto in udp tcp; do
 for fam in 4 6; do
  for op in 1 0; do
   "_fw_nfqws_post$fam" "$op" "-p $proto -m set --match-set zport_$proto dst" 200 'ppp0 eth2'
   "_fw_nfqws_pre$fam" "$op" "-p $proto -m set --match-set zport_$proto src" 200 'ppp0 eth2'
  done
 done
done
python3 - <<'PY'
import os,shlex,ipaddress
lines=open(os.environ['TMP']+'/rules').read().splitlines()
assert len(lines)==48
for line in lines:
 a=shlex.split(line); fam=a[0]; proto=a[a.index('-p')+1]; chain=a[2]
 setname='z2k_tg_dc'+('6' if fam=='6' else '')
 if proto=='udp':
  assert setname in a,'Telegram UDP still enters NFQUEUE: '+line
  i=a.index(setname)
  assert a[i-2:i]==['!','--match-set']
  assert a[i+1]==('dst' if chain=='POSTROUTING' else 'src')
  # This extra predicate excludes only TG addresses; queue and existing policy
  # conditions must stay in place for other UDP traffic.
  assert '-j' in a and a[a.index('-j')+1]=='NFQUEUE'
 else: assert setname not in a,'TCP unexpectedly bypasses zapret'
# Exact same shape for install and removal, no orphaned rules on restart.
added={x.replace(' 1 ',' OP ',1) for x in lines if x.split()[1]=='1'}
removed={x.replace(' 0 ',' OP ',1) for x in lines if x.split()[1]=='0'}
assert added==removed
PY
: > "$TMP/rules"
TG_PROXY_USER_DISABLED=1
_fw_nfqws_post4 1 '-p udp' 200 ppp0
! grep -q z2k_tg_dc "$TMP/rules"
TG_PROXY_USER_DISABLED=0
FAIL_SET=1
_fw_nfqws_post4 1 '-p udp' 200 ppp0
! grep -q z2k_tg_dc "$TMP/rules"
echo 'PASS: scoped Telegram UDP NFQUEUE exclusions, both families/directions, TCP and disabled mode preserved'
