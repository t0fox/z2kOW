#!/bin/sh
# Static contract checks for the product release path; dynamic transaction tests live separately.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s: %s\n' "$1" "$2"; }
contains() { grep -Fq -- "$2" "$1" 2>/dev/null; }

for f in "$ROOT/z2kow.sh" "$ROOT/platform/openwrt/z2kow.sh" "$ROOT/platform/openwrt/product-update.sh"; do
    [ -s "$f" ] && ok "exists: ${f#$ROOT/}" || bad "exists: ${f#$ROOT/}" "missing"
done
contains "$ROOT/z2kow.sh" 'raw.githubusercontent.com/t0fox/z2kOW/' \
    && ok 'bootstrap channel is t0fox/z2kOW' || bad 'bootstrap channel is t0fox/z2kOW' 'missing pinned product URL'
! grep -Eqi 'necronicle/z2k' "$ROOT/z2kow.sh" "$ROOT/platform/openwrt/z2kow.sh" "$ROOT/platform/openwrt/product-update.sh" \
    && ok 'product version lane does not query upstream z2k' || bad 'product version lane does not query upstream z2k' 'foreign update source present'
contains "$ROOT/platform/openwrt/z2kow.sh" 'update|u)' \
    && ok 'CLI exposes update' || bad 'CLI exposes update' 'missing dispatcher'
contains "$ROOT/platform/openwrt/z2kow.sh" 'status|s)' \
    && ok 'CLI exposes status' || bad 'CLI exposes status' 'missing dispatcher'
contains "$ROOT/platform/openwrt/z2kow.sh" 'version|v)' \
    && ok 'CLI exposes version' || bad 'CLI exposes version' 'missing dispatcher'
contains "$ROOT/platform/openwrt/z2kow.sh" 'diag|d)' \
    && ok 'CLI exposes diag' || bad 'CLI exposes diag' 'missing dispatcher'
contains "$ROOT/platform/openwrt/z2kow.sh" 'uninstall|remove)' \
    && ok 'CLI exposes uninstall' || bad 'CLI exposes uninstall' 'missing dispatcher'
contains "$ROOT/platform/openwrt/z2kow.sh" 'install|i)' \
    && ok 'CLI exposes install' || bad 'CLI exposes install' 'missing dispatcher'
contains "$ROOT/platform/openwrt/product-update.sh" 'openssl dgst -sha256 -verify' \
    && ok 'product manifest uses pinned signature verification' || bad 'product manifest uses pinned signature verification' 'missing verifier'
contains "$ROOT/platform/openwrt/product-update.sh" 'sha256sum' \
    && ok 'product assets are hash checked' || bad 'product assets are hash checked' 'missing hash check'
contains "$ROOT/platform/openwrt/product-update.sh" 'rolled-back' \
    && ok 'failed updates expose rollback state' || bad 'failed updates expose rollback state' 'missing rollback status'
contains "$ROOT/platform/openwrt/product-update.sh" 'releases/latest/download/packages.adb*) continue' \
    && ok 'rollback excludes moving production feed' || bad 'rollback excludes moving production feed' 'latest repo could win rollback'
contains "$ROOT/platform/openwrt/product-update.sh" 'product-tag' \
    && ok 'product tag has one canonical storage path' || bad 'product tag has no canonical path' 'missing product-tag'
contains "$ROOT/package/openwrt/Makefile" '/usr/bin/z2kow' \
    && ok 'APK installs /usr/bin/z2kow' || bad 'APK installs /usr/bin/z2kow' 'missing package recipe'
contains "$ROOT/webpanel/cgi/api.sh" 'GET /product/update/check' \
    && ok 'web API exposes product update check' || bad 'web API exposes product update check' 'missing route'
contains "$ROOT/webpanel/cgi/api.sh" 'POST /product/update/start' \
    && ok 'web API starts product update asynchronously' || bad 'web API starts product update asynchronously' 'missing route'
contains "$ROOT/webpanel/cgi/api.sh" 'GET /product/update/status' \
    && ok 'web API exposes product update state' || bad 'web API exposes product update state' 'missing route'
contains "$ROOT/webpanel/cgi/api.sh" 'GET /product/update/info' \
    && ok 'web API exposes cumulative release history' || bad 'web API exposes cumulative release history' 'missing route'
contains "$ROOT/webpanel/cgi/actions.sh" 'z2kow update --non-interactive' \
    && ok 'web and CLI invoke the same engine' || bad 'web and CLI invoke the same engine' 'missing shared CLI invocation'
contains "$ROOT/webpanel/www/js/pages/dashboard.js" 'product-update-card' \
    && ok 'dashboard has product update card' || bad 'dashboard has product update card' 'missing card'
contains "$ROOT/scripts/openwrt/release-assets.py" 'parse_changelog_history' \
    && ok 'release bundle builds history from CHANGELOG.md' || bad 'release bundle builds history from CHANGELOG.md' 'missing history generator'
contains "$ROOT/.github/workflows/release-openwrt.yml" 'z2kow.sh' \
    && ok 'release verifies and publishes the bootstrap' || bad 'release verifies and publishes the bootstrap' 'missing release asset'

printf 'SUITE[ow-product-update-contract]: pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
