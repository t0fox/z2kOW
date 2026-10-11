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
[ "${1:-}" = reload ]
STUB
chmod 0755 "$T/bin/uci" "$Z2K_INSTA_DNSMASQ_INIT"

. "$REPO/platform/openwrt/insta-ip.sh"
z2k_ow_insta_prepare || _t_bad "register the owned dnsmasq host file"
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
z2k_ow_insta_commit || _t_bad "commit records and reload dnsmasq"
assert_contains "changed records reload dnsmasq" "$DNSMASQ_TEST_LOG" 'reload'

z2k_ow_insta_uninstall || _t_bad "remove only the UCI reference owned by z2k"
assert_not_contains "uninstall removes the z2k addnhosts reference" "$UCI_TEST_DB" 'insta-hosts'
[ ! -e "$Z2K_INSTA_HOSTS_FILE" ] && _t_ok || _t_bad "uninstall removes the owned host file"
[ ! -e "$Z2K_INSTA_UCI_MARKER" ] && _t_ok || _t_bad "uninstall clears the ownership marker"

_t_done
