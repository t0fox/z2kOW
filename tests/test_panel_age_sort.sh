#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
    printf '[SKIP] сортировка возраста: Node.js не найден\n'
    exit 0
fi
node "$HERE/tests/test_panel_age_sort.cjs"
