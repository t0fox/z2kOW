#!/bin/sh
# z2kOW stable-channel bootstrap. The release builder renders the pinned key.
set -eu
trap '' HUP

EXPECTED_FEED_KEY_SHA256="@Z2K_FEED_KEY_SHA256@"
KEY_URL="https://raw.githubusercontent.com/t0fox/z2kOW/main/package/openwrt/keys/z2k-feed.pem"
RELEASE_ASSETS="https://github.com/t0fox/z2kOW/releases/latest/download"

# Re-running the public command on an installed router opens the local CLI.
if [ -x /usr/bin/z2kow ]; then
    exec /usr/bin/z2kow "$@"
fi

case "${1:-}" in
    ""|install|i) ;;
    help|-h|--help)
        cat <<'EOF'
Установка z2kOW на OpenWrt:
  wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/z2kow.sh | sh

После установки: z2kow {install|update|status|version|diag|uninstall}
EOF
        exit 0
        ;;
    *) echo "z2kow.sh: z2kow ещё не установлен; допустима только команда install" >&2; exit 2 ;;
esac

[ "$(id -u 2>/dev/null || true)" = 0 ] || { echo "z2kow.sh: запустите от root" >&2; exit 1; }
[ -s /etc/openwrt_release ] || { echo "z2kow.sh: требуется OpenWrt" >&2; exit 1; }
case "$EXPECTED_FEED_KEY_SHA256" in
    ''|*@*) echo "z2kow.sh: production trust key ещё не закреплён владельцем проекта" >&2; exit 1 ;;
esac

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 30 -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 45 -o "$2" "$1"; }
else
    echo "z2kow.sh: нужен wget или curl" >&2
    exit 1
fi

command -v sha256sum >/dev/null 2>&1 || { echo "z2kow.sh: нужен sha256sum" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "z2kow.sh: нужен openssl для проверки подписи release" >&2; exit 1; }
TMP_DIR="${TMPDIR:-/tmp}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP_DIR") || { echo "z2kow.sh: не удалось создать временный каталог" >&2; exit 1; }
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
KEY="$TMP_DIR/z2k-feed.pem"
download "$KEY_URL" "$KEY" || { echo "z2kow.sh: не удалось получить pinned public key" >&2; exit 1; }
actual_key_sha="$(sha256sum "$KEY" | awk '{print $1}')"
[ "$actual_key_sha" = "$EXPECTED_FEED_KEY_SHA256" ] || { echo "z2kow.sh: public key fingerprint mismatch" >&2; exit 1; }

download "$RELEASE_ASSETS/SHA256SUMS" "$TMP_DIR/SHA256SUMS" \
    || { echo "z2kow.sh: не удалось скачать release checksums" >&2; exit 1; }
download "$RELEASE_ASSETS/SHA256SUMS.sig" "$TMP_DIR/SHA256SUMS.sig" \
    || { echo "z2kow.sh: не удалось скачать release signature" >&2; exit 1; }
openssl dgst -sha256 -verify "$KEY" -signature "$TMP_DIR/SHA256SUMS.sig" "$TMP_DIR/SHA256SUMS" >/dev/null \
    || { echo "z2kow.sh: release signature invalid" >&2; exit 1; }
download "$RELEASE_ASSETS/install.sh" "$TMP_DIR/install.sh" \
    || { echo "z2kow.sh: не удалось скачать bootstrap installer" >&2; exit 1; }
expected_installer_sha="$(awk '$2 == "install.sh" { print $1 }' "$TMP_DIR/SHA256SUMS")"
actual_installer_sha="$(sha256sum "$TMP_DIR/install.sh" | awk '{print $1}')"
printf '%s' "$expected_installer_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || { echo "z2kow.sh: signed checksums do not identify install.sh" >&2; exit 1; }
[ "$actual_installer_sha" = "$expected_installer_sha" ] \
    || { echo "z2kow.sh: installer hash mismatch" >&2; exit 1; }

shift 2>/dev/null || true
sh "$TMP_DIR/install.sh" "$@"
