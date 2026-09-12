#!/bin/sh
# package/openwrt/z2k-feed-bootstrap.sh - Stage 7: первый trust feed'а (§31-33).
#
# Канонический first-install path (на роутере, от root):
#   z2k-feed-bootstrap.sh --key-file <pub.pem> [--feed-url URL] [--root /]
# Ключ дистрибутируется ВНЕ этого скрипта (страница релиза,Qr/docs) и
# сравнивается оператором глазами; скрипт его только кладёт на место.
#
# Делает ровно:
#   /etc/apk/keys/z2k-feed.pem      (urfalevelbootstrap, НЕ payload/runtime)
#   /etc/apk/repositories.d/z2k.list (идемпотентно, только наша строка)
#   apk update && apk add z2k-adapter
# НЕ делает никогда: distfeeds.list, blanket apk upgrade, --allow-untrusted
# (кроме явного --insecure-dev-only для тестов артефактов — громко вслух).
# Uninstall пакета эти два файла НЕ сносит (их жизненный цикл — bootstrap,
# иначе reinstall через apk невозможен и ломаются чужие репозитории).
#
# POSIX sh. --root SYSROOT для тестов (пусто = /).

set -e
ROOT_SYS="/"
KEY_FILE=""
FEED_URL="https://feed.z2k.example.com/openwrt"
INSECURE_DEV=0
while [ $# -gt 0 ]; do
    case "$1" in
        --key-file) KEY_FILE="$2"; shift 2 ;;
        --feed-url) FEED_URL="$2"; shift 2 ;;
        --root) ROOT_SYS="$2"; shift 2 ;;
        --insecure-dev-only) INSECURE_DEV=1; shift ;;
        *) printf 'z2k-feed-bootstrap: неизвестный флаг %s\n' "$1" >&2; exit 1 ;;
    esac
done

KEY_DST="$ROOT_SYS/etc/apk/keys/z2k-feed.pem"
LIST_DST="$ROOT_SYS/etc/apk/repositories.d/z2k.list"
APK="${Z2K_APK_BIN:-apk}"

if [ "$INSECURE_DEV" != "1" ]; then
    [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] \
        || { printf 'z2k-feed-bootstrap: нужен --key-file <pub.pem> (production: ключ только глазами, никакого --allow-untrusted)\n' >&2; exit 1; }
else
    printf 'z2k-feed-bootstrap: ВНИМАНИЕ: --insecure-dev-only, БЕЗ проверки подписи (только тесты артефактов)\n' >&2
fi

mkdir -p "$(dirname "$KEY_DST")" "$(dirname "$LIST_DST")" || exit 1
if [ "$INSECURE_DEV" != "1" ]; then
    # Ключ — атомарно tmp+rename; перезапись тем же содержимым — noop.
    _ktmp="$KEY_DST.new.$$"
    cp -f "$KEY_FILE" "$_ktmp" || exit 1
    chmod 644 "$_ktmp" 2>/dev/null || true
    mv -f "$_ktmp" "$KEY_DST" || exit 1
fi
# Строка фида — идемпотентно: дубликат не добавляем, чужие строки не трогаем.
_list_line="$FEED_URL"
if [ -f "$LIST_DST" ] && grep -qxF "$_list_line" "$LIST_DST" 2>/dev/null; then
    :
else
    printf '%s\n' "$_list_line" >> "$LIST_DST" || exit 1
fi

if [ "$INSECURE_DEV" = "1" ]; then
    "$APK" --allow-untrusted update || exit 1
    "$APK" --allow-untrusted add z2k-adapter || exit 1
else
    "$APK" update || exit 1
    "$APK" add z2k-adapter || exit 1
fi
printf 'z2k-feed-bootstrap: ok (feed=%s)\n' "$FEED_URL"
