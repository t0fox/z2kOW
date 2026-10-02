#!/bin/sh
# Readiness check for bytes delivered in the complete installed release tree.

z2k_ow_panel_payload_check() {
    local _root="${Z2K_ROOT:-/usr/lib/z2k}"
    [ -r "$_root/webpanel/cgi/actions.sh" ] \
        && [ -r "$_root/webpanel/cgi/platform.sh" ] \
        && [ -r "$_root/webpanel/cgi/api.sh" ] \
        && [ -r "$_root/www/index.html" ] \
        && [ -r "$_root/webpanel/lighttpd.conf.in" ]
}

z2k_ow_panel_payload_compatible() {
    z2k_ow_panel_payload_check >/dev/null 2>&1
}
