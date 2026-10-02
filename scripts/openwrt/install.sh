#!/bin/sh
# Fresh install bootstrap. It verifies the controlled manifest and one complete
# rootfs archive, then enters the same install_release(tag) transaction as all
# later updates. apk is used only for OpenWrt system dependencies.
set -eu

die() { printf 'z2kOW installer: %s\n' "$*" >&2; exit 1; }
[ "$(id -u 2>/dev/null || echo 1)" = 0 ] || die "запустите установщик от root"
OPENWRT_RELEASE_FILE="${Z2K_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
[ -r "$OPENWRT_RELEASE_FILE" ] || die "это не OpenWrt"
. "$OPENWRT_RELEASE_FILE"
[ "${DISTRIB_ID:-}" = OpenWrt ] || die "поддерживается только OpenWrt"
command -v apk >/dev/null 2>&1 || die "нужен OpenWrt с apk для системных зависимостей"

apk update || die "не удалось обновить индексы системных зависимостей"
apk add ca-bundle openssl-util jsonfilter || die "не удалось установить системные средства проверки подписи"

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 60 -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 600 -o "$2" "$1"; }
else
    die "нужен wget или curl"
fi

TMP="${TMPDIR:-/tmp}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP") || die "не удалось создать временный каталог"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

MANIFEST="$TMP/UPDATES.json"
SIGNATURE="$TMP/UPDATES.json.sig"
PUBKEY="$TMP/z2k-update-pub.pem"
ARTIFACT="$TMP/openwrt-rootfs.tar.gz"
ENGINE="$TMP/engine"
BASE="https://raw.githubusercontent.com/t0fox/z2kOW/main"

# This key is pinned in the bootstrap itself. A key fetched beside the manifest
# would let a modified manifest replace its own trust anchor.
cat > "$PUBKEY" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAHInDNbRMriWoRhLSW0t6AWkrpayIBzM9oakfZuB3/1Y=
-----END PUBLIC KEY-----
EOF

download "$BASE/UPDATES.json" "$MANIFEST" || die "не удалось получить controlled UPDATES.json"
download "$BASE/UPDATES.json.sig" "$SIGNATURE" || die "нет подписи controlled UPDATES.json; релиз не опубликован"
openssl pkeyutl -verify -rawin -pubin -inkey "$PUBKEY" \
    -in "$MANIFEST" -sigfile "$SIGNATURE" >/dev/null 2>&1 \
    || die "подпись controlled UPDATES.json неверна"

value() { jsonfilter -i "$MANIFEST" -e "@.$1" 2>/dev/null | head -n 1; }
_schema=$(value schema)
_branch=$(value branch)
_platform=$(value platform)
_tag=$(value current)
_seq=$(value seq)
_upstream_repo=$(value upstream.repository)
_upstream_branch=$(value upstream.branch)
_upstream_tag=$(value upstream.tag)
_upstream_commit=$(value upstream.commit)
_filename=$(value artifact.filename)
_url=$(value artifact.url)
_sha=$(value artifact.sha256 | tr 'A-F' 'a-f')
_size=$(value artifact.size_bytes)
[ "$_schema" = 1 ] && [ "$_branch" = main ] && [ "$_platform" = openwrt ] \
    || die "controlled UPDATES.json имеет неподдерживаемую схему"
printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' \
    || die "controlled UPDATES.json содержит некорректный release tag"
printf '%s' "$_seq" | grep -Eq '^[1-9][0-9]*$' \
    || die "controlled UPDATES.json содержит некорректный seq"
[ "$_upstream_repo" = necronicle/z2k ] \
    && [ "$_upstream_branch" = z2k-enhanced ] && [ "$_upstream_tag" = "$_tag" ] \
    || die "controlled UPDATES.json содержит некорректное upstream происхождение"
printf '%s' "$_upstream_commit" | grep -Eq '^[0-9a-f]{40}$' \
    || die "controlled UPDATES.json содержит некорректный upstream commit"
[ "$_filename" = openwrt-rootfs.tar.gz ] \
    && [ "$_url" = "https://github.com/t0fox/z2kOW/releases/download/$_tag/openwrt-rootfs.tar.gz" ] \
    || die "controlled UPDATES.json содержит некорректный artifact URL"
printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || die "controlled UPDATES.json содержит некорректный SHA-256"
printf '%s' "$_size" | grep -Eq '^[1-9][0-9]*$' \
    || die "controlled UPDATES.json содержит некорректный artifact size"

download "$_url" "$ARTIFACT" || die "не удалось скачать полный выпуск $_tag"
[ "$(wc -c < "$ARTIFACT" | tr -d ' \t\r\n')" = "$_size" ] \
    || die "размер rootfs не совпал с controlled UPDATES.json"
[ "$(sha256sum "$ARTIFACT" | awk '{print $1}')" = "$_sha" ] \
    || die "SHA-256 rootfs не совпал с controlled UPDATES.json"

# Extract only the small trusted installer engine to tmpfs. The complete
# payload remains a single archive and is applied by install_release(tag).
mkdir -p "$ENGINE"
tar -xzf "$ARTIFACT" -C "$ENGINE" \
    usr/lib/z2k/lib/utils.sh \
    usr/lib/z2k/lib/auto_update.sh \
    usr/lib/z2k/platform/openwrt/paths.sh \
    usr/lib/z2k/platform/openwrt/env.sh \
    usr/lib/z2k/platform/openwrt/manifest.sh \
    usr/lib/z2k/platform/openwrt/release.sh \
    usr/lib/z2k/platform/openwrt/bootstrap.sh \
    usr/lib/z2k/platform/openwrt/owned-paths.txt \
    usr/sbin/install_release \
    || die "полный rootfs не содержит canonical installer engine"
[ -x "$ENGINE/usr/sbin/install_release" ] || die "canonical install_release отсутствует в rootfs"

# The payload root is the live target. Only the installer code and library
# sources come from the small temporary extraction above.
Z2K_ROOT=/usr/lib/z2k
Z2K_ADAPTER_DIR="$ENGINE/usr/lib/z2k/platform/openwrt"
Z2K_LIB="$ENGINE/usr/lib/z2k/lib"
Z2K_AU_PUBKEY="$PUBKEY"
Z2K_OW_BOOTSTRAP_MANIFEST="$MANIFEST"
Z2K_OW_BOOTSTRAP_SIGNATURE="$SIGNATURE"
Z2K_OW_BOOTSTRAP_ARTIFACT="$ARTIFACT"
export Z2K_ROOT Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY \
    Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE Z2K_OW_BOOTSTRAP_ARTIFACT
"$ENGINE/usr/sbin/install_release" "$_tag"
