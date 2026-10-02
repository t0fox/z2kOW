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

_platform="$(jsonfilter -i "$MANIFEST" -e '@.platform' 2>/dev/null | head -1)"
_schema="$(jsonfilter -i "$MANIFEST" -e '@.schema' 2>/dev/null | head -1)"
_branch="$(jsonfilter -i "$MANIFEST" -e '@.branch' 2>/dev/null | head -1)"
_upstream_repo="$(jsonfilter -i "$MANIFEST" -e '@.upstream.repository' 2>/dev/null | head -1)"
_upstream_branch="$(jsonfilter -i "$MANIFEST" -e '@.upstream.branch' 2>/dev/null | head -1)"
_upstream_tag="$(jsonfilter -i "$MANIFEST" -e '@.upstream.tag' 2>/dev/null | head -1)"
_upstream_commit="$(jsonfilter -i "$MANIFEST" -e '@.upstream.commit' 2>/dev/null | head -1)"
_tag="$(jsonfilter -i "$MANIFEST" -e '@.current' 2>/dev/null | head -1)"
_filename="$(jsonfilter -i "$MANIFEST" -e '@.artifact.filename' 2>/dev/null | head -1)"
_url="$(jsonfilter -i "$MANIFEST" -e '@.artifact.url' 2>/dev/null | head -1)"
_sha="$(jsonfilter -i "$MANIFEST" -e '@.artifact.sha256' 2>/dev/null | head -1 | tr 'A-F' 'a-f')"
_size="$(jsonfilter -i "$MANIFEST" -e '@.artifact.size_bytes' 2>/dev/null | head -1)"
printf '%s' "$_tag" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$' || die "current tag malformed"
[ "$_platform" = openwrt ] || die "controlled release is not for OpenWrt"
[ "$_schema" = 1 ] && [ "$_branch" = main ] || die "controlled manifest schema/branch is invalid"
[ "$_upstream_repo" = necronicle/z2k ] && [ "$_upstream_branch" = z2k-enhanced ] \
    && [ "$_upstream_tag" = "$_tag" ] || die "controlled upstream provenance is invalid"
printf '%s' "$_upstream_commit" | grep -Eq '^[0-9a-f]{40}$' || die "controlled upstream commit is malformed"
[ "$_filename" = openwrt-rootfs.tar.gz ] || die "controlled release has no complete rootfs artifact"
[ "$_url" = "https://github.com/t0fox/z2kOW/releases/download/$_tag/openwrt-rootfs.tar.gz" ] \
    || die "rootfs URL does not match current tag"
printf '%s' "$_sha" | grep -Eq '^[0-9a-f]{64}$' || die "rootfs checksum malformed"
printf '%s' "$_size" | grep -Eq '^[1-9][0-9]*$' || die "rootfs size malformed"

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

Z2K_ROOT="$TMP/engine/usr/lib/z2k"
export Z2K_ROOT
Z2K_ADAPTER_DIR="$Z2K_ROOT/platform/openwrt"
Z2K_LIB="$Z2K_ROOT/lib"
ZAPRET2_DIR="$TMP/engine/opt/zapret2"
Z2K_AU_PUBKEY="$ZAPRET2_DIR/etc/z2k-update-pub.pem"
Z2K_OW_BOOTSTRAP_MANIFEST="$MANIFEST"
Z2K_OW_BOOTSTRAP_SIGNATURE="$SIGNATURE"
Z2K_OW_BOOTSTRAP_ARTIFACT="$ARTIFACT"
export Z2K_ADAPTER_DIR Z2K_LIB ZAPRET2_DIR Z2K_AU_PUBKEY \
    Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE Z2K_OW_BOOTSTRAP_ARTIFACT
set +e
sh "$TMP/engine/usr/sbin/install_release" "$_tag"
_rc=$?
rm -rf "$TMP"
exit "$_rc"
