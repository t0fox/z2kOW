#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/z2k-agh-openwrt.XXXXXX")
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/bin" "$T/z2k/platform/openwrt" "$T/state"
cp "$ROOT/files/z2k-agh-sync.sh" "$ROOT/files/z2k-agh-rewrites.awk" "$T/z2k/"
cp "$ROOT/platform/openwrt/insta-ip.sh" "$T/z2k/platform/openwrt/"
cp "$ROOT/files/z2k-insta-ip-refresh.sh" "$T/z2k/"

export SB="$T" Z2K_ROOT="$T/z2k" ZAPRET2_DIR="$T/z2k" Z2K_STATE="$T/state"
export Z2K_INSTA_HOSTS_FILE="$T/pins" Z2K_AGH_STATE_DIR="$T/state/agh-sync"
export Z2K_AGH_YAML="$T/AdGuardHome.yaml" Z2K_AGH_BIN="$T/bin/AdGuardHome" Z2K_AGH_INIT="$T/bin/service"
export Z2K_STUB_PATH="$T/bin"

cat > "$T/bin/pidof" <<'STUB'
#!/bin/sh
[ -f "$SB/running" ] && echo 12345
STUB
cat > "$T/bin/netstat" <<'STUB'
#!/bin/sh
echo 'udp 0 0 127.0.0.1:5300 0.0.0.0:* 12345/AdGuardHome'
STUB
cat > "$T/bin/busybox" <<'STUB'
#!/bin/sh
[ "$1" = nslookup ] || exit 1
case "$*" in *'-port=5300'*'-type=A'*'127.0.0.1'*) ;; *) exit 1 ;; esac
while [ "$#" -gt 2 ]; do shift; done
host=$1
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1:5300\n\nName: %s\n' "$host"
if [ -f "$SB/match" ]; then
    awk -v h="$host" '$2==h {print "Address: " $1}' "$SB/pins"
else
    echo 'Address: 9.9.9.9'
fi
STUB
cat > "$T/bin/service" <<'STUB'
#!/bin/sh
echo "$1" >> "$SB/service.log"
case "$1" in stop) rm -f "$SB/running" ;; start) touch "$SB/running" ;; *) exit 2 ;; esac
STUB
cat > "$T/bin/AdGuardHome" <<'STUB'
#!/bin/sh
case "$*" in *--check-config*) echo check >> "$SB/check.log"; [ ! -f "$SB/bad-config" ] ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin/"*

awk -F'"' '/^HOSTS=/ {n=split($2,h," "); for(i=1;i<=n;i++) print "85.192.60.175 "h[i]}' \
    "$T/z2k/z2k-insta-ip-refresh.sh" > "$T/pins"
printf '%s\n' '85.192.60.176 whatsapp.com' '85.192.60.176 g.whatsapp.net' >> "$T/pins"
cat > "$T/AdGuardHome.yaml" <<'YAML'
http:
  address: 127.0.0.1:3000
dns:
  port: 5300
  bind_hosts:
    - 127.0.0.1
filtering:
  rewrites:
    - domain: user.example
      answer: 192.0.2.9
YAML
touch "$T/running"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
run() { sh "$T/z2k/z2k-agh-sync.sh" "$1"; }

if run sync; then ok 'расхождение DNS создаёт принадлежащие rewrites'; else bad 'расхождение DNS создаёт принадлежащие rewrites'; fi
grep -q 'domain: instagram.com' "$T/AdGuardHome.yaml" && grep -q 'domain: whatsapp.com' "$T/AdGuardHome.yaml" \
    && grep -q 'domain: user.example' "$T/AdGuardHome.yaml" && ok 'синхронизируются пины Instagram и WhatsApp без потери чужой записи' \
    || bad 'синхронизируются пины Instagram и WhatsApp без потери чужой записи'
[ -s "$T/state/agh-sync/owned" ] && ok 'журнал владения хранится в постоянном состоянии OpenWrt' || bad 'журнал владения хранится в постоянном состоянии OpenWrt'

before=$(wc -l < "$T/service.log")
run sync
[ "$(wc -l < "$T/service.log")" = "$before" ] && ok 'повторная синхронизация не перезапускает службу без изменений' \
    || bad 'повторная синхронизация не перезапускает службу без изменений'

touch "$T/match"
run sync
grep -q 'domain: instagram.com' "$T/AdGuardHome.yaml" && ok 'собственные rewrites сохраняются при совпадающем ответе AGH' \
    || bad 'собственные rewrites сохраняются при совпадающем ответе AGH'

run remove
! grep -q 'domain: instagram.com\|domain: whatsapp.com\|domain: g.whatsapp.net' "$T/AdGuardHome.yaml" \
    && grep -q 'domain: user.example' "$T/AdGuardHome.yaml" \
    && ok 'удаление снимает только записи из журнала владения' \
    || bad 'удаление снимает только записи из журнала владения'

cp "$T/AdGuardHome.yaml" "$T/before-invalid"
touch "$T/bad-config"
if run sync >/dev/null 2>&1; then bad 'ошибка проверки YAML блокирует запись'; else
    cmp -s "$T/before-invalid" "$T/AdGuardHome.yaml" && ok 'ошибка проверки YAML блокирует запись' || bad 'ошибка проверки YAML блокирует запись'
fi

. "$ROOT/lib/release_map.sh"
[ "$(z2k_install_paths_for openwrt files/z2k-agh-sync.sh)" = /usr/lib/z2k/z2k-agh-sync.sh ] \
    && ok 'синхронизатор включён в карту OpenWrt' || bad 'синхронизатор включён в карту OpenWrt'
[ "$(z2k_install_paths_for openwrt files/z2k-agh-rewrites.awk)" = /usr/lib/z2k/z2k-agh-rewrites.awk ] \
    && ok 'YAML-редактор включён в карту OpenWrt' || bad 'YAML-редактор включён в карту OpenWrt'
grep -q 'z2k-agh-sync.sh" sync' "$ROOT/files/z2k-insta-ip-refresh.sh" \
    && ok 'обновление Insta-IP вызывает синхронизацию AdGuard Home' || bad 'обновление Insta-IP вызывает синхронизацию AdGuard Home'
grep -q 'z2k-agh-sync.sh" remove' "$ROOT/platform/openwrt/uninstall.sh" \
    && ok 'удаление z2k вызывает освобождение записей AdGuard Home' || bad 'удаление z2k вызывает освобождение записей AdGuard Home'

mkdir -p "$T/payload"
if sh "$ROOT/scripts/openwrt/stage-common-payload.sh" "$ROOT" "$T/payload" >/dev/null \
    && cmp -s "$ROOT/files/z2k-agh-sync.sh" "$T/payload/usr/lib/z2k/z2k-agh-sync.sh" \
    && cmp -s "$ROOT/files/z2k-agh-rewrites.awk" "$T/payload/usr/lib/z2k/z2k-agh-rewrites.awk"; then
    ok 'оба файла попадают в полный OpenWrt release payload без изменений'
else
    bad 'оба файла попадают в полный OpenWrt release payload без изменений'
fi

printf '\nПРОЙДЕНО: %s\nОШИБОК: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
