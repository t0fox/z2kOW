#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
mkdir -p "$TEMP/bin"

cat > "$TEMP/bin/wget" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$Z2K_TEST_WGET_ARGS"
SH
chmod +x "$TEMP/bin/wget"

BLOCK="$(sed -n '/^if command -v wget/,/^fi$/p' "$ROOT/scripts/openwrt/install.sh")"
[ -n "$BLOCK" ] || { echo "Не найдена production-настройка downloader" >&2; exit 1; }

PATH="$TEMP/bin:$PATH"
Z2K_TEST_WGET_ARGS="$TEMP/wget-args"
export PATH Z2K_TEST_WGET_ARGS
eval "$BLOCK"
download https://example.invalid/UPDATES.json "$TEMP/manifest"

ARGS="$(cat "$TEMP/wget-args")"
case " $ARGS " in
    *" -T 15 "*) echo "SUITE[ow-bootstrap-timeout]: pass=1 fail=0" ;;
    *) echo "Ожидался предел ожидания wget 15 секунд, получено: $ARGS" >&2; exit 1 ;;
esac
