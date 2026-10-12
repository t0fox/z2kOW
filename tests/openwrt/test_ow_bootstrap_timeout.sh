#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
mkdir -p "$TEMP/bin"

cat > "$TEMP/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$Z2K_TEST_CURL_ARGS"
SH
cat > "$TEMP/bin/wget" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$Z2K_TEST_WGET_ARGS"
SH
chmod +x "$TEMP/bin/curl" "$TEMP/bin/wget"

APK_LINE="$(grep -E '^[[:space:]]*apk add ' "$ROOT/scripts/openwrt/install.sh")"
case " $APK_LINE " in
    *" curl "*) ;;
    *) echo "Bootstrap не устанавливает curl до загрузки manifest" >&2; exit 1 ;;
esac

BLOCK="$(sed -n '/^if command -v curl/,/^fi$/p' "$ROOT/scripts/openwrt/install.sh")"
[ -n "$BLOCK" ] || { echo "Не найдена production-настройка curl downloader" >&2; exit 1; }

PATH="$TEMP/bin:$PATH"
Z2K_TEST_CURL_ARGS="$TEMP/curl-args"
Z2K_TEST_WGET_ARGS="$TEMP/wget-args"
export PATH Z2K_TEST_CURL_ARGS Z2K_TEST_WGET_ARGS
eval "$BLOCK"
download https://example.invalid/UPDATES.json "$TEMP/manifest"

ARGS="$(cat "$TEMP/curl-args")"
case " $ARGS " in
    *" --connect-timeout 10 "*) ;;
    *) echo "Ожидался DNS/connect timeout curl 10 секунд, получено: $ARGS" >&2; exit 1 ;;
esac
case " $ARGS " in
    *" --max-time 600 "*) ;;
    *) echo "Ожидался общий лимит curl 600 секунд, получено: $ARGS" >&2; exit 1 ;;
esac
[ ! -e "$TEMP/wget-args" ] || { echo "Bootstrap выбрал wget вместо curl" >&2; exit 1; }
echo "SUITE[ow-bootstrap-timeout]: pass=1 fail=0"
