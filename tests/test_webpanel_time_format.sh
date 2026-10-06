#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
if command -v node >/dev/null 2>&1; then
    node "$HERE/test_webpanel_time_format.js"
else
    printf '[SKIP] browser-local time formatting (node unavailable)\n'
fi
