#!/bin/sh
# OpenWrt webpanel brand profile: backend contract, package ownership and local assets.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-branding"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

_brand_json="$(Z2K_ROOT="$REPO/.brand-test-root" . "$REPO/platform/openwrt/webpanel.sh" 2>/dev/null; wp_brand_json 2>/dev/null)"
if [ -n "$_brand_json" ] && printf '%s\n' "$_brand_json" | node -e '
  const fs=require("fs");
  const profile=JSON.parse("{"+fs.readFileSync(0,"utf8").trim()+"}").brand;
  const want={name:"z2kOW",subtitle:"OpenWrt edition",logo:"/brand/openwrt/wordmark.svg",favicon:"/brand/openwrt/favicon.svg",theme:"/brand/openwrt/theme.css"};
  if (JSON.stringify(profile)!==JSON.stringify(want)) process.exit(1);
' 2>/dev/null; then
    _t_ok
else
    _t_bad "package profile emits the neutral OpenWrt brand schema"
fi

# The profile is additive on /status and only appears behind the existing
# platform seam, leaving the Keenetic response bytes untouched.
if grep -q 'wp_brand_json' "$REPO/webpanel/cgi/api.sh" \
    && grep -q 'command -v wp_brand_json' "$REPO/webpanel/cgi/api.sh" \
    && grep -Fq 'if [ "${Z2K_PLATFORM:-keenetic}" = "openwrt" ]; then' "$REPO/webpanel/cgi/api.sh"; then
    _t_ok
else
    _t_bad "GET /status adds the brand profile only on OpenWrt"
fi

for _file in wordmark.svg favicon.svg theme.css; do
    if [ -s "$REPO/platform/openwrt/webpanel-brand/$_file" ]; then _t_ok; else _t_bad "profile asset exists: $_file"; fi
done
grep -Fq '.brand svg[hidden] { display: none; }' "$REPO/webpanel/www/style.css" \
    && grep -Fq '.brand-profile-logo[hidden] { display: none; }' "$REPO/webpanel/www/style.css" \
    && _t_ok || _t_bad "hidden default/profile marks follow CSS display rules"

# Profile assets stay package-owned and never enter the generic signed payload.
for _pair in \
    "/usr/lib/z2k/www/brand/openwrt/wordmark.svg package" \
    "/usr/lib/z2k/www/brand/openwrt/favicon.svg package" \
    "/usr/lib/z2k/www/brand/openwrt/theme.css package"; do
    grep -qxF "$_pair" "$REPO/package/openwrt/ownership.map" \
        && _t_ok || _t_bad "ownership map: $_pair"
done
for _src in wordmark.svg favicon.svg theme.css; do
    grep -q "platform/openwrt/webpanel-brand/$_src" "$REPO/package/openwrt/Makefile" \
        && _t_ok || _t_bad "adapter APK installs $_src"
done

# Every URL in the served brand is local SVG/CSS; no executable or remote
# payload is embedded in these package assets.
if sed 's|http://www.w3.org/2000/svg||g' \
    "$REPO/platform/openwrt/webpanel-brand/wordmark.svg" \
    "$REPO/platform/openwrt/webpanel-brand/favicon.svg" \
    "$REPO/platform/openwrt/webpanel-brand/theme.css" \
    | grep -nEi 'https?://|data:|base64|@import|<script|\.png|\.jpe?g|\.webp' >/dev/null; then
    _t_bad "brand assets contain only local SVG/CSS resources"
else
    _t_ok
fi
for _token in '--bg:' '--bg-card:' '--border:' '--text:' '--accent:'; do
    grep -qF -- "$_token" "$REPO/platform/openwrt/webpanel-brand/theme.css" \
        && _t_ok || _t_bad "OpenWrt palette token $_token"
done

# Common UI code travels in the signed updater snapshot; adapter artwork stays
# out of that seed/update map and is refreshed only by the adapter APK.
_common_dest="$(Z2K_PLATFORM=openwrt . "$REPO/lib/release_map.sh" 2>/dev/null; z2k_install_paths webpanel/www/js/core/branding.js 2>/dev/null)"
if [ "$_common_dest" = "/usr/lib/z2k/www/js/core/branding.js" ]; then _t_ok; else _t_bad "common branding module reaches updater path"; fi
_package_dest="$(Z2K_PLATFORM=openwrt . "$REPO/lib/release_map.sh" 2>/dev/null; z2k_install_paths platform/openwrt/webpanel-brand/wordmark.svg 2>/dev/null)"
if [ -z "$_package_dest" ]; then _t_ok; else _t_bad "adapter asset stays outside common updater mapping"; fi

# Model an APK upgrade over stale installed bytes and compare the resulting
# docroot with the exact source bytes named by the Makefile.
_stage="$(mktemp -d "${TMPDIR:-/tmp}/ow-brand.XXXXXX")" || exit 1
mkdir -p "$_stage/usr/lib/z2k/www/brand/openwrt"
for _asset in wordmark.svg favicon.svg theme.css; do
    printf 'stale package bytes\n' > "$_stage/usr/lib/z2k/www/brand/openwrt/$_asset"
    install -m 0644 "$REPO/platform/openwrt/webpanel-brand/$_asset" \
        "$_stage/usr/lib/z2k/www/brand/openwrt/$_asset"
    cmp -s "$REPO/platform/openwrt/webpanel-brand/$_asset" \
        "$_stage/usr/lib/z2k/www/brand/openwrt/$_asset" \
        && _t_ok || _t_bad "upgrade refreshes installed $_asset bytes"
done
rm -rf "$_stage"

_t_done
