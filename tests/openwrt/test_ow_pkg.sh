#!/bin/sh
# tests/openwrt/test_ow_pkg.sh - §11: один рецепт, apk first, opkg fallback.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-pkg"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/platform/openwrt/pkg.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-pkg.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
_mkstub() {
    mkdir -p "$T/$1"
    printf '#!/bin/sh\necho "%s:$*" >> "%s/calls"\n%s\n' "$1" "$T" "$2" > "$T/$1/$1"
    chmod +x "$T/$1/$1"
}

# только opkg -> opkg
_mkstub opkg "exit 0"
assert_eq "manager opkg" "opkg" "$(PATH="$T/opkg:/usr/bin:/bin" z2k_ow_pkg_manager)"
PATH="$T/opkg:/usr/bin:/bin" z2k_ow_pkg_install kmod-nft-queue >/dev/null 2>&1
grep -q "opkg:update" "$T/calls" 2>/dev/null && _t_bad "opkg update при каждом install" || _t_ok

# apk в PATH -> apk побеждает
_mkstub apk "exit 0"
assert_eq "manager apk" "apk" "$(PATH="$T/apk:$T/opkg:/usr/bin:/bin" z2k_ow_pkg_manager)"
: > "$T/calls"
PATH="$T/apk:$T/opkg:/usr/bin:/bin" z2k_ow_pkg_install foo >/dev/null 2>&1
assert_contains "apk add вызван" "$T/calls" "apk:add foo"

# ни одного менеджера -> провал
if PATH="$T/empty:/usr/bin:/bin" z2k_ow_pkg_manager >/dev/null 2>&1; then
    # /usr/bin:/bin не должны содержать apk/opkg в CI; если содержат — скип
    if command -v apk >/dev/null 2>&1 || command -v opkg >/dev/null 2>&1; then
        _t_ok # хост имеет менеджер — ветка непроверяема здесь
    else
        _t_bad "менеджер найден без apk/opkg"
    fi
else
    _t_ok
fi

# opkg fallback update: install падает -> update -> повтор
mkdir -p "$T/flaky"
cat > "$T/flaky/opkg" <<EOF
#!/bin/sh
echo "opkg:\$*" >> "$T/calls2"
case "\$*" in
    "install needlists") exit 1 ;;
    "list-installed") printf 'kmod-nft-queue - 1.0\n' ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$T/flaky/opkg"
: > "$T/calls2"
PATH="$T/flaky:/usr/bin:/bin" z2k_ow_pkg_install needlists >/dev/null 2>&1
assert_contains "retry после update" "$T/calls2" "opkg:update"

# is_installed через тот же stub
PATH="$T/flaky:/usr/bin:/bin" z2k_ow_pkg_is_installed kmod-nft-queue \
    && _t_ok || _t_bad "is_installed не видит стоящий пакет"
PATH="$T/flaky:/usr/bin:/bin" z2k_ow_pkg_is_installed something-else \
    && _t_bad "is_installed видит нестоящий пакет" || _t_ok

_t_done
