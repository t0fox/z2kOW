#!/bin/sh
# Backward-compatible public alias for the single OpenWrt release installer.
set -eu
trap '' HUP

# Once installed, the same public command opens the local product CLI.
if [ -x /usr/bin/z2kow ]; then
    exec /usr/bin/z2kow "$@"
fi

case "${1:-}" in
    ""|install|i) set -- ;;
    help|-h|--help)
        cat <<'EOF'
Установка z2kOW на OpenWrt:
  wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh

После установки: z2kow {install|update|status|version|diag|uninstall}
EOF
        exit 0
        ;;
    *) echo "z2kow.sh: z2k ещё не установлен; допустима только команда install" >&2; exit 2 ;;
esac

[ "$(id -u 2>/dev/null || true)" = 0 ] || { echo "z2kow.sh: запустите от root" >&2; exit 1; }
[ -s /etc/openwrt_release ] || { echo "z2kow.sh: требуется OpenWrt" >&2; exit 1; }

if command -v wget >/dev/null 2>&1; then
    download() { wget -q -T 30 -O "$2" "$1"; }
elif command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --silent --show-error --connect-timeout 10 --max-time 45 -o "$2" "$1"; }
else
    echo "z2kow.sh: нужен wget или curl" >&2
    exit 1
fi

TMP_DIR="${TMPDIR:-/tmp}/z2kow-bootstrap.$$"
(umask 077 && mkdir "$TMP_DIR") || { echo "z2kow.sh: не удалось создать временный каталог" >&2; exit 1; }
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
INSTALLER="$TMP_DIR/install.sh"
INSTALLER_URL="https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh"
download "$INSTALLER_URL" "$INSTALLER" || { echo "z2kow.sh: canonical installer download failed" >&2; exit 1; }
sh "$INSTALLER" "$@"
