#!/bin/sh
# Fresh-install bootstrap. It verifies the sole controlled manifest and then
# invokes the same install_release(tag) transaction used by every update.
set -eu

die() { printf 'z2kOW installer: %s\n' "$*" >&2; exit 1; }
[ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запустите установщик от root"
[ -r /etc/openwrt_release ] || die "это не OpenWrt"
. /etc/openwrt_release
[ "${DISTRIB_ID:-}" = OpenWrt ] || die "поддерживается только OpenWrt"
command -v apk >/dev/null 2>&1 || die "нужен OpenWrt с apk для системных зависимостей"
apk add ca-bundle openssl-util jsonfilter || die "не удалось поставить системные средства проверки подписи"

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 30 -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 -o "$2" "$1"; }
else
    die "нужен wget или curl"
fi

TMP="${TMPDIR:-/tmp}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP") || die "не удалось создать временный каталог"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MANIFEST="$TMP/UPDATES.json"
SIGNATURE="$TMP/UPDATES.json.sig"
PUBKEY="$TMP/z2k-update-pub.pem"
BASE="https://raw.githubusercontent.com/t0fox/z2kOW/main"
download "$BASE/UPDATES.json" "$MANIFEST" || die "не удалось получить controlled UPDATES.json"
download "$BASE/UPDATES.json.sig" "$SIGNATURE" || die "нет подписи controlled UPDATES.json; релиз не опубликован"
cat > "$PUBKEY" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAHInDNbRMriWoRhLSW0t6AWkrpayIBzM9oakfZuB3/1Y=
-----END PUBLIC KEY-----
EOF
openssl pkeyutl -verify -rawin -pubin -inkey "$PUBKEY" -in "$MANIFEST" -sigfile "$SIGNATURE" \
    >/dev/null 2>&1 || die "подпись controlled UPDATES.json неверна"

TMP_DIR="${TMPDIR:-/tmp}/z2kow-install.$$"
WEBPANEL_DEP_SEED=".z2k-webpanel-bootstrap-deps"
WEBPANEL_DEP_SEED_ACTIVE=0
CLEANUP_DONE=0
cleanup() {
    [ "$CLEANUP_DONE" = "0" ] || return 0
    CLEANUP_DONE=1
    trap '' HUP INT TERM
    if [ "$WEBPANEL_DEP_SEED_ACTIVE" = "1" ]; then
        apk del "$WEBPANEL_DEP_SEED" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
(umask 077 && mkdir "$TMP_DIR") || die "не удалось создать временный каталог"
DOWNLOADED_KEY="$TMP_DIR/z2k-feed.pem"
download "$KEY_URL" "$DOWNLOADED_KEY" \
    || die "не удалось скачать production public key с immutable GitHub commit"
[ -s "$DOWNLOADED_KEY" ] || die "production public key пуст"
DOWNLOADED_FINGERPRINT="$(key_fingerprint "$DOWNLOADED_KEY" || true)"
[ "$DOWNLOADED_FINGERPRINT" = "$EXPECTED_FEED_KEY_SHA256" ] \
    || die "production feed key fingerprint mismatch; установка остановлена"

ARTIFACT="$TMP/openwrt-rootfs.tar.gz"
download "$_url" "$ARTIFACT" || die "не удалось скачать rootfs для $_tag"
[ "$(wc -c < "$ARTIFACT" | tr -d ' \t\r\n')" = "$_size" ] || die "размер rootfs не совпал"
[ "$(sha256sum "$ARTIFACT" | awk '{print $1}')" = "$_sha" ] || die "SHA-256 rootfs не совпал"

# Extract only the installer engine needed to enter the common deployment
# path. The actual release is applied from the complete verified archive.
mkdir -p "$TMP/engine"
tar -xzf "$ARTIFACT" -C "$TMP/engine" \
    usr/lib/z2k/lib/utils.sh \
    usr/lib/z2k/lib/auto_update.sh \
    usr/lib/z2k/platform/openwrt/paths.sh \
    usr/lib/z2k/platform/openwrt/env.sh \
    usr/lib/z2k/platform/openwrt/manifest.sh \
    usr/lib/z2k/platform/openwrt/release.sh \
    usr/lib/z2k/platform/openwrt/bootstrap.sh \
    usr/lib/z2k/platform/openwrt/owned-paths.txt \
    usr/sbin/install_release \
    opt/zapret2/etc/z2k-update-pub.pem || die "installer engine missing from complete rootfs"

apk update || die "apk update завершился ошибкой; пакеты не установлены"
# Lighttpd is used only as the private :8088 runtime. OpenWrt's APK default
# post-install hook starts every newly installed /etc/init.d service, including
# stock lighttpd on :80. Install its runtime dependency closure without package
# scripts, then let the regular z2k package transaction run its own hooks.
WEBPANEL_DEP_SEED_ACTIVE=1
apk --no-scripts add --upgrade --virtual "$WEBPANEL_DEP_SEED" \
    lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias \
    || die "не удалось подготовить Lighttpd runtime без запуска штатного сервиса"
if apk info -e z2k-adapter >/dev/null 2>&1 \
   && apk info -e z2k-webpanel >/dev/null 2>&1; then
    apk add --upgrade z2k-adapter z2k-webpanel \
        || die "не удалось обновить z2k-adapter и z2k-webpanel"
else
    apk add z2k-adapter z2k-webpanel \
        || die "не удалось установить z2k-adapter и z2k-webpanel"
fi

# Package post-install hooks own enable/start. Poll their health without
# duplicating that lifecycle.
CORE_OK=0
attempt=0
while [ "$attempt" -lt 10 ]; do
    if "$ROOT_SYS/etc/init.d/z2k" status >/dev/null 2>&1 \
       && pidof nfqws2 >/dev/null 2>&1; then
        CORE_OK=1
        break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] && sleep 1
done
[ "$CORE_OK" = "1" ] || die "core service/runtime is not running (z2k or nfqws2 health check failed)"

LAN_IP="$(ip -4 -o addr show dev br-lan 2>/dev/null \
    | awk '$3 == "inet" { sub(/\/.*/, "", $4); if ($4 != "127.0.0.1") { print $4; exit } }' || true)"
if [ -z "$LAN_IP" ] && command -v uci >/dev/null 2>&1; then
    LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
fi
[ -n "$LAN_IP" ] || die "не удалось определить LAN IPv4 через ip/uci"

PANEL_OK=0
attempt=0
while [ "$attempt" -lt 10 ]; do
    if "$ROOT_SYS/etc/init.d/z2k-webpanel" running >/dev/null 2>&1 \
       && http_check "http://$LAN_IP:8088/"; then
        PANEL_OK=1
        break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] && sleep 1
done
[ "$PANEL_OK" = "1" ] || die "webpanel service или HTTP health check на порту 8088 не прошёл"

[ -x "$ROOT_SYS/usr/bin/z2kow" ] || die "package не установил /usr/bin/z2kow"
"$ROOT_SYS/usr/bin/z2kow" record || die "не удалось записать product-tag после успешной health check"

package_version() {
    _line="$(apk list --installed "$1" 2>/dev/null | head -1)"
    case "$_line" in
        "$1"-*) _value="${_line#"$1"-}"; printf '%s\n' "${_value%% *}" ;;
        *) return 1 ;;
    esac
}
CORE_VERSION="$(package_version z2k-adapter || true)"
PANEL_VERSION="$(package_version z2k-webpanel || true)"
[ -n "$CORE_VERSION" ] && [ -n "$PANEL_VERSION" ] \
    || die "не удалось прочитать установленные package versions"

printf 'z2kOW установлен\n'
printf 'версия: %s\n' "$CORE_VERSION"
printf 'core: running\n'
printf 'webpanel: running\n'
printf 'панель: http://%s:8088\n' "$LAN_IP"
