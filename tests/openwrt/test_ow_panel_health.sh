#!/bin/sh
# tests/openwrt/test_ow_panel_health.sh - execute the panel compatibility
# predicate against the production snapshot shape, without loading the common
# updater. Every served frontend file must match the snapshot manifest.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-panel-health"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

export Z2K_ROOT="$T/root"
mkdir -p "$Z2K_ROOT/share" "$Z2K_ROOT/webpanel/cgi" "$Z2K_ROOT/www"
cp -f "$REPO/webpanel/cgi/actions.sh" "$Z2K_ROOT/webpanel/cgi/actions.sh"
cp -f "$REPO/webpanel/cgi/platform.sh" "$Z2K_ROOT/webpanel/cgi/platform.sh"
cp -f "$REPO/webpanel/cgi/api.sh" "$Z2K_ROOT/webpanel/cgi/api.sh"
cp -R "$REPO/webpanel/www/." "$Z2K_ROOT/www/"
cp -f "$REPO/package/openwrt/PANEL_API" "$Z2K_ROOT/share/panel.api"

python3 - "$REPO" "$Z2K_ROOT" <<'PYEOF'
import hashlib
import json
import pathlib
import shutil
import sys

repo = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
paths = [
    "webpanel/cgi/actions.sh",
    "webpanel/cgi/platform.sh",
    "webpanel/cgi/api.sh",
]
paths += [
    path.relative_to(repo).as_posix()
    for path in sorted((repo / "webpanel/www").rglob("*"))
    if path.is_file()
]
install_map = {}
files_sha256 = {}
for source in paths:
    src = repo / source
    if source.startswith("webpanel/www/"):
        dest = "/usr/lib/z2k/www/" + source[len("webpanel/www/"):]
        installed = root / "www" / source[len("webpanel/www/"):]
    else:
        dest = "/usr/lib/z2k/" + source
        installed = root / source
    installed.parent.mkdir(parents=True, exist_ok=True)
    if not installed.exists():
        shutil.copy2(src, installed)
    install_map[source] = [dest]
    files_sha256[source] = hashlib.sha256(src.read_bytes()).hexdigest()
(root / "share/snapshot-manifest.json").write_text(json.dumps({
    "current": "fixture",
    "install_map": install_map,
    "files_sha256": files_sha256,
    "history": [],
}, indent=2) + "\n", encoding="utf-8")
PYEOF
[ "$?" = "0" ] || { _t_bad "build full frontend snapshot fixture"; _t_done; exit 1; }

# Load only the package-owned panel contract, exactly like CGI fallback mode;
# au_manifest_file_sha must not be present to exercise its local parser.
. "$REPO/platform/openwrt/panel.sh" || exit 1
if command -v au_manifest_file_sha >/dev/null 2>&1; then
    _t_bad "test isolation: common updater parser unexpectedly loaded"
else
    _t_ok
fi

if z2k_ow_panel_payload_compatible; then _t_ok; else _t_bad "valid full snapshot was rejected"; fi
if z2k_ow_panel_snapshot_check; then _t_ok; else _t_bad "valid full snapshot hash check failed"; fi

# Stale CGI and frontend bytes fail the compatibility predicate.
for _rel in webpanel/cgi/actions.sh webpanel/cgi/api.sh webpanel/www/js/pages/warp.js; do
    case "$_rel" in
        webpanel/www/*) _installed="$Z2K_ROOT/www/$(printf '%s' "$_rel" | sed 's|^webpanel/www/||')" ;;
        *) _installed="$Z2K_ROOT/$_rel" ;;
    esac
    cp -f "$_installed" "$_installed.good"
    printf '\n# deliberately stale payload\n' >> "$_installed"
    if z2k_ow_panel_payload_compatible; then
        _t_bad "stale $_rel was accepted"
    else
        _t_ok
    fi
    mv -f "$_installed.good" "$_installed"
done

# A newly required module missing from the installed document root must also
# fail closed, even though the CGI files and the rest of the UI are current.
rm -f "$Z2K_ROOT/www/js/core/identity.js"
if z2k_ow_panel_payload_compatible; then
    _t_bad "missing identity.js was accepted"
else
    _t_ok
fi

_t_done
