#!/bin/sh
# z2kOW production bootstrap. release-assets.py renders the two pinned values.
set -eu

ROOT_SYS="/"
# Hash of the exact PEM file, embedded by release-assets.py. Minimal OpenWrt
# images need sha256sum but do not necessarily include base64 or OpenSSL.
EXPECTED_FEED_KEY_SHA256="@Z2K_FEED_KEY_SHA256@"
KEY_SOURCE_SHA="@Z2K_KEY_SOURCE_SHA@"
FEED_URL="https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb"
FEED_ENTRY="ndx $FEED_URL"
KEY_URL="https://raw.githubusercontent.com/t0fox/z2kOW/$KEY_SOURCE_SHA/package/openwrt/keys/z2k-feed.pem"
KEY_PATH="$ROOT_SYS/etc/apk/keys/z2k-feed.pem"
REPOSITORY_PATH="$ROOT_SYS/etc/apk/repositories.d/z2kow.list"
SUPPORTED_RELEASE="25.12.5"
SUPPORTED_TARGET="mediatek/filogic"
SUPPORTED_ARCH="aarch64_cortex-a53"

die() {
    printf 'z2kOW installer: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u 2>/dev/null || true)" = "0" ] || die "запустите installer от root"
[ -s "$ROOT_SYS/etc/openwrt_release" ] || die "это не OpenWrt: нет /etc/openwrt_release"
# shellcheck disable=SC1090
. "$ROOT_SYS/etc/openwrt_release"
[ "${DISTRIB_ID:-}" = "OpenWrt" ] || die "поддерживается только OpenWrt"
[ "${DISTRIB_RELEASE:-}" = "$SUPPORTED_RELEASE" ] \
    || die "нужен OpenWrt $SUPPORTED_RELEASE, обнаружен ${DISTRIB_RELEASE:-unknown}"
[ "${DISTRIB_TARGET:-}" = "$SUPPORTED_TARGET" ] \
    || die "неподдерживаемый target: ${DISTRIB_TARGET:-unknown}; нужен $SUPPORTED_TARGET"
[ "${DISTRIB_ARCH:-}" = "$SUPPORTED_ARCH" ] \
    || die "неподдерживаемая APK architecture: ${DISTRIB_ARCH:-unknown}; нужен $SUPPORTED_ARCH"

command -v apk >/dev/null 2>&1 || die "не найден apk package manager"
apk --version >/dev/null 2>&1 || die "apk не запускается"
command -v sha256sum >/dev/null 2>&1 || die "нужен sha256sum для проверки pinned ключа"
case "$EXPECTED_FEED_KEY_SHA256" in
    ''|*@*) die "release installer не содержит production key fingerprint" ;;
esac
case "$KEY_SOURCE_SHA" in
    *[!0-9a-f]*|'') die "release installer не содержит immutable source SHA" ;;
esac
[ "${#KEY_SOURCE_SHA}" -eq 40 ] || die "immutable key source SHA malformed"

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 30 -O "$2" "$1"; }
    http_check() { wget -q -T 5 -O /dev/null "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 -o "$2" "$1"; }
    http_check() { curl --fail --location --silent --show-error --connect-timeout 3 --max-time 5 -o /dev/null "$1"; }
else
    die "нужен HTTPS downloader: wget или curl"
fi

key_fingerprint() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

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

if [ -e "$KEY_PATH" ]; then
    EXISTING_FINGERPRINT="$(key_fingerprint "$KEY_PATH" || true)"
    [ "$EXISTING_FINGERPRINT" = "$EXPECTED_FEED_KEY_SHA256" ] \
        || die "$KEY_PATH уже содержит другой ключ; доверие не будет заменено автоматически"
else
    mkdir -p "$ROOT_SYS/etc/apk/keys" || die "не удалось создать каталог APK keys"
    cp "$DOWNLOADED_KEY" "$TMP_DIR/z2k-feed.pem.new" || die "не удалось подготовить APK key"
    chmod 0644 "$TMP_DIR/z2k-feed.pem.new" 2>/dev/null || true
    mv "$TMP_DIR/z2k-feed.pem.new" "$KEY_PATH" || die "не удалось установить APK key"
fi

if [ -e "$REPOSITORY_PATH" ]; then
    if grep -qxF "$FEED_ENTRY" "$REPOSITORY_PATH"; then
        [ "$(wc -l < "$REPOSITORY_PATH" | tr -d ' \t\r\n')" = "1" ] \
            || die "$REPOSITORY_PATH содержит дополнительные записи; файл оставлен без изменений"
    elif [ -s "$REPOSITORY_PATH" ]; then
        die "$REPOSITORY_PATH уже содержит другую конфигурацию; файл оставлен без изменений"
    else
        printf '%s\n' "$FEED_ENTRY" > "$TMP_DIR/z2kow.list" \
            || die "не удалось подготовить repository entry"
        mv "$TMP_DIR/z2kow.list" "$REPOSITORY_PATH" \
            || die "не удалось записать repository entry"
    fi
else
    mkdir -p "$ROOT_SYS/etc/apk/repositories.d" \
        || die "не удалось создать каталог repositories.d"
    printf '%s\n' "$FEED_ENTRY" > "$TMP_DIR/z2kow.list" \
        || die "не удалось подготовить repository entry"
    mv "$TMP_DIR/z2kow.list" "$REPOSITORY_PATH" \
        || die "не удалось записать repository entry"
fi

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
