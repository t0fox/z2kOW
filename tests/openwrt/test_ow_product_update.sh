#!/bin/sh
# Transaction-level product updater tests with an isolated OpenWrt root and APK/network mocks.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-product-update"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$REPO/platform/openwrt/product-update.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-product-update.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
SYS="$T/sys"
BIN="$T/bin"
FIX="$T/releases"
mkdir -p "$SYS/etc/apk/keys" "$SYS/etc/apk/repositories.d" \
    "$SYS/etc/z2k/state" "$SYS/etc/init.d" "$SYS/usr/lib/z2k/share" \
    "$SYS/var/lock" "$BIN" "$FIX/latest" "$FIX/v0.1.2" "$T/tmp"
export Z2K_PRODUCT_SYSROOT="$SYS" TMPDIR="$T/tmp"
export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ETC="$SYS/etc/z2k" Z2K_STATE="$SYS/etc/z2k/state"
export Z2K_PRODUCT_TAG_FILE="$Z2K_STATE/product-tag"
export Z2K_PRODUCT_UPDATE_STATUS_FILE="$Z2K_STATE/product-update.status"
export Z2K_FEED_PUBLIC_KEY="$Z2K_ROOT/share/z2k-feed.pem"
export Z2K_TEST_INSTALLED="$T/installed" Z2K_TEST_APK_LOG="$T/apk.log"
export Z2K_TEST_RELEASE_FIXTURES="$FIX"

openssl ecparam -name prime256v1 -genkey -noout -out "$T/feed.key" 2>/dev/null || exit 1
openssl ec -in "$T/feed.key" -pubout -out "$T/feed.pem" 2>/dev/null || exit 1
cp "$T/feed.pem" "$SYS/usr/lib/z2k/share/z2k-feed.pem"
cp "$T/feed.pem" "$SYS/etc/apk/keys/z2k-feed.pem"

make_release() {
    _dir="$1" _version="$2" _previous="${3:-}"
    if [ -n "$_previous" ]; then
        _history="{\"version\":\"$_version\",\"tag\":\"v$_version\"},{\"version\":\"$_previous\",\"tag\":\"v$_previous\"}"
    else
        _history="{\"version\":\"$_version\",\"tag\":\"v$_version\"}"
    fi
    cat > "$_dir/release-manifest.json" <<EOF
{"product":"z2kOW","schema":2,"channel":"stable","version":"$_version","tag":"v$_version","openwrt":{"release":"25.12.5","target":"mediatek/filogic","arch":"aarch64_cortex-a53"},"history":[$_history]}
EOF
    if [ "$_version" = "0.1.2" ]; then
        printf 'signed old package index fixture\n' > "$_dir/packages.adb"
        printf 'old adapter\n' > "$_dir/z2k-adapter-0.1.2-r1.apk"
        printf 'old webpanel\n' > "$_dir/z2k-webpanel-0.1.2-r1.apk"
    fi
    (
        cd "$_dir" || exit 1
        set -- release-manifest.json
        [ ! -f packages.adb ] || set -- "$@" packages.adb
        [ ! -f z2k-adapter-0.1.2-r1.apk ] || set -- "$@" z2k-adapter-0.1.2-r1.apk
        [ ! -f z2k-webpanel-0.1.2-r1.apk ] || set -- "$@" z2k-webpanel-0.1.2-r1.apk
        sha256sum "$@" > SHA256SUMS || exit 1
        openssl dgst -sha256 -sign "$T/feed.key" -out SHA256SUMS.sig SHA256SUMS >/dev/null 2>&1
    ) || return 1
}

make_release "$FIX/latest" 0.1.3 0.1.2 || exit 1
make_release "$FIX/v0.1.2" 0.1.2 || exit 1

cat > "$BIN/jsonfilter" <<'JSONFILTER'
#!/bin/sh
file= expr=
while [ $# -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        -e) expr="$2"; shift 2 ;;
        *) exit 2 ;;
    esac
done
python3 - "$file" "$expr" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
expr = sys.argv[2]
paths = {
    "@.product": ("product",), "@.schema": ("schema",),
    "@.channel": ("channel",), "@.version": ("version",),
    "@.tag": ("tag",), "@.openwrt.release": ("openwrt", "release"),
    "@.openwrt.target": ("openwrt", "target"), "@.openwrt.arch": ("openwrt", "arch"),
    "@.history[0].version": ("history", 0, "version"),
    "@.history[0].tag": ("history", 0, "tag"),
}
if expr == "@.history[*].tag":
    for row in obj.get("history", []): print(row.get("tag", ""))
else:
    value = obj
    for part in paths[expr]: value = value[part]
    print(value)
PY
JSONFILTER

cat > "$BIN/id" <<'ID'
#!/bin/sh
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exit 2
ID
cat > "$BIN/ip" <<'IP'
#!/bin/sh
echo '2: br-lan inet 192.0.2.1/24 scope global br-lan'
IP
cat > "$BIN/pidof" <<'PIDOF'
#!/bin/sh
grep -q '^z2k-adapter|0.1.3-r1$' "$Z2K_TEST_INSTALLED" && [ "${Z2K_TEST_HEALTH_ALWAYS:-0}" = 0 ] && exit 1
exit 0
PIDOF
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
    http://*)
        if grep -q '^z2k-adapter|0.1.3-r1$' "$Z2K_TEST_INSTALLED" \
           && [ "${Z2K_TEST_HEALTH_ALWAYS:-0}" = 0 ]; then exit 1; fi
        exit 0
        ;;
    https://github.com/t0fox/z2kOW/releases/latest/download/*)
        rel="$Z2K_TEST_RELEASE_FIXTURES/latest"; asset=${url##*/} ;;
    https://github.com/t0fox/z2kOW/releases/download/v0.1.2/*)
        rel="$Z2K_TEST_RELEASE_FIXTURES/v0.1.2"; asset=${url##*/} ;;
    *) exit 1 ;;
esac
[ -f "$rel/$asset" ] || exit 1
cp "$rel/$asset" "$dest"
WGET

cat > "$BIN/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >> "$Z2K_TEST_APK_LOG"
if [ "${1:-}" = --repositories-file ]; then
    repos="$2"; shift 2
    cat "$repos" >> "$Z2K_TEST_APK_LOG"
    case "${1:-}" in
        update) exit 0 ;;
        upgrade)
            [ "${2:-}" = --available ] || exit 2
            grep -q "ndx file://.*/rollback/packages.adb" "$repos" || exit 1
            if grep -q 'github.com/t0fox/z2kOW/releases/latest/download/packages.adb' "$repos"; then
                echo 'rollback repositories still contain the moving latest feed' >&2
                exit 1
            fi
            printf '%s\n' "$(dirname "$repos")" > "$Z2K_TEST_ROLLBACK_REPOS"
            sed -i 's/^z2k-adapter|.*/z2k-adapter|0.1.2-r1/; s/^z2k-webpanel|.*/z2k-webpanel|0.1.2-r1/' "$Z2K_TEST_INSTALLED"
            exit 0
            ;;
    esac
fi
case "${1:-}" in
    list)
        [ "${2:-}" = --installed ] || exit 2
        pkg="$3"; ver="$(sed -n "s/^$pkg|//p" "$Z2K_TEST_INSTALLED" | head -1)"
        [ -n "$ver" ] && printf '%s-%s aarch64_cortex-a53 {fixture} (MIT) [installed]\n' "$pkg" "$ver"
        exit 0
        ;;
    update) exit 0 ;;
    del) exit 0 ;;
    add)
        [ "${Z2K_TEST_APK_ADD_FAIL:-0}" = 0 ] || exit 1
        [ "${2:-}" = --upgrade ] || exit 2
        sed -i 's/^z2k-adapter|.*/z2k-adapter|0.1.3-r1/; s/^z2k-webpanel|.*/z2k-webpanel|0.1.3-r1/' "$Z2K_TEST_INSTALLED"
        exit 0
        ;;
    *) exit 2 ;;
esac
APK

cat > "$SYS/etc/init.d/z2k" <<'CORE'
#!/bin/sh
if [ "${Z2K_TEST_HEALTH_ALWAYS:-0}" = 0 ] && grep -q '^z2k-adapter|0.1.3-r1$' "$Z2K_TEST_INSTALLED"; then exit 1; fi
exit 0
CORE
cat > "$SYS/etc/init.d/z2k-webpanel" <<'PANEL'
#!/bin/sh
if [ "${Z2K_TEST_HEALTH_ALWAYS:-0}" = 0 ] && grep -q '^z2k-webpanel|0.1.3-r1$' "$Z2K_TEST_INSTALLED"; then exit 1; fi
exit 0
PANEL
chmod +x "$BIN"/* "$SYS/etc/init.d/"*
export PATH="$BIN:$PATH" Z2K_TEST_ROLLBACK_REPOS="$T/rollback-repos"
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'user-config=keep-me\n' > "$SYS/etc/z2k/config"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"
printf 'ndx https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base\n' > "$SYS/etc/apk/repositories"

# A failed package transaction must leave the installed product tag and config untouched.
if Z2K_TEST_APK_ADD_FAIL=1 sh "$ENGINE" update >"$T/failed.log" 2>&1; then
    _t_bad "failed package transaction" "unexpectedly succeeded"
else
    grep -q '^v0.1.2$' "$SYS/etc/z2k/state/product-tag" \
        && _t_ok || _t_bad "failed package transaction preserves product tag" "tag changed"
    grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
        && _t_ok || _t_bad "failed package transaction preserves config" "config changed"
fi

# A post-update health failure must use the immutable prior release and exclude moving latest.
: > "$Z2K_TEST_APK_LOG"
rm -f "$SYS/etc/z2k/state/product-update.status" "$T/rollback-repos"
if sh "$ENGINE" update >"$T/rollback.log" 2>&1; then
    _t_bad "health failure rollback" "unexpectedly reported success"
else
    grep -q '^v0.1.2$' "$SYS/etc/z2k/state/product-tag" \
        && _t_ok || _t_bad "rollback preserves previous product tag" "tag changed"
    grep -q '^z2k-adapter|0.1.2-r1$' "$Z2K_TEST_INSTALLED" \
        && grep -q '^z2k-webpanel|0.1.2-r1$' "$Z2K_TEST_INSTALLED" \
        && _t_ok || _t_bad "rollback restores previous package versions" "old packages not restored"
    grep -q 'ndx file://.*/rollback/packages.adb' "$Z2K_TEST_APK_LOG" \
        && _t_ok || _t_bad "rollback uses old immutable APK index" "rollback index missing"
    grep -q '^state=rolled-back$' "$SYS/etc/z2k/state/product-update.status" \
        && _t_ok || _t_bad "rollback reports rolled-back state" "state not recorded"
    grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
        && _t_ok || _t_bad "health rollback preserves config" "config changed"
fi

# Successful install/update advances only the product tag after health checks.
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"
if Z2K_TEST_HEALTH_ALWAYS=1 sh "$ENGINE" update >"$T/success.log" 2>&1; then
    grep -q '^v0.1.3$' "$SYS/etc/z2k/state/product-tag" \
        && _t_ok || _t_bad "healthy update advances product tag" "new version was not recorded"
else
    cat "$T/success.log" >&2
    _t_bad "healthy update advances product tag" "update failed before recording the new version"
fi
grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
    && _t_ok || _t_bad "successful update preserves config" "config changed"

# The documented uninstall path removes only z2kOW's feed/key and install metadata.
mkdir -p "$SYS/etc/z2k/state/warp"
printf '{"id":"warp-id-keep"}\n' > "$SYS/etc/z2k/state/warp/device.json"
sh "$ENGINE" uninstall >"$T/uninstall.log" 2>&1 \
    && [ ! -e "$SYS/etc/apk/repositories.d/z2kow.list" ] \
    && [ ! -e "$SYS/etc/apk/keys/z2k-feed.pem" ] \
    && [ ! -e "$SYS/etc/z2k/state/product-tag" ] \
    && [ ! -e "$SYS/etc/z2k/state/product-update.status" ] \
    && [ -f "$SYS/etc/apk/repositories" ] \
    && grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
    && grep -q 'warp-id-keep' "$SYS/etc/z2k/state/warp/device.json" \
    && _t_ok || _t_bad "documented uninstall removes only owned trust/meta" "foreign feeds or user state changed"

_t_done
