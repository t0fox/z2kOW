#!/bin/sh
# Transaction-level product updater tests with an isolated OpenWrt root and APK/network mocks.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/luci_fixture.sh"
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
if ! luci_fixture_seed "$SYS"; then _t_bad "cannot seed LuCI fixture"; exit 1; fi
_luci_before="$(luci_fixture_state "$SYS")" || exit 1
export Z2K_PRODUCT_SYSROOT="$SYS" TMPDIR="$T/tmp"
export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ETC="$SYS/etc/z2k" Z2K_STATE="$SYS/etc/z2k/state"
export Z2K_PRODUCT_TAG_FILE="$Z2K_STATE/product-tag"
export Z2K_PRODUCT_UPDATE_STATUS_FILE="$Z2K_STATE/product-update.status"
export Z2K_FEED_PUBLIC_KEY="$Z2K_ROOT/share/z2k-feed.pem"
export Z2K_TEST_INSTALLED="$T/installed" Z2K_TEST_APK_LOG="$T/apk.log"
export Z2K_TEST_LIGHTTPD_STAGE_FILE="$T/lighttpd-staged"
export Z2K_TEST_FETCH_LOG="$T/fetch.log"
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
[ -z "${Z2K_TEST_FETCH_LOG:-}" ] || printf '%s\n' "$url" >> "$Z2K_TEST_FETCH_LOG"
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
no_scripts=0
if [ "${1:-}" = --no-scripts ]; then no_scripts=1; shift; fi
case "${1:-}" in
    list)
        [ "${2:-}" = --installed ] || exit 2
        pkg="$3"; ver="$(sed -n "s/^$pkg|//p" "$Z2K_TEST_INSTALLED" | head -1)"
        [ -n "$ver" ] && printf '%s-%s aarch64_cortex-a53 {fixture} (MIT) [installed]\n' "$pkg" "$ver"
        exit 0
        ;;
    update) rm -f "$Z2K_TEST_LIGHTTPD_STAGE_FILE"; exit 0 ;;
    del)
        [ "${2:-}" != "${Z2K_TEST_WEBPANEL_SEED:-}" ] || rm -f "$Z2K_TEST_LIGHTTPD_STAGE_FILE"
        exit 0
        ;;
    add)
        shift
        upgrade=0 virtual_seed=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --upgrade) upgrade=1; shift ;;
                --virtual) virtual_seed="$2"; shift 2 ;;
                *) break ;;
            esac
        done
        if [ -n "$virtual_seed" ]; then
            [ "$no_scripts" = 1 ] || exit 2
            : > "$Z2K_TEST_LIGHTTPD_STAGE_FILE"
            exit 0
        fi
        [ "$upgrade" = 1 ] || exit 2
        if [ "$no_scripts" = 0 ] \
           && [ "${Z2K_TEST_LIGHTTPD_HOOK:-0}" = 1 ] \
           && [ ! -e "$Z2K_TEST_LIGHTTPD_STAGE_FILE" ]; then
            printf '%s\n' 'hook start stock-lighttpd' >> "$Z2K_TEST_APK_LOG"
        fi
        if [ "${Z2K_TEST_APK_ADD_PARTIAL_FAIL:-0}" = 1 ]; then
            sed -i 's/^z2k-adapter|.*/z2k-adapter|0.1.3-r1/; s/^z2k-webpanel|.*/z2k-webpanel|0.1.3-r1/' "$Z2K_TEST_INSTALLED"
            exit 1
        fi
        [ "${Z2K_TEST_APK_ADD_FAIL:-0}" = 0 ] || exit 1
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
export Z2K_TEST_WEBPANEL_SEED=.z2k-webpanel-product-update-deps
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'user-config=keep-me\n' > "$SYS/etc/z2k/config"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"
printf 'ndx https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/base\n' > "$SYS/etc/apk/repositories"

# CI snapshots have no production release metadata. Status, check, info and
# version must identify the snapshot without touching the stable release feed.
SNAPSHOT_SHA=fcaca952e3cd9926db84b7c0440960909956b8fd
SNAPSHOT_VERSION="0.1.1_alpha20260929234704~$SNAPSHOT_SHA-r1"
printf 'z2k-adapter|%s\nz2k-webpanel|%s\n' "$SNAPSHOT_VERSION" "$SNAPSHOT_VERSION" > "$Z2K_TEST_INSTALLED"
rm -f "$SYS/etc/z2k/state/product-tag"
printf 'p-86.1\n' > "$SYS/etc/z2k/state/installed-tag"
printf 'state=failed\ninstalled=unknown\nlatest=unknown\nmessage=stale production manifest error\nupdated_at=2026-09-30T04:18:29Z\n' \
    > "$SYS/etc/z2k/state/product-update.status"
: > "$Z2K_TEST_FETCH_LOG"
: > "$Z2K_TEST_APK_LOG"
sh "$ENGINE" status --json > "$T/snapshot-status.json"
grep -q '"state":"snapshot"' "$T/snapshot-status.json" \
    && grep -q '"installed":"SNAPSHOT"' "$T/snapshot-status.json" \
    && grep -q '"build":"fcaca952e3cd9926db84b7c0440960909956b8fd"' "$T/snapshot-status.json" \
    && grep -q '"engine":"p-86.1"' "$T/snapshot-status.json" \
    && grep -q '"production_channel_active":false' "$T/snapshot-status.json" \
    && _t_ok || _t_bad "snapshot status reports build and engine" "snapshot metadata missing or stale failure leaked"
sh "$ENGINE" check --json > "$T/snapshot-check.json" \
    && grep -q '"state":"snapshot"' "$T/snapshot-check.json" \
    && grep -q '"update_available":false' "$T/snapshot-check.json" \
    && _t_ok || _t_bad "snapshot check does not query stable channel" "check failed or returned production update"
sh "$ENGINE" info > "$T/snapshot-info.json" \
    && grep -q '"channel":"snapshot"' "$T/snapshot-info.json" \
    && grep -q '"production_channel_active":false' "$T/snapshot-info.json" \
    && _t_ok || _t_bad "snapshot info is structured and explicit" "info returned a stable manifest or failed"
sh "$ENGINE" version > "$T/snapshot-version.txt"
grep -q '^product=SNAPSHOT fcaca952$' "$T/snapshot-version.txt" \
    && grep -q "^build=$SNAPSHOT_SHA$" "$T/snapshot-version.txt" \
    && grep -q '^engine=p-86.1$' "$T/snapshot-version.txt" \
    && _t_ok || _t_bad "snapshot version separates product, build and engine" "version output conflated or omitted axes"
if sh "$ENGINE" update --non-interactive > "$T/snapshot-update.log" 2>&1; then
    _t_bad "snapshot update fails closed" "snapshot entered production package update"
else
    grep -qi 'snapshot\|production channel' "$T/snapshot-update.log" \
        && _t_ok || _t_bad "snapshot update explains inactive production channel" "failure reason missing"
fi
[ ! -s "$Z2K_TEST_FETCH_LOG" ] \
    && _t_ok || _t_bad "snapshot commands do not fetch stable releases" "production manifest was requested"
if grep -Eq '^(update|add|--repositories-file)' "$Z2K_TEST_APK_LOG"; then
    _t_bad "snapshot update does not mutate packages" "APK transaction ran"
else
    _t_ok
fi

# Restore the stable-release fixture for the transaction and rollback cases below.
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"
rm -f "$SYS/etc/z2k/state/product-update.status"
export Z2K_TEST_LIGHTTPD_HOOK=1

# A failed package transaction must leave the installed product tag and config untouched.
if Z2K_TEST_APK_ADD_FAIL=1 sh "$ENGINE" update >"$T/failed.log" 2>&1; then
    _t_bad "failed package transaction" "unexpectedly succeeded"
else
    grep -q '^v0.1.2$' "$SYS/etc/z2k/state/product-tag" \
        && _t_ok || _t_bad "failed package transaction preserves product tag" "tag changed"
    grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
        && _t_ok || _t_bad "failed package transaction preserves config" "config changed"
fi
luci_fixture_assert_unchanged "$SYS" "$_luci_before" "failed product update preserves LuCI and uhttpd state"
grep -qF -- '--no-scripts add --upgrade --virtual .z2k-webpanel-product-update-deps lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-alias' "$Z2K_TEST_APK_LOG" \
    && _t_ok || _t_bad "product update stages Lighttpd dependencies without package scripts" "no-script dependency stage was not run"
if grep -qx 'hook start stock-lighttpd' "$Z2K_TEST_APK_LOG"; then
    _t_bad "product update does not start stock Lighttpd" "stock hook ran on port 80"
else
    _t_ok
fi
assert_eq "product update retains normal z2k package hooks" '1' "$(grep -c '^add --upgrade z2k-adapter z2k-webpanel$' "$Z2K_TEST_APK_LOG")"
assert_eq "product update removes its temporary dependency seed" '1' "$(grep -c '^del .z2k-webpanel-product-update-deps$' "$Z2K_TEST_APK_LOG")"

# APK can report failure after changing one or both package files. In that
# case the old signed release must be restored before update exits.
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"
rm -f "$SYS/etc/z2k/state/product-update.status" "$T/rollback-repos"
: > "$Z2K_TEST_APK_LOG"
if Z2K_TEST_APK_ADD_PARTIAL_FAIL=1 sh "$ENGINE" update >"$T/partial-failure.log" 2>&1; then
    _t_bad "partial package transaction rollback" "unexpectedly reported success"
else
    if grep -q '^v0.1.2$' "$SYS/etc/z2k/state/product-tag"; then
        _t_ok
    else
        _t_bad "partial transaction preserves product tag" "tag changed"
    fi
    if grep -q '^z2k-adapter|0.1.2-r1$' "$Z2K_TEST_INSTALLED" \
       && grep -q '^z2k-webpanel|0.1.2-r1$' "$Z2K_TEST_INSTALLED"; then
        _t_ok
    else
        _t_bad "partial transaction restores both packages" "new or mixed package state remains"
    fi
    if grep -q '^state=rolled-back$' "$SYS/etc/z2k/state/product-update.status"; then
        _t_ok
    else
        _t_bad "partial transaction records rollback" "rollback state not recorded"
    fi
    if grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config"; then
        _t_ok
    else
        _t_bad "partial transaction preserves config" "config changed"
    fi
fi

# A missing product tag can be recovered only from matching stable package
# versions. Use that signed immutable release as the rollback baseline.
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
rm -f "$SYS/etc/z2k/state/product-tag" "$SYS/etc/z2k/state/product-update.status" "$T/rollback-repos"
: > "$Z2K_TEST_APK_LOG"
if Z2K_TEST_APK_ADD_PARTIAL_FAIL=1 sh "$ENGINE" update >"$T/missing-tag-partial-failure.log" 2>&1; then
    _t_bad "missing-tag partial package rollback" "unexpectedly reported success"
else
    if grep -q '^z2k-adapter|0.1.2-r1$' "$Z2K_TEST_INSTALLED" \
       && grep -q '^z2k-webpanel|0.1.2-r1$' "$Z2K_TEST_INSTALLED"; then
        _t_ok
    else
        _t_bad "missing-tag partial rollback restores both packages" "new or mixed package state remains"
    fi
    if grep -q '^v0.1.2$' "$SYS/etc/z2k/state/product-tag"; then
        _t_ok
    else
        _t_bad "missing-tag partial rollback records recovered baseline" "signed baseline tag missing"
    fi
    if grep -q '^state=rolled-back$' "$SYS/etc/z2k/state/product-update.status"; then
        _t_ok
    else
        _t_bad "missing-tag partial rollback is recorded" "rollback state not recorded"
    fi
fi
printf 'z2k-adapter|0.1.2-r1\nz2k-webpanel|0.1.2-r1\n' > "$Z2K_TEST_INSTALLED"
printf 'v0.1.2\n' > "$SYS/etc/z2k/state/product-tag"

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
    luci_fixture_assert_unchanged "$SYS" "$_luci_before" "successful product update preserves LuCI and uhttpd state"
else
    cat "$T/success.log" >&2
    _t_bad "healthy update advances product tag" "update failed before recording the new version"
fi
grep -q '^user-config=keep-me$' "$SYS/etc/z2k/config" \
    && _t_ok || _t_bad "successful update preserves config" "config changed"

# Stable product version output carries the immutable source commit packaged by CI.
PRODUCT_BUILD_SHA=1234567890abcdef1234567890abcdef12345678
printf '%s\n' "$PRODUCT_BUILD_SHA" > "$Z2K_ROOT/share/product-build-commit"
sh "$ENGINE" version > "$T/stable-version.txt"
if grep -q '^product=v0.1.3$' "$T/stable-version.txt" \
   && grep -q "^build=$PRODUCT_BUILD_SHA$" "$T/stable-version.txt"; then
    _t_ok
else
    _t_bad "stable version separates product and source build" "release version or build SHA missing"
fi

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
    && [ "$(luci_fixture_state "$SYS")" = "$_luci_before" ] \
    && _t_ok || _t_bad "documented uninstall removes only owned trust/meta" "foreign feeds or user state changed"

_t_done
