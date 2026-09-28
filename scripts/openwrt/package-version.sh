#!/bin/sh
# Canonical adapter/webpanel package version selection for build-release.sh.
set -eu

die() { printf 'package-version: %s\n' "$1" >&2; exit 1; }

[ "$#" -ge 3 ] || die 'usage: package-version.sh snapshot|release REPO SOURCE_SHA [PRODUCT_VERSION]'
MODE="$1"
ROOT="$2"
SOURCE_SHA="$3"
PRODUCT_VERSION="${4:-}"
MAKEFILE="$ROOT/package/openwrt/Makefile"
[ -f "$MAKEFILE" ] || die "нет $MAKEFILE"

_resolved="$(git -C "$ROOT" rev-parse --verify "${SOURCE_SHA}^{commit}" 2>/dev/null)" \
    || die "source commit не найден: $SOURCE_SHA"
[ "$_resolved" = "$SOURCE_SHA" ] || die 'source SHA должен быть полным commit SHA'

_base_version="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$MAKEFILE" | head -1 | tr -d ' \t\r\n')"
_base_release="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$MAKEFILE" | head -1 | tr -d ' \t\r\n')"
[ -n "$_base_version" ] && [ -n "$_base_release" ] || die 'нет PKG_VERSION/PKG_RELEASE в adapter Makefile'
case "$_base_release" in ''|*[!0-9]*) die "PKG_RELEASE не целое: [$_base_release]" ;; esac

case "$MODE" in
    snapshot)
        [ -z "$PRODUCT_VERSION" ] || die 'product version недопустима для snapshot'
        _epoch="$(git -C "$ROOT" show -s --format=%ct "$_resolved" 2>/dev/null)" \
            || die "нет committer timestamp для $_resolved"
        case "$_epoch" in ''|*[!0-9]*) die "неверный committer timestamp: [$_epoch]" ;; esac
        command -v python3 >/dev/null 2>&1 || die 'нужен python3 для UTC timestamp'
        _stamp="$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y%m%d%H%M%S"))' "$_epoch")" \
            || die 'не удалось форматировать UTC timestamp'
        _version="${_base_version}_alpha${_stamp}~${_resolved}"
        _release="$_base_release"
        ;;
    release)
        [ -n "$PRODUCT_VERSION" ] || die 'release mode требует product version X.Y.Z'
        command -v python3 >/dev/null 2>&1 || die 'нужен python3 для проверки product version'
        python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", sys.argv[1]) else 1)' "$PRODUCT_VERSION" \
            || die "product version должна иметь форму X.Y.Z: [$PRODUCT_VERSION]"
        _version="$PRODUCT_VERSION"
        _release=1
        ;;
    *) die "неизвестный режим: [$MODE]" ;;
esac

printf '%s|%s\n' "$_version" "$_release"
