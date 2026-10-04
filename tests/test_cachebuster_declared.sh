#!/bin/sh
# tests/test_cachebuster_declared.sh
#
# Кеш-бастер панели правит САМ генератор карты сумм: он вписывает в
# webpanel/www/index.html текущую версию (`app.js?v=<тег>`). А список файлов
# релиза (changed_files) человек пишет РАНЬШЕ, чем запускает генератор — то есть
# на момент составления списка index.html ещё не изменён, и объявить его нельзя
# физически.
#
# На эти грабли наступали трижды подряд (r-71.1, r-72, r-72.1), каждый раз ловили
# руками. Гейт полноты (tests/test_release_manifest_complete.sh) тут не спасает:
# у свежей записи ref ещё PENDING, и он пропускает проверку.
#
# Цена промаха не косметическая: панель у людей осталась бы со старым кешем при
# новой версии — браузер кеширует по URL, и пока суффикс не сменился, новый app.js
# не подхватывается.
#
# Поэтому объявляет тот, кто изменил: генератор сам дописывает index.html в
# changed_files последней записи. Этот тест следит, чтобы поведение не убрали.
#
# POSIX sh.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEN="$ROOT/scripts/gen_file_hashes.sh"
IDX="$ROOT/webpanel/www/index.html"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n      %s\n' "$1" "$2"; }

for f in "$GEN" "$IDX" "$ROOT/UPDATES.json"; do
    [ -f "$f" ] || { no "файлы на месте" "нет $f"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }
done

# 1) Механизм присутствует в генераторе.
if grep -q 'changed_files.*index\.html\|index\.html.*changed_files' "$GEN"; then
    ok "генератор умеет объявлять index.html сам"
else
    no "генератор умеет объявлять index.html сам" \
       "в scripts/gen_file_hashes.sh нет дописывания в changed_files — грабли вернутся"
fi

# UPDATES.json is the only release source of truth. Cache-busters are rendered
# into the staged payload from its controlled current tag; the branded source
# WebPanel must remain untouched when preparing a release candidate.
_manifest="$(cat "$ROOT/UPDATES.json")"

# 2) Stage a temporary copy of the panel at the selected release version. This
#    also covers candidate versions newer than the source checkout's manifest.
cur="$(printf '%s\n' "$_manifest" | sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
candidate="${Z2K_RELEASE_CANDIDATE_VERSION:-$cur}"
if [ -n "$candidate" ] && printf '%s' "$candidate" | grep -Eq '^[pr]-[0-9]+(\.[0-9]+)+$'; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-cachebuster.XXXXXX")" || exit 1
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    mkdir -p "$tmp/www"
    cp -R "$ROOT/webpanel/www/." "$tmp/www/"
    printf '{"current":"%s"}\n' "$candidate" > "$tmp/UPDATES.json"
    if python3 "$ROOT/scripts/openwrt/stamp_panel_assets.py" --root "$tmp/www" --manifest "$tmp/UPDATES.json" \
        && python3 - "$tmp/www" "$candidate" <<'PY'
import pathlib
import re
import sys

root, expected = pathlib.Path(sys.argv[1]), sys.argv[2].encode()
count = 0
for path in root.rglob("*"):
    if path.suffix not in {".html", ".js", ".css"}:
        continue
    data = path.read_bytes()
    versions = re.findall(rb"[?&]v=([pr]-[0-9]+(?:\.[0-9]+)+)", data)
    if versions and any(version != expected for version in versions):
        raise SystemExit(f"stale asset version in {path}")
    count += len(versions)
if count < 6:
    raise SystemExit(f"expected panel asset references in staged tree, found {count}")
PY
    then
        ok "staged panel cache-busters match release candidate ($candidate)"
    else
        no "staged panel cache-busters match release candidate" "stamp failed or staged assets still use an old tag"
    fi
else
    no "staged panel cache-busters match release candidate" "invalid candidate=$candidate (manifest current=$cur)"
fi

# 3) index.html объявлен в changed_files последней записи. Пропускаем, если он
#    в этом релизе и правда не менялся — тогда объявлять нечего.
last="$(printf '%s\n' "$_manifest" | grep '^{"v":' | tail -1)"
if printf '%s' "$last" | grep -q '"webpanel/www/index.html"'; then
    ok "index.html объявлен в changed_files последнего релиза"
else
    # менялся ли он относительно предыдущего коммита
    if git -C "$ROOT" diff --quiet HEAD -- webpanel/www/index.html 2>/dev/null; then
        ok "index.html в этом релизе не менялся — объявлять нечего"
    else
        no "index.html объявлен в changed_files последнего релиза" \
           "файл изменён, но не объявлен — панель уедет со старым кешем"
    fi
fi

printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
