#!/bin/sh
# Outbound links stay user-initiated, same-origin assets stay local, and the
# current desktop sidebar collapse control remains inside navigation.

HERE=$(cd "$(dirname "$0")/.." && pwd)
H="$HERE/webpanel/www/index.html"
C="$HERE/webpanel/www/style.css"
T="$HERE/platform/openwrt/webpanel-brand/theme.css"
R="$HERE/README.md"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

for f in "$H" "$C" "$T" "$R"; do
    [ -f "$f" ] || { printf '[FAIL] нет %s\n' "$f"; exit 1; }
done

GH="https://github.com/t0fox/z2kOW"
TG="https://t.me/zapret2keenetic"

eq "sidebar GitHub points to z2kOW" "1" "$(grep -c "href=\"$GH\"" "$H")"
eq "sidebar retains the Telegram link" "1" "$(grep -c "href=\"$TG\"" "$H")"
eq "repository address is present in README" "yes" \
    "$(grep -q "$GH" "$R" && echo yes || echo no)"

_ext=$(grep -c 'href="https://' "$H")
_safe=$(grep 'href="https://' "$H" | grep -c 'target="_blank" rel="noopener noreferrer"')
eq "all external links use noopener" "$_ext" "$_safe"

_nav_open=$(grep -n '<nav id="nav"' "$H" | head -1 | cut -d: -f1)
_nav_close=$(grep -n '</nav>' "$H" | head -1 | cut -d: -f1)
_ext_ln=$(grep -n 'class="nav-external"' "$H" | head -1 | cut -d: -f1)
if [ -n "$_ext_ln" ] && [ -n "$_nav_open" ] && [ -n "$_nav_close" ] \
   && [ "$_ext_ln" -gt "$_nav_open" ] && [ "$_ext_ln" -lt "$_nav_close" ]; then
    ok "footer links stay inside the side navigation"
else
    no "footer inside navigation" "between $_nav_open and $_nav_close" "$_ext_ln"
fi

eq "one collapse control stays inside navigation" "1" \
    "$(awk '/<nav id="nav"/{inside=1} inside && /<button class="sidebar-collapse"/{n++} inside && /<\/nav>/{inside=0} END{print n+0}' "$H")"
if grep -q 'z2k-sidebar' "$HERE/webpanel/www/js/chrome.js" \
   && grep -q 'sidebar-w-collapsed' "$C" "$T"; then
    ok "collapse state is handled by the panel chrome and styles"
else
    no "collapse state is handled by the panel chrome and styles" "state key and collapsed width" "missing"
fi
eq "footer remains pinned to menu bottom" "1" \
    "$(awk '/^#nav \.nav-external \{/,/^\}/' "$C" | grep -c 'margin-top: auto;')"

# No remotely hosted files: the panel works offline; links navigate only on click.
_remote=$(grep -oE '(src|href)="https?://[^\"]+"' "$H" \
    | grep -vE "^href=\"$GH\"$|^href=\"$TG\"$" | head -5)
if [ -z "$_remote" ]; then
    ok "panel embeds no externally hosted files"
else
    no "no external file requests" "only links" "$(printf '%s' "$_remote" | tr '\n' ' ')"
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
