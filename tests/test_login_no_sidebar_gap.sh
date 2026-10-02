#!/bin/sh
# The login route has no side navigation, so its content stays centered.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSS="$ROOT/webpanel/www/style.css"
THEME="$ROOT/platform/openwrt/webpanel-brand/theme.css"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

[ -f "$CSS" ] && [ -f "$THEME" ] || { echo "нет стилей панели"; exit 1; }

_login_block=$(awk '/^body\[data-page="login"\] \{/{f=1} f{print} f && /^\}/{exit}' "$THEME")
if printf '%s' "$_login_block" | grep -qE 'padding-left:[[:space:]]*0'; then
    ok "login clears the desktop sidebar offset"
else
    bad "login does not clear the sidebar offset"
fi

if grep -q 'body\[data-page="login"\] #nav' "$CSS"; then
    ok "sidebar is hidden on the login route"
else
    bad "sidebar is not hidden on the login route"
fi

if grep -Eq 'sidebar-collapse|data-sidebar|sidebar-w-collapsed' "$CSS" "$THEME"; then
    bad "obsolete collapsed-sidebar layout is still present"
else
    ok "fixed-width navigation has no collapsed state"
fi

echo
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
