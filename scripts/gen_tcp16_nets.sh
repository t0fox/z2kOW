#!/bin/sh
# Собрать карту «сеть → AS» для мишеней проверки на блок по объёму.
#
# ЗАЧЕМ ОГРУБЛЕНИЕ ДО /16. Точных префиксов у этих 43 AS около 52 тысяч (v4),
# в роутер такое не кладут. Уникальных /16 среди них — 6098, это 47 КБ и
# копеечная таблица в памяти. Цена огрубления: имя достанется и соседям по /16,
# которым оно не нужно. Замерено 30.08.2026 — лишний фейк рабочим сайтам не
# мешает (linode, cdn77, aws, scaleway не изменились ни на байт), так что цена
# приемлемая, а выигрыш — мы перестаём ставить имя вообще всему пулу.
#
# Запускается НЕ на роутере, а у нас, и результат коммитится. Источник —
# RIPEstat (публичный, без ключей).
#
#   sh scripts/gen_tcp16_nets.sh > files/lists/tcp16_nets.txt
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGETS="$ROOT/files/lists/tcp16_targets.txt"

ASNS=$(awk -F'\t' '$0 !~ /^#/ && NF>=6 { print $2 }' "$TARGETS" | sort -un)

printf '# Карта «сеть → AS» для класса «блок по объёму соединения».\n'
printf '#\n'
printf '# Формат: <asn><TAB><префикс>. v4 огрублены до /16, v6 до /32 — точных\n'
printf '# префиксов у этих AS около 52 тысяч, и в роутер они не помещаются.\n'
printf '#\n'
printf '# Файл отвечает на ОДИН вопрос: принадлежит ли адрес назначения той AS,\n'
printf '# где проба нашла блок. Список AS берётся из lists/tcp16_targets.txt,\n'
printf '# префиксы — из RIPEstat. Пересобирать: scripts/gen_tcp16_nets.sh\n'
printf '# Снимок: %s\n' "$(date +%F)"

for as in $ASNS; do
    curl -s --max-time 30 "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS$as" \
    | python3 -c '
import json,sys,ipaddress
asn=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v4=set(); v6=set()
# Короткие префиксы разворачиваем во все покрытые блоки /16 или /32;
# прежнее огрубление оставляло только первый блок. Ограничение расширения
# IPv6 не даёт развернуть один большой префикс в десятки тысяч записей.
MAXEXP=256
for x in d.get("data",{}).get("prefixes",[]):
    try: n=ipaddress.ip_network(x["prefix"], strict=False)
    except Exception: continue
    if n.version==4 and n.prefixlen>=8:
        if n.prefixlen<16:
            for s in n.subnets(new_prefix=16): v4.add(str(s))
        else:
            v4.add(str(ipaddress.ip_network((int(n.network_address)>>16<<16, 16))))
    elif n.version==6 and n.prefixlen>=16:
        if n.prefixlen<32 and (1<<(32-n.prefixlen))<=MAXEXP:
            for s in n.subnets(new_prefix=32): v6.add(str(s))
        else:
            v6.add(str(ipaddress.ip_network((int(n.network_address)>>96<<96, 32))))
for p in sorted(v4)+sorted(v6): print(asn+"\t"+p)
' "$as"
done
