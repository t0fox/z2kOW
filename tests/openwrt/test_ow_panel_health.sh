#!/bin/sh
# The web panel is healthy only when its required files exist in the complete
# installed release tree. Integrity is enforced earlier on the whole artifact.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-panel-health"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_ROOT="$T/root"
mkdir -p "$Z2K_ROOT/webpanel/cgi" "$Z2K_ROOT/www"
cp -f "$REPO/webpanel/cgi/actions.sh" "$Z2K_ROOT/webpanel/cgi/actions.sh"
cp -f "$REPO/webpanel/cgi/platform.sh" "$Z2K_ROOT/webpanel/cgi/platform.sh"
cp -f "$REPO/webpanel/cgi/api.sh" "$Z2K_ROOT/webpanel/cgi/api.sh"
cp -R "$REPO/webpanel/www/." "$Z2K_ROOT/www/"
cp -f "$REPO/webpanel/lighttpd.conf" "$Z2K_ROOT/webpanel/lighttpd.conf.in"
. "$REPO/platform/openwrt/panel.sh" || exit 1

z2k_ow_panel_payload_compatible && _t_ok || _t_bad "complete panel payload was rejected"
rm -f "$Z2K_ROOT/webpanel/cgi/api.sh"
z2k_ow_panel_payload_compatible && _t_bad "missing panel API was accepted" || _t_ok

_t_done
