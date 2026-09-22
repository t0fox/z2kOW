#!/bin/sh
# tests/openwrt/test_ow_panel_health.sh - execute the panel compatibility
# predicate against the production snapshot shape, without loading the common
# updater.  The same repo path intentionally appears in install_map first and
# files_sha256 later: this is the live failure that made /status report
# payload_compatible=false on an otherwise current p-85.4 installation.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-panel-health"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-panel-health.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_ROOT="$T/root"
mkdir -p "$Z2K_ROOT/share" "$Z2K_ROOT/webpanel/cgi" "$Z2K_ROOT/www/js/pages"
cp -f "$REPO/webpanel/cgi/actions.sh" "$Z2K_ROOT/webpanel/cgi/actions.sh"
cp -f "$REPO/webpanel/cgi/platform.sh" "$Z2K_ROOT/webpanel/cgi/platform.sh"
cp -f "$REPO/webpanel/cgi/api.sh" "$Z2K_ROOT/webpanel/cgi/api.sh"
cp -f "$REPO/webpanel/www/js/pages/warp.js" "$Z2K_ROOT/www/js/pages/warp.js"
cp -f "$REPO/package/openwrt/PANEL_API" "$Z2K_ROOT/share/panel.api"

_actions_sha="$(sha256sum "$Z2K_ROOT/webpanel/cgi/actions.sh" | awk '{print $1}')"
_platform_sha="$(sha256sum "$Z2K_ROOT/webpanel/cgi/platform.sh" | awk '{print $1}')"
_api_sha="$(sha256sum "$Z2K_ROOT/webpanel/cgi/api.sh" | awk '{print $1}')"
_warp_js_sha="$(sha256sum "$Z2K_ROOT/www/js/pages/warp.js" | awk '{print $1}')"
cat > "$Z2K_ROOT/share/snapshot-manifest.json" <<EOF
{
  "current": "p-85.4",
  "install_map": {
    "webpanel/cgi/actions.sh": ["/usr/lib/z2k/webpanel/cgi/actions.sh"],
    "webpanel/cgi/platform.sh": ["/usr/lib/z2k/webpanel/cgi/platform.sh"],
    "webpanel/cgi/api.sh": ["/usr/lib/z2k/webpanel/cgi/api.sh"],
    "webpanel/www/js/pages/warp.js": ["/usr/lib/z2k/www/js/pages/warp.js"]
  },
  "files_sha256": {
    "webpanel/cgi/actions.sh": "$_actions_sha",
    "webpanel/cgi/platform.sh": "$_platform_sha",
    "webpanel/cgi/api.sh": "$_api_sha",
    "webpanel/www/js/pages/warp.js": "$_warp_js_sha"
  },
  "history": []
}
EOF

# Load only the package-owned panel contract, exactly like CGI fallback mode;
# au_manifest_file_sha must not be present to make this an end-to-end test of
# the code path that failed on the router.
. "$REPO/platform/openwrt/panel.sh" || exit 1
if command -v au_manifest_file_sha >/dev/null 2>&1; then
    _t_bad "test isolation: common updater parser unexpectedly loaded"
else
    _t_ok
fi

if z2k_ow_panel_payload_compatible; then _t_ok; else _t_bad "valid snapshot with duplicate paths was rejected"; fi
if z2k_ow_panel_snapshot_check; then _t_ok; else _t_bad "valid snapshot hash check failed"; fi

# The real predicate must fail closed for every executable/static byte that
# participates in the WARP status contract, not just the platform seam.
for _stale in actions.sh api.sh; do
    printf '\n# deliberately stale payload\n' >> "$Z2K_ROOT/webpanel/cgi/$_stale"
    if z2k_ow_panel_payload_compatible; then
        _t_bad "stale webpanel/cgi/$_stale was accepted"
    else
        _t_ok
    fi
    cp -f "$REPO/webpanel/cgi/$_stale" "$Z2K_ROOT/webpanel/cgi/$_stale"
done
printf '\n// deliberately stale WARP renderer\n' >> "$Z2K_ROOT/www/js/pages/warp.js"
if z2k_ow_panel_payload_compatible; then
    _t_bad "stale webpanel/www/js/pages/warp.js was accepted"
else
    _t_ok
fi

_t_done
