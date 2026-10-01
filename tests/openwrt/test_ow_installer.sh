#!/bin/sh
# Production bootstrap behavior in an isolated OpenWrt-like filesystem.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/luci_fixture.sh"
_t_plan "ow-installer"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO/scripts/openwrt/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-installer.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
SYS="$T/sys"
BIN="$T/bin"
KEY="$T/feed.pem"
SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

command -v openssl >/dev/null 2>&1 || { echo "FAIL[ow-installer]: openssl unavailable" >&2; exit 1; }
openssl ecparam -name prime256v1 -genkey -noout -out "$T/feed.key" 2>/dev/null || exit 1
openssl ec -in "$T/feed.key" -pubout -out "$KEY" 2>/dev/null || exit 1
KEY_FP="$(sha256sum "$KEY" | awk '{print $1}')"

_render() {
    sed -e "s/@Z2K_FEED_KEY_SHA256@/$KEY_FP/g" \
        -e "s/@Z2K_KEY_SOURCE_SHA@/$SHA/g" \
        -e "s|^ROOT_SYS=\"/\"$|ROOT_SYS=\"$SYS\"|" \
        "$INSTALLER" > "$T/install.sh" || return 1
    chmod +x "$T/install.sh"
}

_reset() {
    rm -rf "$SYS" "$BIN"
    mkdir -p "$SYS/etc/apk/keys" "$SYS/etc/apk/repositories.d" \
        "$SYS/etc/init.d" "$SYS/etc/z2k" "$BIN" "$T/tmp"
    cat > "$SYS/etc/openwrt_release" <<'RELEASE'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
RELEASE
    : > "$T/apk.log"
    : > "$T/installed"
    cat > "$BIN/id" <<'ID'
#!/bin/sh
[ "$1" = -u ] && { printf '%s\n' "${Z2K_TEST_UID:-0}"; exit 0; }
exit 2
ID
    cat > "$BIN/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TEST_APK_LOG"
no_scripts=0
if [ "${1:-}" = --no-scripts ]; then
    no_scripts=1
    shift
fi
case "$1" in
    --version) echo 'apk-tools 3.0.5'; exit 0 ;;
    info)
        [ "$2" = -e ] || exit 2
        grep -q "^$3|" "$Z2K_TEST_INSTALLED"; exit $? ;;
    list)
        [ "$2" = --installed ] || exit 2
        shift 2
        for pkg in "$@"; do
            version="$(sed -n "s/^$pkg|//p" "$Z2K_TEST_INSTALLED" | head -1)"
            [ -n "$version" ] && printf '%s-%s aarch64_cortex-a53 {fixture} (MIT) [installed]\n' "$pkg" "$version"
        done
        exit 0 ;;
    update) [ "${Z2K_TEST_APK_UPDATE_FAIL:-0}" = 0 ]; exit $? ;;
    add)
        [ "${Z2K_TEST_APK_ADD_FAIL:-0}" = 0 ] || exit 1
        shift
        upgrade=0
        virtual_seed=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --upgrade) upgrade=1; shift ;;
                --virtual)
                    [ "$#" -ge 2 ] || exit 2
                    virtual_seed="$2"
                    shift 2
                    ;;
                *) break ;;
            esac
        done
        if [ "$no_scripts" = 1 ] && [ "${Z2K_TEST_APK_STAGE_FAIL:-0}" = 1 ]; then
            exit 1
        fi
        if [ "$no_scripts" = 0 ] && [ "${Z2K_TEST_APK_PRODUCT_FAIL:-0}" = 1 ]; then
            exit 1
        fi
        for pkg in "$@"; do
            changed=0
            if grep -q "^$pkg|" "$Z2K_TEST_INSTALLED"; then
                if [ "$upgrade" = 1 ]; then
                    sed -i "s/^$pkg|.*/$pkg|0.1.1-r1/" "$Z2K_TEST_INSTALLED"
                    changed=1
                fi
            else
                printf '%s|0.1.1-r1\n' "$pkg" >> "$Z2K_TEST_INSTALLED"
                changed=1
            fi
            if [ "$pkg" = lighttpd ] && [ "$changed" = 1 ] && [ "$no_scripts" = 0 ]; then
                printf '%s\n' 'hook start stock-lighttpd' >> "$Z2K_TEST_APK_LOG"
            fi
        done
        if [ -n "$virtual_seed" ]; then
            if grep -q "^$virtual_seed|" "$Z2K_TEST_INSTALLED"; then
                sed -i "s/^$virtual_seed|.*/$virtual_seed|0.1.1-r1/" "$Z2K_TEST_INSTALLED"
            else
                printf '%s|0.1.1-r1\n' "$virtual_seed" >> "$Z2K_TEST_INSTALLED"
            fi
        fi
        if [ "$no_scripts" = 1 ] && [ "${Z2K_TEST_SIGNAL_STAGE:-}" = TERM ]; then
            kill -TERM "$PPID"
        fi
        exit 0 ;;
    del)
        shift
        [ "${1:-}" = .z2k-webpanel-bootstrap-deps ] || exit 2
        sed -i '/^\.z2k-webpanel-bootstrap-deps|/d' "$Z2K_TEST_INSTALLED"
        if ! grep -Eq '^z2k-(adapter|webpanel)\|' "$Z2K_TEST_INSTALLED"; then
            if grep -q '^lighttpd|' "$Z2K_TEST_INSTALLED"; then
                printf '%s\n' 'hook post-deinstall stock-lighttpd' >> "$Z2K_TEST_APK_LOG"
            fi
            sed -i '/^lighttpd\(-mod-[^|]*\)\?|/d' "$Z2K_TEST_INSTALLED"
        fi
        exit 0 ;;
    upgrade)
        [ "${Z2K_TEST_APK_UPGRADE_FAIL:-0}" = 0 ] || exit 1
        shift
        for pkg in "$@"; do
            if grep -q "^$pkg|" "$Z2K_TEST_INSTALLED"; then
                sed -i "s/^$pkg|.*/$pkg|0.1.1-r1/" "$Z2K_TEST_INSTALLED"
            fi
        done
        exit 0 ;;
    *) exit 2 ;;
esac
APK
    cat > "$BIN/wget" <<'WGET'
#!/bin/sh
dest= url=
while [ $# -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        -T) shift 2 ;;
        -O) dest="$2"; shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    https://raw.githubusercontent.com/t0fox/z2kOW/*/package/openwrt/keys/z2k-feed.pem)
        [ "${Z2K_TEST_DOWNLOAD_FAIL:-0}" = 0 ] || exit 1
        cp "$Z2K_TEST_KEY_FILE" "$dest" ;;
    http://*:8088/*) [ "${Z2K_TEST_PANEL_HTTP_FAIL:-0}" = 0 ] || exit 1 ;;
    *) echo "unexpected test URL: $url" >&2; exit 2 ;;
esac
WGET
    cat > "$BIN/ip" <<'IP'
#!/bin/sh
[ "$*" = '-4 -o addr show dev br-lan' ] || exit 1
echo '8: br-lan inet 192.0.2.1/24 brd 192.0.2.255 scope global br-lan'
IP
    cat > "$BIN/pidof" <<'PIDOF'
#!/bin/sh
[ "$1" = nfqws2 ] && [ "${Z2K_TEST_CORE_RUNTIME_FAIL:-0}" = 0 ] || exit 1
echo 123
PIDOF
    cat > "$BIN/sleep" <<'SLEEP'
#!/bin/sh
exit 0
SLEEP
    # Some supported minimal OpenWrt images do not ship base64. The bootstrap
    # must verify its pinned key without relying on an optional decoder.
    cat > "$BIN/base64" <<'BASE64'
#!/bin/sh
exit 127
BASE64
    cat > "$SYS/etc/init.d/z2k" <<'CORE'
#!/bin/sh
[ "$1" = status ] || [ "$1" = running ] || exit 2
[ "${Z2K_TEST_CORE_FAIL:-0}" = 0 ] || exit 1
echo running
CORE
    cat > "$SYS/etc/init.d/z2k-webpanel" <<'PANEL'
#!/bin/sh
[ "$1" = running ] || [ "$1" = status ] || exit 2
[ "${Z2K_TEST_PANEL_FAIL:-0}" = 0 ] || exit 1
echo running
PANEL
    mkdir -p "$SYS/usr/bin"
    cat > "$SYS/usr/bin/z2kow" <<'CLI'
#!/bin/sh
[ "$1" = record ] || exit 2
printf '%s\n' 'record product-tag' >> "$Z2K_TEST_APK_LOG"
CLI
    chmod +x "$BIN/id" "$BIN/apk" "$BIN/wget" "$BIN/ip" "$BIN/pidof" "$BIN/sleep" "$BIN/base64" \
        "$SYS/usr/bin/z2kow" \
        "$SYS/etc/init.d/z2k" "$SYS/etc/init.d/z2k-webpanel"
    cp "$KEY" "$T/test-key.pem"
    export Z2K_TEST_KEY_FILE="$T/test-key.pem"
    export Z2K_TEST_APK_LOG="$T/apk.log" Z2K_TEST_INSTALLED="$T/installed"
    export PATH="$BIN:/usr/bin:/bin" TMPDIR="$T/tmp"
    unset Z2K_TEST_UID Z2K_TEST_DOWNLOAD_FAIL Z2K_TEST_APK_UPDATE_FAIL \
        Z2K_TEST_APK_ADD_FAIL Z2K_TEST_APK_UPGRADE_FAIL Z2K_TEST_PANEL_FAIL \
        Z2K_TEST_CORE_FAIL Z2K_TEST_CORE_RUNTIME_FAIL Z2K_TEST_PANEL_HTTP_FAIL \
        Z2K_TEST_APK_STAGE_FAIL Z2K_TEST_APK_PRODUCT_FAIL Z2K_TEST_SIGNAL_STAGE
    _render || return 1
}

_run() { sh "$T/install.sh" > "$T/out" 2>&1; }

assert_file "production installer template exists" "$INSTALLER"
_reset
if ! luci_fixture_seed "$SYS"; then _t_bad "cannot seed LuCI fixture"; exit 1; fi
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
printf 'user-owned configuration\n' > "$SYS/etc/z2k/config"
printf 'stock feeds stay\n' > "$SYS/etc/apk/distfeeds.list"
if _run; then _t_ok; else _t_bad "fresh install failed: $(cat "$T/out")"; fi
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "fresh install preserves LuCI and uhttpd state"
assert_eq "Lighttpd dependencies use no-script upgrade staging" \
    '--no-scripts add --upgrade --virtual .z2k-webpanel-bootstrap-deps lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias' \
    "$(grep '^--no-scripts add ' "$T/apk.log" | head -1)"
assert_eq "fresh install suppresses stock Lighttpd post-install hook" '' "$(grep '^hook start stock-lighttpd$' "$T/apk.log" || true)"
assert_eq "fresh install uses apk add for the two packages" 'add z2k-adapter z2k-webpanel' "$(grep '^add ' "$T/apk.log" | tail -1)"
assert_file "fresh install adds the pinned key" "$SYS/etc/apk/keys/z2k-feed.pem"
assert_eq "fresh install writes the signed release index as a separate feed" 'ndx https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb' "$(cat "$SYS/etc/apk/repositories.d/z2kow.list" 2>/dev/null)"
assert_contains "fresh install reports LAN panel URL" "$T/out" 'http://192.0.2.1:8088'
assert_contains "fresh install reports product version" "$T/out" 'версия: 0.1.1-r1'
assert_contains "fresh install records stable product version after health checks" "$T/apk.log" 'record product-tag'
assert_eq "fresh install preserves stock repositories" 'stock feeds stay' "$(cat "$SYS/etc/apk/distfeeds.list")"
assert_eq "fresh install preserves user config" 'user-owned configuration' "$(cat "$SYS/etc/z2k/config")"
if grep -Eq '(^|[[:space:]])(enable|start)([[:space:]]|$)' "$T/apk.log"; then
    _t_bad "installer duplicated package lifecycle service start"
else
    _t_ok
fi

_reset
if ! luci_fixture_seed "$SYS"; then _t_bad "cannot seed LuCI fixture"; exit 1; fi
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
printf 'z2k-adapter|0.1.1-r1\nz2k-webpanel|0.1.1-r1\nlighttpd|0.1.0-r1\nlighttpd-mod-cgi|0.1.0-r1\nlighttpd-mod-setenv|0.1.0-r1\nlighttpd-mod-alias|0.1.0-r1\n' > "$T/installed"
cp "$KEY" "$SYS/etc/apk/keys/z2k-feed.pem"
printf '%s\n' 'ndx https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb' > "$SYS/etc/apk/repositories.d/z2kow.list"
before_key="$(sha256sum "$SYS/etc/apk/keys/z2k-feed.pem" | awk '{print $1}')"
if _run; then _t_ok; else _t_bad "repeat install failed: $(cat "$T/out")"; fi
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "repeat install preserves LuCI and uhttpd state"
assert_eq "repeat install stages Lighttpd upgrades without package scripts" \
    '--no-scripts add --upgrade --virtual .z2k-webpanel-bootstrap-deps lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias' \
    "$(grep '^--no-scripts add ' "$T/apk.log" | head -1)"
assert_eq "repeat install upgrades an old Lighttpd dependency in the no-script stage" \
    'lighttpd|0.1.1-r1' "$(grep '^lighttpd|' "$T/installed")"
assert_eq "repeat install suppresses stock Lighttpd upgrade hook" '' "$(grep '^hook start stock-lighttpd$' "$T/apk.log" || true)"
assert_eq "repeat install upgrades only the two product packages" 'add --upgrade z2k-adapter z2k-webpanel' "$(grep '^add --upgrade ' "$T/apk.log" | tail -1)"
assert_eq "repeat install leaves one feed entry" '1' "$(grep -c '^ndx https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb$' "$SYS/etc/apk/repositories.d/z2kow.list")"
assert_eq "repeat install leaves correct key bytes unchanged" "$before_key" "$(sha256sum "$SYS/etc/apk/keys/z2k-feed.pem" | awk '{print $1}')"

_reset
if ! luci_fixture_seed "$SYS"; then _t_bad "cannot seed LuCI fixture"; exit 1; fi
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
printf 'user extra data\n' > "$SYS/etc/z2k/config"
printf 'z2k-adapter|0.1.0-r79\nz2k-webpanel|0.1.0-r79\n' > "$T/installed"
if _run; then _t_ok; else _t_bad "legacy package upgrade failed: $(cat "$T/out")"; fi
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "legacy package upgrade preserves LuCI and uhttpd state"
assert_eq "legacy package upgrade uses the package-scoped add operation" 'add --upgrade z2k-adapter z2k-webpanel' "$(grep '^add --upgrade ' "$T/apk.log" | tail -1)"
assert_eq "legacy 0.1.0-r79 upgrades to product 0.1.1" 'z2k-adapter|0.1.1-r1' "$(grep '^z2k-adapter|' "$T/installed")"
assert_eq "legacy upgrade preserves user config" 'user extra data' "$(cat "$SYS/etc/z2k/config")"

_reset
openssl ecparam -name prime256v1 -genkey -noout -out "$T/wrong.key" 2>/dev/null || exit 1
openssl ec -in "$T/wrong.key" -pubout -out "$T/wrong-key.pem" 2>/dev/null || exit 1
Z2K_TEST_KEY_FILE="$T/wrong-key.pem" _run
assert_eq "wrong fingerprint fails closed" '1' "$?"
assert_eq "wrong fingerprint writes no trusted key" '0' "$([ -e "$SYS/etc/apk/keys/z2k-feed.pem" ] && echo 1 || echo 0)"
assert_eq "wrong fingerprint writes no repository" '0' "$([ -e "$SYS/etc/apk/repositories.d/z2kow.list" ] && echo 1 || echo 0)"
assert_eq "wrong fingerprint does not update or install packages" '' "$(grep -E '^(update|add|upgrade)([[:space:]]|$)' "$T/apk.log" || true)"

_reset
cp "$T/wrong-key.pem" "$SYS/etc/apk/keys/z2k-feed.pem"
_run
assert_eq "existing different key is never silently replaced" '1' "$?"
assert_eq "existing different key remains unchanged" "$(sha256sum "$T/wrong-key.pem" | awk '{print $1}')" "$(sha256sum "$SYS/etc/apk/keys/z2k-feed.pem" | awk '{print $1}')"
assert_eq "existing different key prevents package update" '' "$(grep -E '^(update|add|upgrade)([[:space:]]|$)' "$T/apk.log" || true)"

_reset
printf '%s\n' 'https://example.invalid/other-feed' > "$SYS/etc/apk/repositories.d/z2kow.list"
_run
assert_eq "conflicting repository entry stops install" '1' "$?"
assert_eq "conflicting repository entry is left untouched" 'https://example.invalid/other-feed' "$(cat "$SYS/etc/apk/repositories.d/z2kow.list")"
assert_eq "conflicting repository prevents package update" '' "$(grep -E '^(update|add|upgrade)([[:space:]]|$)' "$T/apk.log" || true)"

_reset
Z2K_TEST_DOWNLOAD_FAIL=1 _run
assert_eq "download failure stops install" '1' "$?"
assert_eq "download failure leaves no key" '0' "$([ -e "$SYS/etc/apk/keys/z2k-feed.pem" ] && echo 1 || echo 0)"

_reset
Z2K_TEST_APK_UPDATE_FAIL=1 _run
assert_eq "apk update failure stops install" '1' "$?"
assert_eq "apk update failure does not add packages" '0' "$(grep -c '^add ' "$T/apk.log")"

_reset
Z2K_TEST_APK_ADD_FAIL=1 _run
assert_eq "package installation failure stops install" '1' "$?"

_reset
Z2K_TEST_APK_STAGE_FAIL=1 _run
assert_eq "Lighttpd staging failure stops install" '1' "$?"
assert_eq "Lighttpd staging failure never starts the product transaction" '0' "$(grep -c '^add z2k-adapter z2k-webpanel$' "$T/apk.log" || true)"

_reset
Z2K_TEST_APK_PRODUCT_FAIL=1 _run
assert_eq "product transaction failure stops install" '1' "$?"
assert_contains "product transaction failure removes temporary dependency root" "$T/apk.log" 'del .z2k-webpanel-bootstrap-deps'
assert_eq "product transaction failure removes newly staged Lighttpd packages" '0' "$(grep -Ec '^lighttpd(-mod-[^|]*)?\|' "$T/installed" || true)"

_reset
Z2K_TEST_SIGNAL_STAGE=TERM _run
assert_eq "TERM during Lighttpd staging exits with signal status" '143' "$?"
assert_contains "TERM during Lighttpd staging runs cleanup" "$T/apk.log" 'del .z2k-webpanel-bootstrap-deps'
assert_eq "TERM during Lighttpd staging never starts the product transaction" '0' "$(grep -c '^add z2k-adapter z2k-webpanel$' "$T/apk.log" || true)"
assert_eq "TERM during Lighttpd staging removes staged dependencies" '0' "$(grep -Ec '^lighttpd(-mod-[^|]*)?\|' "$T/installed" || true)"

_reset
sed -i "s/DISTRIB_RELEASE='25.12.5'/DISTRIB_RELEASE='24.10.8'/" "$SYS/etc/openwrt_release"
_run
assert_eq "unsupported OpenWrt version is rejected" '1' "$?"

_reset
sed -i "s|DISTRIB_TARGET='mediatek/filogic'|DISTRIB_TARGET='ath79/generic'|" "$SYS/etc/openwrt_release"
_run
assert_eq "unsupported target is rejected" '1' "$?"

_reset
mv "$BIN/apk" "$BIN/apk.disabled"
_run
assert_eq "non-APK system is rejected" '1' "$?"

_reset
Z2K_TEST_PANEL_FAIL=1 _run
assert_eq "webpanel failed health check is reported" '1' "$?"

_reset
Z2K_TEST_PANEL_HTTP_FAIL=1 _run
assert_eq "webpanel HTTP failure is reported" '1' "$?"

_reset
Z2K_TEST_UID=1000 _run
assert_eq "non-root caller is rejected" '1' "$?"

_reset
Z2K_TEST_CORE_FAIL=1 _run
assert_eq "core failed health check is reported" '1' "$?"

_reset
Z2K_TEST_CORE_RUNTIME_FAIL=1 _run
assert_eq "core runtime failure is reported" '1' "$?"

_reset
printf 'preserve\n' > "$SYS/etc/apk/distfeeds.list"
printf 'keep config\n' > "$SYS/etc/z2k/config"
_run
assert_eq "production path never changes distfeeds.list" 'preserve' "$(cat "$SYS/etc/apk/distfeeds.list")"
assert_eq "production path never uses allow-untrusted" '0' "$(grep -ci -- '--allow-untrusted' "$T/apk.log" || true)"
assert_eq "production path never runs blanket apk upgrade" '0' "$(grep -E '^upgrade([[:space:]]*)$' "$T/apk.log" | wc -l | tr -d ' ')"
assert_eq "installer does not enable/start services itself" '0' "$(grep -E '^(/etc/init.d/)?z2k(-webpanel)?[[:space:]]+(enable|start)([[:space:]]|$)' "$T/apk.log" | wc -l | tr -d ' ')"

_t_done
