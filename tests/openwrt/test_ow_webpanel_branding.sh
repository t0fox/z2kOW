#!/bin/sh
# OpenWrt webpanel brand profile: backend contract and unchanged local assets.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-webpanel-branding"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

_brand_json="$(Z2K_ROOT="$REPO/.brand-test-root" . "$REPO/platform/openwrt/webpanel.sh" 2>/dev/null; wp_brand_json 2>/dev/null)"
if [ -n "$_brand_json" ] && printf '%s\n' "$_brand_json" | node -e '
  const fs=require("fs");
  const profile=JSON.parse("{"+fs.readFileSync(0,"utf8").trim()+"}").brand;
  const want={name:"z2kOW",subtitle:"OpenWrt edition",logo:"/assets/openwrt/logo.png",favicon:"/assets/openwrt/favicon.svg",theme:"/assets/openwrt/theme.css"};
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

for _file in mark.svg logo.png favicon.svg theme.css profile.json; do
    if [ -s "$REPO/platform/openwrt/webpanel-brand/$_file" ]; then _t_ok; else _t_bad "profile asset exists: $_file"; fi
done
if node - "$REPO/platform/openwrt/webpanel-brand/logo.png" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const path = process.argv[2];
const image = fs.readFileSync(path);
const hash = crypto.createHash("sha256").update(image).digest("hex").toUpperCase();
if (image.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a"
    || image.readUInt32BE(16) !== 2508 || image.readUInt32BE(20) !== 627
    || hash !== "79A450AB9F489EA56A28CAB8D402A85FAF2FE69621D655EBEBCA08482065E3AA") process.exit(1);
NODE
then
    _t_ok
else
    _t_bad "the supplied 2508×627 logo stays byte-for-byte unchanged"
fi
grep -Fq '<img id="brand-profile-logo"' "$REPO/webpanel/www/index.html" \
    && grep -Fq '<span id="brand-wordmark"' "$REPO/webpanel/www/index.html" \
    && ! grep -qE 'brand-default-logo|ANTIDPI|KEENETIC|brand-tagline' "$REPO/webpanel/www/index.html" \
    && ! grep -Fq 'brand-logo-window' "$REPO/webpanel/www/style.css" \
    && grep -Fq '.brand-profile-logo { display: block; width: 34px; height: 34px;' "$REPO/webpanel/www/style.css" \
    && grep -Fq '.topbar { padding: 0 var(--space-16); gap: 12px; }' "$REPO/webpanel/www/style.css" \
    && _t_ok || _t_bad "the existing shared brand slot and favicon remain unchanged"

if node - "$REPO/platform/openwrt/webpanel-brand/profile.json" "$REPO/webpanel/www/index.html" <<'NODE'
const fs = require("fs");
const profile = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const html = fs.readFileSync(process.argv[3], "utf8");
if (profile.name !== "z2kOW" || profile.logo !== "/assets/openwrt/logo.png"
    || profile.favicon !== "/assets/openwrt/favicon.svg"
    || profile.theme !== "/assets/openwrt/theme.css") process.exit(1);
if (!html.includes('fetch("/assets/openwrt/profile.json"') || !html.includes("window.__z2kBrandName = name;")) process.exit(1);
if (!html.includes("the z2kOW fallback remains usable")) process.exit(1);
NODE
then
    _t_ok
else
    _t_bad "static OpenWrt profile applies without /status and has a neutral fallback"
fi

# Profile assets stay package-owned and never enter the generic signed payload.
for _pair in \
    "/usr/lib/z2k/www/assets/openwrt/mark.svg package" \
    "/usr/lib/z2k/www/assets/openwrt/logo.png package" \
    "/usr/lib/z2k/www/assets/openwrt/favicon.svg package" \
    "/usr/lib/z2k/www/assets/openwrt/theme.css package" \
    "/usr/lib/z2k/www/assets/openwrt/profile.json package"; do
    grep -qxF "$_pair" "$REPO/package/openwrt/ownership.map" \
        && _t_ok || _t_bad "ownership map: $_pair"
done
for _src in mark.svg logo.png favicon.svg theme.css profile.json; do
    grep -q "platform/openwrt/webpanel-brand/$_src" "$REPO/package/openwrt/Makefile" \
        && _t_ok || _t_bad "adapter APK installs $_src"
done

# All identity assets remain local SVG/CSS; no extra image is shipped.
if sed 's|http://www.w3.org/2000/svg||g' \
    "$REPO/platform/openwrt/webpanel-brand/mark.svg" \
    "$REPO/platform/openwrt/webpanel-brand/favicon.svg" \
    "$REPO/platform/openwrt/webpanel-brand/theme.css" \
    | grep -nEi 'https?://|data:|base64|@import|<script|\.jpe?g|\.webp' >/dev/null; then
    _t_bad "identity assets contain only local SVG/CSS resources"
else
    _t_ok
fi

if node - "$REPO/platform/openwrt/webpanel-brand/mark.svg" "$REPO/platform/openwrt/webpanel-brand/favicon.svg" <<'NODE'
const fs = require("fs");
for (const filename of process.argv.slice(2)) {
  const svg = fs.readFileSync(filename, "utf8");
  const viewBox = /viewBox="([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)"/.exec(svg);
  if (!svg.startsWith("<svg") || !viewBox) process.exit(1);
  const [, , , width, height] = viewBox.map(Number);
  const ratio = width / height;
  if (ratio < 0.5 || ratio > 2 || !/<path\b/.test(svg)) process.exit(1);
  if (/<text\b|<image\b|<polygon\b|<rect\b|https?:\/\/|data:|base64/i.test(svg.replace("http://www.w3.org/2000/svg", ""))) process.exit(1);
  if (!/stroke-linecap="round"/.test(svg) || !/stroke-linejoin="round"/.test(svg)) process.exit(1);
}
NODE
then
    _t_ok
else
    _t_bad "mark and favicon are smooth local vector paths without a square frame or wordmark text"
fi
if node - "$REPO/platform/openwrt/webpanel-brand/theme.css" <<'NODE'
const fs = require("fs");
const css = fs.readFileSync(process.argv[2], "utf8");
function value(selector, token) {
  const start = css.indexOf(selector);
  const open = css.indexOf("{", start);
  const close = css.indexOf("}", open);
  if (start < 0 || open < 0 || close < 0) return null;
  const declaration = css.slice(open + 1, close).split(";")
    .map((part) => part.trim()).find((part) => part.startsWith(token + ":"));
  return declaration ? declaration.slice(token.length + 1).trim().toUpperCase() : null;
}
const themes = [
  [":root", "#0C0F0E", "#00BA78"],
  [":root[data-theme=\"light\"]", "#F4F8F7", "#087A70"],
];
const required = ["--ow-canvas", "--ow-surface-1", "--ow-surface-2", "--ow-surface-hover",
  "--ow-surface-selected", "--ow-border-subtle", "--ow-border-strong", "--ow-text-primary",
  "--ow-text-secondary", "--ow-text-tertiary", "--ow-accent", "--ow-accent-hover",
  "--ow-accent-soft", "--ow-brand-violet", "--ow-success", "--ow-warning", "--ow-danger",
  "--ow-info", "--ow-radius-control", "--ow-radius-card", "--ow-radius-panel",
  "--ow-focus-ring", "--ow-shadow-card", "--ow-shadow-popover"];
for (const [selector, canvas, accent] of themes) {
  if (value(selector, "--ow-canvas") !== canvas || value(selector, "--ow-accent") !== accent) process.exit(1);
  for (const token of required) if (!value(selector, token)) process.exit(1);
}
NODE
then
    _t_ok
else
    _t_bad "the complete OpenWrt token system applies in dark and light themes"
fi

# Common UI code travels in the signed updater snapshot; adapter artwork stays
# out of that seed/update map and is refreshed only by the adapter APK.
_common_dest="$(. "$REPO/lib/release_map.sh" 2>/dev/null; Z2K_PLATFORM=openwrt z2k_install_paths webpanel/www/js/core/identity.js 2>/dev/null)"
if [ "$_common_dest" = "/usr/lib/z2k/www/js/core/identity.js" ]; then _t_ok; else _t_bad "common branding module reaches updater path"; fi
_package_dest="$(. "$REPO/lib/release_map.sh" 2>/dev/null; Z2K_PLATFORM=openwrt z2k_install_paths platform/openwrt/webpanel-brand/mark.svg 2>/dev/null)"
if [ -z "$_package_dest" ]; then _t_ok; else _t_bad "adapter asset stays outside common updater mapping"; fi

# Model staging a new complete release over stale docs and compare the
# resulting docroot with each source asset.
_stage="$(mktemp -d "${TMPDIR:-/tmp}/ow-brand.XXXXXX")" || exit 1
mkdir -p "$_stage/usr/lib/z2k/www/assets/openwrt"
for _asset in mark.svg logo.png favicon.svg theme.css profile.json; do
    printf 'stale package bytes\n' > "$_stage/usr/lib/z2k/www/assets/openwrt/$_asset"
    cp "$REPO/platform/openwrt/webpanel-brand/$_asset" \
        "$_stage/usr/lib/z2k/www/assets/openwrt/$_asset"
    cmp -s "$REPO/platform/openwrt/webpanel-brand/$_asset" \
        "$_stage/usr/lib/z2k/www/assets/openwrt/$_asset" \
        && _t_ok || _t_bad "upgrade refreshes installed $_asset bytes"
done

assert_not_contains "single controlled manifest has no component install map" "$REPO/UPDATES.json" '"install_map"'

rm -rf "$_stage"

_t_done
