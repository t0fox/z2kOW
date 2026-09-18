#!/bin/sh
# z2k-ppe-check.sh [секунд] — проверка с самого роутера: доходят ли пакеты
# транзитных потоков на 443 до netfilter (а значит до NFQUEUE и движка) и на
# каком пакете железный ускоритель забирает поток. Временные счётчики в mangle
# снимаются в конце, конфиг не трогается.
export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin
DUR=${1:-60}
FOE=/proc/driver/hw_nat/foe/binds
echo "=== z2k-ppe-check $(date '+%F %T'), окно $DUR с ==="
echo "board : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null) | $(uname -m) | $(ndmc -c 'show version' 2>/dev/null | grep -i -m1 'hw_id\|model' | tr -s ' ')"
echo "fw    : $(ndmc -c 'show version' 2>/dev/null | grep -i -m1 'release\|title' | tr -s ' ')"
echo "fastnat=$(cat /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null) fastroute=$(cat /proc/sys/net/netfilter/nf_conntrack_fastroute 2>/dev/null || echo n/a) hw_nat-driver=$([ -d /proc/driver/hw_nat ] && echo yes || echo NO) ppe_enabled=$(cat /proc/sys/net/hwnat/ppe_enabled 2>/dev/null || echo n/a) PPE-target=$(grep -qw PPE /proc/net/ip_tables_targets 2>/dev/null && echo yes || echo no) foe-table=$([ -r $FOE ] && echo yes || echo no)"
echo "rules : PPE=$(iptables -w -t mangle -S 2>/dev/null | grep -c -- '-j PPE') NFQUEUE=$(iptables -w -t mangle -S 2>/dev/null | grep -c NFQUEUE) nfqws2=$(pidof nfqws2 >/dev/null && echo up || echo DOWN)"
LANNET=${LANNET:-$(ip -o -4 addr show br0 2>/dev/null | awk '{print $4}' | head -1 | sed 's#\.[0-9]*/#.0/#')}
[ -n "$LANNET" ] || LANNET=192.168.0.0/16
echo "lan   : $LANNET — считаются только транзитные TCP-потоки из этой сети на порт 443"

# --- временные счётчики ------------------------------------------------------
iptables -w -t mangle -N z2kchk 2>/dev/null
add() { iptables -w -t mangle -I PREROUTING -p tcp -m conntrack --ctorigsrc "$LANNET" --ctorigdstport 443 "$@" -j z2kchk; }
add -m conntrack --ctdir ORIGINAL -m comment --comment o_all
add -m conntrack --ctdir REPLY    -m comment --comment r_all
add -m connbytes --connbytes 1:1 --connbytes-dir original --connbytes-mode packets -m comment --comment o_syn
# ClientHello = 3-й (реже 4-й) исходящий пакет потока с TLS-заголовком 16 03 01 в начале данных;
# без ограничения по номеру пакета шаблон ловил бы и куски данных длинных потоков
add -m connbytes --connbytes 3:4 --connbytes-dir original --connbytes-mode packets -m string --algo bm --from 40 --to 90 --hex-string "|160301|" -m comment --comment o_ch
cnt() { iptables -w -t mangle -L PREROUTING -v -x -n 2>/dev/null | grep z2kchk | grep "/\* $1 \*/" | awk '{print $1}'; }
cleanup() {
    # удаляем по номерам строк, с конца: правило со строковым шаблоном в кавычках через -S/-D не проходит
    for n in $(iptables -w -t mangle -L PREROUTING --line-numbers -n 2>/dev/null | awk '/z2kchk/{print $1}' | sort -rn); do iptables -w -t mangle -D PREROUTING "$n" 2>/dev/null; done
    iptables -w -t mangle -X z2kchk 2>/dev/null
    rm -f /tmp/z2kchk.*
}
trap cleanup EXIT INT TERM

# --- истина: счётчики conntrack (их увеличивает и железо) --------------------
ctsnap() { # key orig_pkts reply_pkts — транзитные потоки на 443
    awk -v net="${LANNET%/*}" 'BEGIN{split(net,a,"."); pfx=a[1]"."a[2]"."a[3]"."}
      $3=="tcp" { s=""; d=""; sp=""; dp=""; o=""; r="";
        for(i=1;i<=NF;i++){ if($i ~ /^src=/ && s=="") s=substr($i,5); if($i ~ /^dst=/ && d=="") d=substr($i,5);
          if($i ~ /^sport=/ && sp=="") sp=substr($i,7); if($i ~ /^dport=/ && dp=="") dp=substr($i,7);
          if($i ~ /^packets=/){ if(o=="") o=substr($i,9); else r=substr($i,9) } }
        if(dp=="443" && index(s,pfx)==1) print s":"sp">"d, o, r }' /proc/net/nf_conntrack 2>/dev/null
}
ctsnap | sort > /tmp/z2kchk.ct0
grep -o 'IPv4_NAPT=[0-9]*: [0-9.]*:[0-9]* -> [0-9.]*:443 ' $FOE 2>/dev/null | awk '{print $2, $4}' > /tmp/z2kchk.base
: > /tmp/z2kchk.seen
echo "наблюдаю $DUR с — откройте с телефона или ПК несколько сайтов и что-нибудь тяжёлое: видео, большой файл"

# --- момент захвата потока железом (опрос 20 раз в секунду) ------------------
i=0; ticks=$((DUR*20)); : > /tmp/z2kchk.binds
while [ $i -lt $ticks ]; do
    if [ -r $FOE ]; then
        grep -o 'IPv4_NAPT=[0-9]*: [0-9.]*:[0-9]* -> [0-9.]*:443 ' $FOE 2>/dev/null | awk '{print $2, $4}' | while read -r s d; do
            grep -q "^$s $d$" /tmp/z2kchk.base && continue
            grep -q "^$s $d$" /tmp/z2kchk.seen && continue
            echo "$s $d" >> /tmp/z2kchk.seen
            ct=$(grep "src=${s%:*} .*dst=${d%:*} sport=${s#*:} dport=443 " /proc/net/nf_conntrack 2>/dev/null | head -1)
            o=$(echo "$ct" | grep -o 'packets=[0-9]*' | sed -n 1p | cut -d= -f2)
            r=$(echo "$ct" | grep -o 'packets=[0-9]*' | sed -n 2p | cut -d= -f2)
            echo "${o:-0} ${r:-0}" >> /tmp/z2kchk.binds
            echo "  железо забрало $s -> $d: исходящих=${o:-?} ответных=${r:-?} пакетов к этому моменту"
        done
    fi
    usleep 50000; i=$((i+1))
done

# --- итог ---------------------------------------------------------------------
ctsnap | sort > /tmp/z2kchk.ct1
# дельта по conntrack: новые потоки целиком + прирост старых
# в awk обращение o0[$1] само создаёт ключ — членство проверяется ДО арифметики
truth=$(awk 'NR==FNR{o0[$1]=$2; r0[$1]=$3; next} { if($1 in o0){ o+=$2-o0[$1]; r+=$3-r0[$1] } else { o+=$2; r+=$3; if($2>=4) f++ } } END{printf "%d %d %d", o, r, f}' /tmp/z2kchk.ct0 /tmp/z2kchk.ct1)
to=${truth%% *}; tr_=$(echo "$truth" | awk '{print $2}'); nf=${truth##* }
oa=$(cnt o_all); ra=$(cnt r_all); os=$(cnt o_syn); oc=$(cnt o_ch)
pct() { [ "${2:-0}" -gt 0 ] && echo $(( ${1:-0} * 100 / $2 )) || echo "-"; }
echo "--- итог за $DUR с ---"
echo "  исходящие пакеты (клиент→сервер): всего по conntrack $to, дошло до netfilter ${oa:-0} ($(pct "$oa" "$to") %)"
echo "  ответные пакеты (сервер→клиент): всего по conntrack $tr_, дошло до netfilter ${ra:-0} ($(pct "$ra" "$tr_") %)"
echo "  новых потоков: по conntrack с ≥4 исходящими пакетами $nf; первых пакетов (SYN) до netfilter дошло ${os:-0}; ClientHello до netfilter дошло ${oc:-0}"
nb=$(wc -l < /tmp/z2kchk.binds | tr -d ' ')
early=$(awk '$1<3{n++} END{print n+0}' /tmp/z2kchk.binds)
minb=$(sort -n /tmp/z2kchk.binds | head -1 | cut -d' ' -f1)
echo "  потоков забрано железом за окно: $nb; самый ранний захват на исходящем пакете №${minb:--}; ЗАБРАНО ДО ClientHello (раньше 3-го пакета): $early"
echo "чтение: «забрано до ClientHello» должно быть 0 — тогда движок видит каждое рукопожатие; малая доля всех пакетов при закачках — норма, железо берёт поток после рукопожатия."
