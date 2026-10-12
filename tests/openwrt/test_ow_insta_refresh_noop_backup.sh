#!/bin/sh
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-insta-noop.XXXXXX")"
PASS=0
FAIL=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT HUP INT TERM
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

mkdir -p "$T/bin" "$T/state" "$T/lists"
cp "$REPO/files/lists/meta-ranges.txt" "$T/lists/meta-ranges.txt"
sed "s|/tmp/z2k-log|$T/logroot|g" \
    "$REPO/files/z2k-insta-ip-refresh.sh" > "$T/refresh.sh"

cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out= url= http_code=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w) http_code=1; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *'?name='*)
        [ -n "$out" ] || exit 2
        printf '{"Answer":[{"type":1,"TTL":300,"data":"%s"}]}\n' \
            "${INSTA_TEST_IP:-57.144.245.32}" > "$out"
        ;;
    https://*)
        [ "$http_code" = 1 ] || exit 2
        printf '200'
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/jsonfilter" <<'STUB'
#!/bin/sh
expr=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -e) expr="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$expr" in
    '@.Answer[*].data') printf '%s\n' "${INSTA_TEST_IP:-57.144.245.32}" ;;
    '@.Answer[*].TTL') printf '300\n' ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
case "$*" in
    '-q show dhcp.@dnsmasq[0]') printf "dhcp.@dnsmasq[0].nohosts='0'\n" ;;
    '-q show dhcp') printf "dhcp.@dnsmasq[0].addnhosts='%s'\n" "$Z2K_INSTA_HOSTS_FILE" ;;
    'add_list '*) exit 0 ;;
    'commit dhcp') exit 0 ;;
    *) exit 2 ;;
esac
STUB
cat > "$T/bin/dnsmasq-init" <<'STUB'
#!/bin/sh
[ "${1:-}" = restart ] || exit 1
[ "${DNSMASQ_FAIL_RESTART:-0}" != 1 ]
STUB
chmod 0755 "$T/bin/curl" "$T/bin/jsonfilter" "$T/bin/uci" "$T/bin/dnsmasq-init"

HOSTS='instagram.com www.instagram.com graph.instagram.com api.instagram.com instagram.c10r.instagram.com static.cdninstagram.com scontent.cdninstagram.com web.whatsapp.com www.whatsapp.com scontent.whatsapp.net graph.whatsapp.com v.whatsapp.com'
for host in $HOSTS; do printf '57.144.245.32 %s\n' "$host"; done > "$T/state/insta-hosts"
cp "$T/state/insta-hosts" "$T/state/before"
: > "$T/config"

if Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" ZAPRET2_DIR="$T" \
    CONFIG_FILE="$T/config" LOG_FILE="$T/refresh.log" Z2K_STUB_PATH="$T/bin" \
    Z2K_INSTA_HOSTS_FILE="$T/state/insta-hosts" \
    Z2K_INSTA_UCI_MARKER="$T/state/uci-owned" Z2K_INSTA_UCI_BIN="$T/bin/uci" \
    Z2K_INSTA_DNSMASQ_INIT="$T/bin/dnsmasq-init" Z2K_INSTA_CACHE_FILE="$T/state/cache" \
    Z2K_IP_PROBE_TIMEOUT=1 Z2K_IP_PROBE_MAX_TRY=1 Z2K_IP_PROBE_KEEP=1 \
    sh "$T/refresh.sh"; then
    ok "refresh без изменений завершился успешно"
else
    bad "refresh без изменений завершился с ошибкой"
fi

if cmp -s "$T/state/before" "$T/state/insta-hosts"; then
    ok "refresh без изменений сохранил исходные записи"
else
    bad "refresh без изменений изменил исходные записи"
fi
if find "$T/state" -name 'insta-hosts.z2k-backup.*' | grep -q .; then
    bad "после no-op refresh остался временный backup"
else
    ok "после no-op refresh временный backup удалён"
fi

if INSTA_TEST_IP=57.144.245.33 DNSMASQ_FAIL_RESTART=1 \
    Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" ZAPRET2_DIR="$T" \
    CONFIG_FILE="$T/config" LOG_FILE="$T/refresh.log" Z2K_STUB_PATH="$T/bin" \
    Z2K_INSTA_HOSTS_FILE="$T/state/insta-hosts" \
    Z2K_INSTA_UCI_MARKER="$T/state/uci-owned" Z2K_INSTA_UCI_BIN="$T/bin/uci" \
    Z2K_INSTA_DNSMASQ_INIT="$T/bin/dnsmasq-init" Z2K_INSTA_CACHE_FILE="$T/state/cache" \
    Z2K_IP_PROBE_TIMEOUT=1 Z2K_IP_PROBE_MAX_TRY=1 Z2K_IP_PROBE_KEEP=1 \
    sh "$T/refresh.sh"; then
    ok "refresh с отказом restart завершился с контролируемым восстановлением"
else
    bad "refresh с отказом restart завершился с ошибкой"
fi
if cmp -s "$T/state/before" "$T/state/insta-hosts"; then
    ok "отказ restart восстановил полный предыдущий файл"
else
    bad "отказ restart повредил предыдущий файл"
fi
grep -q 'previous host records restored' "$T/refresh.log" \
    && ok "журнал отметил восстановление после отказа" \
    || bad "в журнале нет записи о восстановлении"
if find "$T/state" -name 'insta-hosts.z2k-backup.*' | grep -q .; then
    bad "после rollback остался временный backup"
else
    ok "после rollback временный backup удалён"
fi

cp "$T/state/before" "$T/state/insta-hosts"
cat > "$T/bin/cp" <<'STUB'
#!/bin/sh
if [ "${1:-}" = -p ] && [ "$#" -eq 3 ]; then
    case "$2" in *.z2k-backup.*) exit 1 ;; esac
fi
exec /bin/cp "$@"
STUB
chmod 0755 "$T/bin/cp"
if INSTA_TEST_IP=57.144.245.34 DNSMASQ_FAIL_RESTART=1 \
    Z2K_PLATFORM=openwrt Z2K_ROOT="$REPO" ZAPRET2_DIR="$T" \
    CONFIG_FILE="$T/config" LOG_FILE="$T/restore-fail.log" Z2K_STUB_PATH="$T/bin" \
    Z2K_INSTA_HOSTS_FILE="$T/state/insta-hosts" \
    Z2K_INSTA_UCI_MARKER="$T/state/uci-owned" Z2K_INSTA_UCI_BIN="$T/bin/uci" \
    Z2K_INSTA_DNSMASQ_INIT="$T/bin/dnsmasq-init" Z2K_INSTA_CACHE_FILE="$T/state/cache" \
    Z2K_IP_PROBE_TIMEOUT=1 Z2K_IP_PROBE_MAX_TRY=1 Z2K_IP_PROBE_KEEP=1 \
    sh "$T/refresh.sh"; then
    _refresh_rc=0
else
    _refresh_rc=$?
fi
if [ "$_refresh_rc" -ne 0 ]; then
    ok "ошибка восстановления возвращена вызывающему процессу"
else
    bad "ошибка восстановления не должна сообщаться как успешный refresh"
fi
grep -q 'previous host records could not be restored' "$T/restore-fail.log" \
    && ok "сценарий дошёл до отказа восстановления" \
    || bad "сценарий не воспроизвёл отказ восстановления"
_backup=$(find "$T/state" -name 'insta-hosts.z2k-backup.*' | head -1)
if [ -n "$_backup" ] && cmp -s "$T/state/before" "$_backup"; then
    ok "если восстановление не удалось, исходный backup сохранён для повторной попытки"
else
    bad "если восстановление не удалось, исходный backup должен остаться целым"
fi
if grep -q 'conntrack flushed for old IPs' "$T/restore-fail.log"; then
    bad "conntrack не должен очищаться при неподтверждённом rollback"
else
    ok "conntrack не очищается при неподтверждённом rollback"
fi

printf '\ntest_ow_insta_refresh_noop_backup.sh: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
