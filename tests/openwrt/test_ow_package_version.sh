#!/bin/sh
# tests/openwrt/test_ow_package_version.sh - adapter snapshot/release version contract.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-package-version"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION_TOOL="$REPO/scripts/openwrt/package-version.sh"
BUILD="$REPO/scripts/openwrt/build-release.sh"

_sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
_parent="$(git -C "$REPO" rev-parse HEAD^ 2>/dev/null)"
_base_version="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$REPO/package/openwrt/Makefile" | head -1 | tr -d ' \t\r\n')"
_base_release="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$REPO/package/openwrt/Makefile" | head -1 | tr -d ' \t\r\n')"
_snap_base_version="$(python3 - "$_base_version" <<'PY'
import sys
major, minor, patch = (int(part) for part in sys.argv[1].split("."))
print(f"{major}.{minor}.{patch + 1}")
PY
)"
_snapshot_version() {
    [ -f "$VERSION_TOOL" ] || return 1
    sh "$VERSION_TOOL" snapshot "$REPO" "$1" 2>/dev/null
}
_legacy_stable_version() {
    [ -f "$VERSION_TOOL" ] || return 1
    sh "$VERSION_TOOL" stable "$REPO" "$1" 2>/dev/null
}
_release_version() {
    [ -f "$VERSION_TOOL" ] || return 1
    sh "$VERSION_TOOL" release "$REPO" "$1" "$2" 2>/dev/null
}

assert_file "package version helper exists" "$VERSION_TOOL"
if _legacy_stable_version "$_sha" >/dev/null; then
    _t_bad "package-version helper must reject the legacy stable rXX mode"
else
    _t_ok
fi
_snap="$( _snapshot_version "$_sha" )"
_snap_repeat="$( _snapshot_version "$_sha" )"
assert_eq "same source SHA reproduces snapshot version" "$_snap" "$_snap_repeat"
_snap_version="$(printf '%s' "$_snap" | cut -d'|' -f1)"
_snap_release="$(printf '%s' "$_snap" | cut -d'|' -f2)"
case "$_snap_version" in
    "${_snap_base_version}_alpha"??????????????"~${_sha}") _t_ok ;;
    *) _t_bad "snapshot version must use next product patch and include UTC timestamp/full SHA: [$_snap_version]" ;;
esac
assert_eq "snapshot starts at package revision 1" "1" "$_snap_release"
_parent_snap="$( _snapshot_version "$_parent" )"
if [ -n "$_snap_version" ] && [ -n "$_parent_snap" ] && \
   [ "$_snap_version" != "$(printf '%s' "$_parent_snap" | cut -d'|' -f1)" ]; then
    _t_ok
else
    _t_bad "different source SHAs produced the same/empty snapshot version"
fi

if _release_version "$_sha" "$_base_version" >/dev/null; then
    _t_bad "release helper must reject a SemVer equal to the legacy stable baseline"
else
    _t_ok
fi
_product_version="$(python3 - "$_base_version" <<'PY'
import sys
major, minor, patch = (int(part) for part in sys.argv[1].split("."))
print(f"{major}.{minor}.{patch + 1}")
PY
)"
assert_eq "release mode emits product version with release 1" \
    "$_product_version|1" "$(_release_version "$_sha" "$_product_version")"
_bad_release="$( _release_version "$_sha" '1.2' )"
if [ -z "$_bad_release" ]; then _t_ok; else _t_bad "release helper accepted a non-X.Y.Z product version"; fi
_bad_leading_zero_release="$( _release_version "$_sha" '01.2.3' )"
if [ -z "$_bad_leading_zero_release" ]; then _t_ok; else _t_bad "release helper accepted a SemVer component with a leading zero"; fi

# Exercise the canonical builder's read-only version query, which selects the
# same helper/mode as a build without traversing manifest/seed/SDK work.
if sh "$BUILD" --print-package-version --target mediatek/filogic >/dev/null 2>&1; then
    _t_bad "canonical builder must require snapshot or release mode"
else
    _t_ok
fi
_builder_snapshot="$(sh "$BUILD" --print-package-version --ci-snapshot --target mediatek/filogic 2>/dev/null)"
_builder_snapshot_pkg="$(printf '%s' "$_builder_snapshot" | cut -d'|' -f1)"
_builder_snapshot_sha="$(printf '%s' "$_builder_snapshot" | cut -d'|' -f2)"
assert_eq "canonical builder selects snapshot version" "$_snap_version-r$_snap_release" "$_builder_snapshot_pkg"
assert_eq "snapshot query preserves exact source SHA" "$_sha" "$_builder_snapshot_sha"
_builder_release="$(sh "$BUILD" --print-package-version --release --product-version \
    "$_product_version" --target mediatek/filogic 2>/dev/null)"
_builder_release_pkg="$(printf '%s' "$_builder_release" | cut -d'|' -f1)"
_builder_release_sha="$(printf '%s' "$_builder_release" | cut -d'|' -f2)"
assert_eq "canonical builder release mode selects product version" "$_product_version-r1" "$_builder_release_pkg"
assert_eq "release query preserves exact source SHA" "$_sha" "$_builder_release_sha"

# Make sure package overrides are scoped to the adapter/webpanel Makefile;
# runtime package Makefiles retain their independent pins.
assert_contains "adapter Makefile accepts scoped package version override" \
    "$REPO/package/openwrt/Makefile" 'Z2K_OW_PACKAGE_VERSION'
assert_contains "adapter Makefile accepts scoped package release override" \
    "$REPO/package/openwrt/Makefile" 'Z2K_OW_PACKAGE_RELEASE'
assert_contains "canonical make call passes scoped adapter version" \
    "$BUILD" 'Z2K_OW_PACKAGE_VERSION=$PKG_VERSION'
assert_contains "canonical make call passes scoped adapter release" \
    "$BUILD" 'Z2K_OW_PACKAGE_RELEASE=$PKG_RELEASE'
assert_contains "canonical make call embeds exact source commit in adapter" \
    "$BUILD" 'Z2K_OW_BUILD_COMMIT=$SRC_COMMIT'
assert_contains "adapter installs product build commit metadata" \
    "$REPO/package/openwrt/Makefile" 'share/product-build-commit'
# The webpanel must require the adapter build selected by this invocation,
# whether the canonical builder selected snapshot or release versions.
assert_contains "webpanel adapter floor follows selected package mode" \
    "$REPO/package/openwrt/Makefile" 'EXTRA_DEPENDS:=z2k-adapter (>=$(PKG_VERSION)-r$(PKG_RELEASE))'
assert_not_contains "runtime Makefile does not consume adapter version override" \
    "$REPO/package/z2k-runtime/Makefile" 'Z2K_OW_PACKAGE_VERSION|Z2K_OW_PACKAGE_RELEASE'
assert_not_contains "WARP runtime Makefile does not consume adapter version override" \
    "$REPO/package/z2k-warp-runtime/Makefile" 'Z2K_OW_PACKAGE_VERSION|Z2K_OW_PACKAGE_RELEASE'

# apk-tools 3.0.5 is present in CI's pinned SDK. Local developer runs may lack
# the SDK; strict OpenWrt CI must fail closed rather than skip the real sorter.
APK_BIN="${OW_APK_BIN:-$HOME/openwrt-sdk-25.12.5-mediatek-filogic/staging_dir/host/bin/apk}"
if [ -x "$APK_BIN" ]; then
    _apk_version="$("$APK_BIN" --version 2>&1 | head -1)"
    case "$_apk_version" in
        *"3.0.5"*) _t_ok ;;
        *) _t_bad "version comparator must be pinned apk-tools 3.0.5, got [$_apk_version]" ;;
    esac
    _parent_sha="$_parent"
    _head_epoch="$(git -C "$REPO" show -s --format=%ct "$_sha")"
    _parent_epoch="$(git -C "$REPO" show -s --format=%ct "$_parent_sha")"
    _parent_version="$(printf '%s' "$_parent_snap" | cut -d'|' -f1)-r$(printf '%s' "$_parent_snap" | cut -d'|' -f2)"
    _head_version="$_snap_version-r$_snap_release"
    if [ "$_head_epoch" -gt "$_parent_epoch" ] 2>/dev/null; then
        _cmp="$("$APK_BIN" version -t "$_parent_version" "$_head_version" 2>/dev/null)"
        assert_eq "later source commit sorts newer under apk-tools" "<" "$_cmp"
    else
        _t_bad "test fixture requires HEAD committer timestamp later than its parent"
    fi
    _makefile_stable="$_base_version-r$_base_release"
    _same_semver_r1="$_base_version-r1"
    _cmp="$("$APK_BIN" version -t "$_same_semver_r1" "$_makefile_stable" 2>/dev/null)"
    assert_eq "same SemVer r1 sorts below legacy r79" "<" "$_cmp"
    _release="$( _release_version "$_sha" "$_product_version" )"
    _release_pkg="$(printf '%s' "$_release" | sed 's/|/-r/')"
    _cmp="$("$APK_BIN" version -t "$_snap_version-r$_snap_release" "$_release_pkg" 2>/dev/null)"
    assert_eq "snapshot sorts below product release under apk-tools" "<" "$_cmp"
    _cmp="$("$APK_BIN" version -t "$_makefile_stable" "$_snap_version-r$_snap_release" 2>/dev/null)"
    assert_eq "snapshot sorts above installed legacy stable package under apk-tools" "<" "$_cmp"
    _cmp="$("$APK_BIN" version -t "$_makefile_stable" "$_release_pkg" 2>/dev/null)"
    assert_eq "first product release sorts above installed legacy r79" "<" "$_cmp"
    if "$APK_BIN" version -c "$_snap_version-r$_snap_release" "$_release_pkg" >/dev/null 2>&1; then
        _t_ok
    else
        _t_bad "apk-tools 3.0.5 rejected generated package version syntax"
    fi
elif [ "${OW_STRICT:-0}" = "1" ]; then
    _t_bad "apk-tools 3.0.5 is required in strict CI: [$APK_BIN]"
else
    echo "SKIP[ow-package-version]: apk-tools 3.0.5 not found at [$APK_BIN]"
fi

_t_done
