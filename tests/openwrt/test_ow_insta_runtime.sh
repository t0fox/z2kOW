#!/bin/sh
. "$(dirname "$0")/helper.sh"
_t_plan "ow-insta-runtime"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-insta.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/etc/state"
export UCI_TEST_DB="$T/uci.db" UCI_TEST_LOG="$T/uci.log" DNSMASQ_TEST_LOG="$T/dnsmasq.log"
export INSTA_DOH_TEST_LOG="$T/doh.log"
export Z2K_INSTA_HOSTS_FILE="$T/etc/state/insta-hosts"
export Z2K_INSTA_UCI_MARKER="$T/etc/state/.insta-addnhosts-owned"
export Z2K_INSTA_DNSMASQ_INIT="$T/dnsmasq-init"
export Z2K_INSTA_CACHE_FILE="$T/etc/state/insta-ip-candidates"
export Z2K_INSTA_NOW=1000
export PATH="$T/bin:$PATH"
printf "dhcp.cfg0001='dnsmasq'\ndhcp.@dnsmasq[0].nohosts='0'\n" > "$UCI_TEST_DB"

cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$UCI_TEST_LOG"
case "$*" in
    "-q show dhcp.@dnsmasq[0]") grep -q "dnsmasq" "$UCI_TEST_DB" ;;
    "-q show dhcp") cat "$UCI_TEST_DB" ;;
    "commit dhcp") exit 0 ;;
    "add_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#dhcp.@dnsmasq[0].addnhosts=}
        printf "dhcp.@dnsmasq[0].addnhosts='%s'\n" "$_path" >> "$UCI_TEST_DB"
        ;;
    "del_list dhcp.@dnsmasq[0].addnhosts="*)
        _path=${2#dhcp.@dnsmasq[0].addnhosts=}
        awk -v path="$_path" 'index($0, ".addnhosts=\047" path "\047") == 0' "$UCI_TEST_DB" > "$UCI_TEST_DB.new"
        mv "$UCI_TEST_DB.new" "$UCI_TEST_DB"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$Z2K_INSTA_DNSMASQ_INIT" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_TEST_LOG"
[ "${1:-}" = restart ]
STUB
chmod 0755 "$T/bin/uci" "$Z2K_INSTA_DNSMASQ_INIT"

. "$REPO/platform/openwrt/insta-ip.sh"
z2k_ow_insta_prepare || _t_bad "зарегистрировать файл dnsmasq, созданный адаптером"
assert_contains "dnsmasq addnhosts path is persistent and scoped" "$UCI_TEST_DB" "$Z2K_INSTA_HOSTS_FILE"
assert_file "adapter records its own UCI reference for uninstall" "$Z2K_INSTA_UCI_MARKER"

# Локальный OpenWrt resolver опрашивает несколько независимых DoH endpoints,
# сохраняет A-записи с TTL и использует ещё не протухший кэш при отказе сети.
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
url=
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || exit 2
printf '%s\n' "$url" >> "$INSTA_DOH_TEST_LOG"
case "$url" in
    *cloudflare-dns.com*) printf '{"Answer":[{"name":"instagram.com","type":1,"TTL":120,"data":"157.240.1.1"}]}' > "$out" ;;
    *dns.google*) printf '{"Answer":[{"name":"instagram.com","type":1,"TTL":300,"data":"157.240.1.2"}]}' > "$out" ;;
    *dns.adguard-dns.com*) printf '{"Answer":[{"name":"instagram.com","type":1,"TTL":240,"data":"157.240.1.3"}]}' > "$out" ;;
    *) exit 7 ;;
esac
STUB
cat > "$T/bin/jsonfilter" <<'STUB'
#!/bin/sh
file= expr=
while [ "$#" -gt 0 ]; do
    case "$1" in -i) file="$2"; shift 2 ;; -e) expr="$2"; shift 2 ;; *) shift ;; esac
done
case "$expr" in
    '@.Answer[*].data') sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' "$file" ;;
    '@.Answer[*].TTL') sed -n 's/.*"TTL":\([0-9]*\).*/\1/p' "$file" ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/paste" <<'STUB'
#!/bin/sh
exit 127
STUB
chmod 0755 "$T/bin/curl" "$T/bin/jsonfilter" "$T/bin/paste"
_dns_candidates=$(z2k_ow_insta_resolve_hosts instagram.com)
assert_contains "локальный резолвер возвращает A-кандидаты Cloudflare" /dev/stdin '157.240.1.1' <<EOF_CANDIDATES
$_dns_candidates
EOF_CANDIDATES
assert_contains "локальный резолвер объединяет независимые DNS-ответы" /dev/stdin '157.240.1.2' <<EOF_CANDIDATES
$_dns_candidates
EOF_CANDIDATES
assert_contains "локальный резолвер добавляет третий независимый DNS-ответ" /dev/stdin '157.240.1.3' <<EOF_CANDIDATES
$_dns_candidates
EOF_CANDIDATES
assert_contains "Cloudflare DoH использует поддерживаемый путь JSON API" "$INSTA_DOH_TEST_LOG" '/dns-query?name='
assert_contains "кэш хранит срок действия и источник ответа" "$Z2K_INSTA_CACHE_FILE" 'cloudflare-dns.com'
assert_contains "кэш хранит TTL каждой записи" "$Z2K_INSTA_CACHE_FILE" '120'

# Успешное обновление одного домена не должно вытеснять ещё годный кэш
# другого домена, для которого все DoH endpoints временно недоступны.
printf '%s\n' '900 www.instagram.com 157.240.2.1 120 cloudflare-dns.com' >> "$Z2K_INSTA_CACHE_FILE"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
url=
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *"name=instagram.com&type=A"*) printf '{"Answer":[{"name":"instagram.com","type":1,"TTL":120,"data":"157.240.1.4"}]}' > "$out" ;;
    *) exit 7 ;;
esac
STUB
chmod 0755 "$T/bin/curl"
_partial_candidates=$(z2k_ow_insta_resolve_hosts instagram.com www.instagram.com)
if printf '%s\n' "$_partial_candidates" \
    | awk -F '\t' '$1=="www.instagram.com" && $2=="157.240.2.1" {found=1} END {exit !found}'; then
    _t_ok
else
    _t_bad "при отказе DNS второго домена возвращается кэш в пределах grace-period"
fi
assert_contains "успешное обновление первого домена сохраняет кэш второго" "$Z2K_INSTA_CACHE_FILE" '900 www.instagram.com 157.240.2.1'
cat > "$Z2K_INSTA_CACHE_FILE" <<'CACHE'
1120 instagram.com 157.240.1.1 120 cloudflare-dns.com
1300 instagram.com 157.240.1.2 300 dns.google
1240 instagram.com 157.240.1.3 240 dns.adguard-dns.com
900 www.instagram.com 157.240.2.1 120 cloudflare-dns.com
CACHE

cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
exit 7
STUB
chmod 0755 "$T/bin/curl"
_cached_candidates=$(z2k_ow_insta_resolve_hosts instagram.com)
assert_contains "при сбое DNS используются ещё действующие записи кэша" /dev/stdin '157.240.1.1' <<EOF_CACHED
$_cached_candidates
EOF_CACHED

export Z2K_INSTA_NOW=200000
if z2k_ow_insta_resolve_hosts instagram.com >/dev/null 2>&1; then
    _t_bad "expired candidates outside stale grace are not returned"
else
    _t_ok
fi

# Даже если каждый отдельный DoH timeout соблюдён, последовательные попытки
# на всех управляемых hostname не должны занимать несколько минут.
cat > "$Z2K_INSTA_CACHE_FILE" <<'CACHE'
4102444800 instagram.com 157.240.1.1 120 cloudflare-dns.com
4102444800 www.instagram.com 157.240.1.2 120 cloudflare-dns.com
CACHE
_deadline_cache_hash=$(sha256sum "$Z2K_INSTA_CACHE_FILE" | awk '{print $1}')
unset Z2K_INSTA_NOW
_path_before_deadline=$PATH
export T
printf '0\n' > "$T/date.calls"
cat > "$T/bin/date" <<'STUB'
#!/bin/sh
n=$(cat "$T/date.calls")
n=$((n + 1))
printf '%s\n' "$n" > "$T/date.calls"
case "$n" in
    1) echo 100 ;;
    2) echo 101 ;;
    3) echo 102 ;;
    4) echo 103 ;;
    5) echo 104 ;;
    *) echo 106 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$INSTA_DOH_TEST_LOG"
exit 7
STUB
chmod 0755 "$T/bin/date" "$T/bin/curl"
export Z2K_INSTA_DOH_TOTAL_TIMEOUT=5
: > "$INSTA_DOH_TEST_LOG"
_deadline_candidates=$(z2k_ow_insta_resolve_hosts instagram.com www.instagram.com 2>/dev/null)
if [ -n "$_deadline_candidates" ]; then
    printf '%s\n' "$_deadline_candidates" | grep -q 'instagram.com[[:space:]]157.240.1.1' \
        && _t_ok || _t_bad "до deadline возвращён кэш первого hostname"
    printf '%s\n' "$_deadline_candidates" | grep -q 'www.instagram.com[[:space:]]157.240.1.2' \
        && _t_ok || _t_bad "после deadline сохранён кэш оставшихся hostname"
    _dns_attempts=$(wc -l < "$INSTA_DOH_TEST_LOG" | tr -d ' ')
    [ "$_dns_attempts" -le 2 ] \
        && _t_ok \
        || _t_bad "общий DoH deadline останавливает последовательные попытки"
    grep -F -- '--max-time 2 ' "$INSTA_DOH_TEST_LOG" >/dev/null \
        && _t_ok \
        || _t_bad "последний curl ограничен оставшимся временем deadline"
    _deadline_cache_after=$(sha256sum "$Z2K_INSTA_CACHE_FILE" | awk '{print $1}')
    assert_eq "отказ resolver не меняет кэш" "$_deadline_cache_hash" "$_deadline_cache_after"
else
    _t_bad "при отказе DoH возвращается допустимый кэш"
fi
unset Z2K_INSTA_DOH_TOTAL_TIMEOUT
PATH=$_path_before_deadline
export PATH

printf '# сохранённая настройка\n192.0.2.9 example.net\n192.0.2.8 instagram.com\n' > "$Z2K_INSTA_HOSTS_FILE"
z2k_ow_insta_replace_hosts instagram.com '57.144.245.32 instagram.com' \
    || _t_bad "атомарная замена сохраняет несвязанные записи"
assert_contains "атомарная замена сохраняет комментарии" "$Z2K_INSTA_HOSTS_FILE" '# сохранённая настройка'
assert_contains "атомарная замена сохраняет пользовательские домены" "$Z2K_INSTA_HOSTS_FILE" '192.0.2.9 example.net'
assert_contains "атомарная замена устанавливает выбранный адрес" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32 instagram.com'
assert_not_contains "атомарная замена удаляет старый адрес" "$Z2K_INSTA_HOSTS_FILE" '192\.0\.2\.8 instagram\.com'
cp -p "$Z2K_INSTA_HOSTS_FILE" "$T/insta-before-restore"
printf '192.0.2.7 broken.example\n' > "$Z2K_INSTA_HOSTS_FILE"
z2k_ow_insta_restore_hosts "$T/insta-before-restore" || _t_bad "восстановить предыдущий dnsmasq host-файл"
assert_contains "откат восстанавливает предыдущую запись домена" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32 instagram.com'

z2k_ow_insta_add_host instagram.com 57.144.245.32 || _t_bad "add Instagram address"
z2k_ow_insta_add_host www.whatsapp.com 57.144.245.32 || _t_bad "add WhatsApp address"
assert_contains "host include uses dnsmasq /etc/hosts syntax" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32 instagram.com'
assert_contains "show-config preserves upstream host/IP field order" "$Z2K_INSTA_HOSTS_FILE" '57.144.245.32'
_config=$(z2k_ow_insta_show_running_config)
case "$_config" in
    *"ip host instagram.com 57.144.245.32"*"ip host www.whatsapp.com 57.144.245.32"*) _t_ok ;;
    *) _t_bad "OpenWrt records translate to upstream ip host lines" ;;
esac

z2k_ow_insta_remove_host instagram.com 57.144.245.32 || _t_bad "remove stale Instagram address"
assert_not_contains "remove affects only the exact managed hostname" "$Z2K_INSTA_HOSTS_FILE" 'instagram\.com'
assert_contains "unrelated managed hostname survives removal" "$Z2K_INSTA_HOSTS_FILE" 'www.whatsapp.com'
z2k_ow_insta_commit || _t_bad "сохранить записи и перезапустить dnsmasq"
assert_contains "изменённые записи перезапускают dnsmasq" "$DNSMASQ_TEST_LOG" 'restart'

z2k_ow_insta_uninstall || _t_bad "remove only the UCI reference owned by z2k"
assert_not_contains "uninstall removes the z2k addnhosts reference" "$UCI_TEST_DB" 'insta-hosts'
[ ! -e "$Z2K_INSTA_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes the owned host file"
[ ! -e "$Z2K_INSTA_UCI_MARKER" ] && _t_ok || _t_bad "uninstall clears the ownership marker"

_t_done
