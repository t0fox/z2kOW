#!/bin/sh
# scripts/openwrt/gen-openwrt-manifest.sh - Stage 7: OpenWrt-манифест из common.
#
# z2k-enhanced-openwrt — НЕ hand-maintained fork: этот скрипт механически
# выводит OpenWrt-манифест из того же release candidate, что и common-релиз
# (история НЕ копируется вручную). Подпись — отдельным шагом ключом payload
# (см. scripts/release.sh: ключ только у оператора).
#
# Что делает:
#   install_map: ключи common-манифеста ∩ openwrt-dests (Z2K_PLATFORM=openwrt,
#     z2k_install_paths). Keenetic-only (S99/ndm//opt-цели) отваливаются сами:
#     у них пусто по построению. Package-owned dests — отказ сборки.
#   files_sha256: те же эталоны, ПЛЮС сверка с байтами дерева (dirty/mismatch
#     ловятся здесь, а не на роутере). Исключение — явный --refresh-stale-hashes
#     (только CI snapshot: дерево новее подписанного snapshot'а, и кандидат
#     обязан нести правду дерева, иначе ему не сойдутся все downstream-чеки;
#     production-путь этот флаг НЕ ставит — там несоответствие = баг релиза).
#   history/current/seq/refs: как в источнике, без переписывания. Новая
#     current-запись получает openwrt_adapter_api_min (по умолчанию "1").
#   branch=z2k-enhanced-openwrt, platform=openwrt.
# Формат вывода — построчный, как у генератора (роутеры разбирают awk/sed).
#
# Использование:
#   gen-openwrt-manifest.sh --source-manifest UPDATES.json --tree DIR
#     --ref TAG --api-min N --out openwrt-UPDATES.json [--allow-dirty]
#     [--refresh-stale-hashes]
#   gen-openwrt-manifest.sh --print-deliverables <changed-files.txt>
#     (promotion gate: какие из изменившихся путей — openwrt deliverables;
#     package-only релиз даёт пусто → payload bump не нужен, R13/R14)
#
# POSIX sh + python3 (как scripts/release.sh).

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

die() { printf 'gen-openwrt-manifest: %s\n' "$1" >&2; exit 1; }

MODE="gen"
SRC=""; TREE=""; REF=""; APIMIN="1"; OUT=""; ALLOW_DIRTY=0; REFRESH_STALE=0
CHANGED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source-manifest) SRC="$2"; shift 2 ;;
        --tree) TREE="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        --api-min) APIMIN="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --refresh-stale-hashes) REFRESH_STALE=1; shift ;;
        --print-deliverables) MODE="deliverables"; CHANGED="$2"; shift 2 ;;
        *) die "неизвестный флаг $1" ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "нужен python3"
# shellcheck disable=SC1090,SC1091
. "$ROOT/lib/release_map.sh" || die "нет lib/release_map.sh"

# Подмножество changed-путей с openwrt-назначениями (promotion gate, R13/R14).
if [ "$MODE" = "deliverables" ]; then
    [ -n "$CHANGED" ] && [ -f "$CHANGED" ] || die "--print-deliverables: нужен файл со списком путей"
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        if [ -n "$(Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null)" ]; then
            printf '%s\n' "$_f"
        fi
    done < "$CHANGED"
    exit 0
fi

[ -n "$SRC" ] && [ -f "$SRC" ] || die "--source-manifest: нужен существующий манифест"
[ -n "$TREE" ] && [ -d "$TREE" ] || die "--tree: нужен корень дерева"
[ -n "$REF" ] || die "--ref: нужен тег/срез (immutable ref reactive window)"
[ -n "$OUT" ] || die "--out: нужен выходной файл"
case "$APIMIN" in
    ''|*[!0-9]*) die "--api-min: целое 1..999" ;;
esac
[ "$APIMIN" -ge 1 ] 2>/dev/null && [ "$APIMIN" -le 999 ] 2>/dev/null \
    || die "--api-min: целое 1..999"

# Чистое дерево — иначе суммы посчитаются по рабочей копии, а ref укажет на
# коммит без этих правок (то же правило, что в scripts/release.sh).
# Сравнение — контентное (--ignore-cr-at-eol): stat-кэш dual-git окружения
# (WSL/Windows) даёт фантомную грязь, а CRLF-шум Windows-чекаута — не грязь.
if [ "$ALLOW_DIRTY" != "1" ]; then
    if ! git -C "$TREE" diff --ignore-cr-at-eol --quiet 2>/dev/null; then
        printf 'gen-openwrt-manifest: в дереве есть незакоммиченные правки:\n' >&2
        git -C "$TREE" diff --ignore-cr-at-eol --name-only 2>/dev/null | sed 's/^/  /' >&2
        die "грязное дерево — манифест собирается из коммитов (или --allow-dirty для проб)"
    fi
fi

# Package-owned цели (точные пути + /*-префиксы): им в payload-манифесте
# делать нечего (PACKAGE ∩ UPDATER = ∅, runtime-гейт в executor тоже есть).
_pkg_exact="$(mktemp)" || exit 1
_pkg_pref="$(mktemp)" || exit 1
trap 'rm -f "$_pkg_exact" "$_pkg_pref"' EXIT INT TERM
sed 's/#.*$//' "$TREE/package/openwrt/ownership.map" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | awk '$2=="package" {print $1}' > "$_pkg_exact"
grep -E '/\*$' "$_pkg_exact" | sed 's|/\*$||' > "$_pkg_pref"
grep -vE '/\*$' "$_pkg_exact" > "$_pkg_exact.tmp" && mv -f "$_pkg_exact.tmp" "$_pkg_exact"

python3 - "$SRC" "$TREE" "$REF" "$APIMIN" "$OUT" "$_pkg_exact" "$_pkg_pref" "$REFRESH_STALE" <<'PYEOF'
import json, sys, hashlib, os, subprocess
src, tree, ref, apimin, out, pkgexact, pkgpref, refresh = sys.argv[1:9]
refresh = (refresh == '1')

def fail(msg):
    sys.stderr.write('gen-openwrt-manifest: %s\n' % msg)
    sys.exit(1)

try:
    raw = open(src, encoding='utf-8').read()
    man = json.loads(raw)
except Exception as e:
    fail('source manifest не JSON: %s' % e)

for k in ('current', 'install_map', 'files_sha256', 'history'):
    if k not in man:
        fail('в source manifest нет "%s"' % k)
cur = man['current']
if not cur:
    fail('пустой current в source manifest')

pkg_exact = set(l.strip() for l in open(pkgexact, encoding='utf-8') if l.strip())
pkg_pref = [l.strip() for l in open(pkgpref, encoding='utf-8') if l.strip()]

def pkg_owned(dest):
    if dest in pkg_exact:
        return True
    return any(dest == p or dest.startswith(p + '/') for p in pkg_pref)

def ow_dests(repo_path):
    # openwrt-назначения через настоящую таблицу (дочерний sh: release_map
    # уже подсвечен в родителе, но python проще вызвать z2k_install_paths
    # напрямую с нужным окружением).
    env = dict(os.environ, Z2K_PLATFORM='openwrt')
    r = subprocess.run(['sh', '-c', '. "$1/lib/release_map.sh" >/dev/null 2>&1; z2k_install_paths "$2"',
                        'sh', tree, repo_path],
                       capture_output=True, text=True, env=env)
    return [l for l in r.stdout.split('\n') if l.startswith('/')]

def tree_sha(repo_path):
    p = os.path.join(tree, repo_path)
    if not os.path.isfile(p) or os.path.islink(p) and not os.path.exists(p):
        return None
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

owmap = {}
owshas = {}
kept = 0
dropped = 0
refreshed = []
for key in man['install_map'].keys():
    dests = ow_dests(key)
    if not dests:
        dropped += 1
        continue
    for d in dests:
        if d.startswith('/opt'):
            fail('keenetic-цель в openwrt-маппинге: %s -> %s' % (key, d))
        if pkg_owned(d):
            fail('package-owned цель в payload-манифесте: %s -> %s' % (key, d))
    want = man['files_sha256'].get(key)
    if not want:
        fail('у %s нет sha256 в source manifest — безэталонная доставка запрещена' % key)
    got = tree_sha(key)
    if got is None:
        fail('нет файла дерева для %s' % key)
    if got != want:
        # Дерево новее snapshot'а (незарелизенные правки mapped-файла):
        # production-путь — отказ (несоответствие = баг релиза); CI snapshot —
        # правда дерева с громким списком (иначе downstream-чеки бессмысленны).
        if refresh:
            refreshed.append(key)
            owshas[key] = got
        else:
            fail('sha дерева != manifest у %s (дерево=%s manifest=%s)' % (key, got, want))
    else:
        owshas[key] = want
    owmap[key] = dests
    kept += 1

# history: как есть; current-записи без api-поля ставим требуемый минимум.
hist = man['history']
if not isinstance(hist, list) or not hist:
    fail('пустая history в source manifest')
stamped = False
for e in hist:
    if not isinstance(e, dict) or e.get('v') != cur:
        continue
    if 'openwrt_adapter_api_min' not in e:
        e['openwrt_adapter_api_min'] = apimin
        stamped = True

def js(v):
    return json.dumps(v, ensure_ascii=False)

lines = []
lines.append('{')
lines.append('  "schema": %s,' % js(man.get('schema', 1)))
lines.append('  "branch": "z2k-enhanced-openwrt",')
lines.append('  "seq": %s,' % js(man.get('seq', 0)))
lines.append('  "current": %s,' % js(cur))
lines.append('  "platform": "openwrt",')
lines.append('  "install_map": {')
items = sorted(owmap.items())
for i, (k, dests) in enumerate(items):
    comma = ',' if i < len(items) - 1 else ''
    lines.append('  %s: [%s]%s' % (js(k), ', '.join(js(d) for d in dests), comma))
lines.append('  },')
lines.append('  "files_sha256": {')
# refreshed-ключи едут с правдой дерева (CI snapshot); остальные — как в источнике.
shas = sorted(((k, owshas.get(k, v)) for k, v in man['files_sha256'].items()))
for i, (k, v) in enumerate(shas):
    comma = ',' if i < len(shas) - 1 else ''
    lines.append('  %s: %s%s' % (js(k), js(v), comma))
lines.append('  },')
lines.append('  "history": [')
for i, e in enumerate(hist):
    comma = ',' if i < len(hist) - 1 else ''
    lines.append('  %s%s' % (js(e), comma))
lines.append('  ]}')
open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

# самопроверка: валидный JSON + platform-gate проходит
json.load(open(out, encoding='utf-8'))
sys.stderr.write('openwrt manifest: current=%s ref=%s api_min=%s%s keys=%d dropped_keenetic=%d refreshed=%d%s\n'
                 % (cur, ref, apimin, ' (stamped)' if stamped else ' (kept)', kept, dropped,
                    len(refreshed), ' [%s]' % ' '.join(sorted(refreshed)) if refreshed else ''))
PYEOF
rc=$?
[ "$rc" = "0" ] || exit "$rc"
# platform-gate поверх результата (тот же предикат, что на роутере).
grep -q '"platform"[[:space:]]*:[[:space:]]*"openwrt"' "$OUT" \
    || die "в результате нет platform=openwrt"
if sed -n '/"install_map"[[:space:]]*:/,/"files_sha256"[[:space:]]*:/p' "$OUT" | grep -q '"/opt/etc/'; then
    die "в openwrt install_map остались keenetic-цели"
fi
printf 'gen-openwrt-manifest: %s готов (подпишите ключом payload перед публикацией)\n' "$OUT"
