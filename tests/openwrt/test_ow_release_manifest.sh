#!/bin/sh
# tests/openwrt/test_ow_release_manifest.sh - Stage 7: генерация OpenWrt-манифеста.
# branch/platform/install_map/api/refs/hashes, keenetic-отсев, ownership,
# dirty-отказ, deliverables для promotion gate (R13/R14).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-manifest"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rman.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
GEN="$REPO/scripts/openwrt/gen-openwrt-manifest.sh"

# --- фиктивное дерево релиза (таблица и ownership — настоящие) ---
mkdir -p "$T/tree/lib" "$T/tree/files" "$T/tree/webpanel/cgi" "$T/tree/package/openwrt"
ln -s "$REPO/lib/release_map.sh" "$T/tree/lib/release_map.sh" || exit 1
ln -s "$REPO/package/openwrt/ownership.map" "$T/tree/package/openwrt/ownership.map" || exit 1
printf '#!/bin/sh\n# fixture lib\n' > "$T/tree/lib/a.sh"
printf '# keenetic only\n' > "$T/tree/files/S99probe.new"
printf '#!/bin/sh\n# fixture cgi\n' > "$T/tree/webpanel/cgi/probe.sh"
mkdir -p "$T/tree/z2k-warpd/builds"
printf 'warp fixture\n' > "$T/tree/z2k-warpd/builds/z2k-warpd-linux-arm64"
_sha_a="$(sha256sum "$T/tree/lib/a.sh" | awk '{print $1}')"
_sha_s="$(sha256sum "$T/tree/files/S99probe.new" | awk '{print $1}')"
_sha_w="$(sha256sum "$T/tree/webpanel/cgi/probe.sh" | awk '{print $1}')"
_sha_warp="$(sha256sum "$T/tree/z2k-warpd/builds/z2k-warpd-linux-arm64" | awk '{print $1}')"
mkdir -p "$T/tree/z2k-detect/builds"
printf 'detect fixture original\n' > "$T/tree/z2k-detect/builds/z2k-detect-linux-arm64"
_sha_detect_original="$(sha256sum "$T/tree/z2k-detect/builds/z2k-detect-linux-arm64" | awk '{print $1}')"
cat > "$T/src.json" <<EOF
{"schema": 1,
"branch": "z2k-enhanced",
"seq": 91,
"current": "p-2",
"install_map": {
  "lib/a.sh": ["/opt/z2k/lib/a.sh"],
  "files/S99probe.new": ["/opt/etc/init.d/S99probe"],
  "webpanel/cgi/probe.sh": ["/opt/z2k/webpanel/cgi/probe.sh"]
},
"files_sha256": {
  "lib/a.sh": "$_sha_a",
  "files/S99probe.new": "$_sha_s",
  "webpanel/cgi/probe.sh": "$_sha_w",
  "z2k-warpd/builds/z2k-warpd-linux-arm64": "$(printf '%064d' 0 | tr '0' 'c')",
  "z2k-detect/builds/z2k-detect-linux-arm64": "$_sha_detect_original"
},
"history": [
{"v": "p-1", "type": "patch", "ref": "p-1", "changed_files": ["lib/a.sh"], "steps": []},
{"v": "p-2", "type": "patch", "ref": "p-2", "changed_files": ["webpanel/cgi/probe.sh"], "steps": []}
]}
EOF

# --- gen: ok с api-min 2 ---
sh "$GEN" --source-manifest "$T/src.json" --tree "$T/tree" --ref "p-2" \
    --api-min 2 --out "$T/out.json" --allow-dirty >/dev/null 2>&1
assert_eq "gen rc" "0" "$?"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/out.json" 2>/dev/null \
    && _t_ok || _t_bad "gen: не JSON"
assert_eq "gen branch" "z2k-enhanced-openwrt" \
    "$(sed -n 's/.*"branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/out.json" | head -1)"
assert_eq "gen platform" "openwrt" \
    "$(sed -n 's/.*"platform"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/out.json" | head -1)"
assert_eq "gen current" "p-2" \
    "$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$T/out.json" | head -1)"
# lib/a.sh — openwrt-dest, без /opt
_got="$(sed -n 's/^  "lib\/a.sh": \[\(.*\)\],*$/\1/p' "$T/out.json" | head -1)"
case "$_got" in
    *"/usr/lib/z2k/lib/a.sh"*) _t_ok ;;
    *) _t_bad "gen: lib/a.sh не в openwrt-dest: $_got" ;;
esac
case "$_got" in
    *"/opt"*) _t_bad "gen: /opt в openwrt-dest" ;;
    *) _t_ok ;;
esac
# S99 (keenetic-only) — выбыл из install_map
if grep -q '"files/S99probe.new": \[' "$T/out.json" 2>/dev/null; then
    _t_bad "gen: keenetic-only остался в install_map"
else
    _t_ok
fi
# webpanel cgi — openwrt-dest под /usr/lib/z2k/webpanel
_gotw="$(sed -n 's/^  "webpanel\/cgi\/probe.sh": \[\(.*\)\],*$/\1/p' "$T/out.json" | head -1)"
case "$_gotw" in
    *"/usr/lib/z2k/webpanel/cgi/probe.sh"*) _t_ok ;;
    *) _t_bad "gen: webpanel cgi не в openwrt-dest: $_gotw" ;;
esac
# api stamp: только current-запись
assert_eq "gen api current" "2" \
    "$(grep '"v": "p-2"' "$T/out.json" | sed -n 's/.*"openwrt_adapter_api_min"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1)"
if grep '"v": "p-1"' "$T/out.json" | grep -q 'openwrt_adapter_api_min'; then
    _t_bad "gen: api затёр старую запись"
else
    _t_ok
fi
# refs целы
assert_eq "gen ref p-2" "p-2" \
    "$(grep '"v": "p-2"' "$T/out.json" | sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
# platform-gate роутера принимает результат
( . "$REPO/lib/utils.sh" >/dev/null 2>&1
  . "$REPO/lib/auto_update.sh" >/dev/null 2>&1
  Z2K_PLATFORM=openwrt au_manifest_platform_ok "$T/out.json" ) >/dev/null 2>&1 \
    && _t_ok || _t_bad "gen: platform-gate отверг результат"
# ownership: ни одна цель не package-owned
_bad=""
sed -n '/"install_map"/,/"files_sha256"/p' "$T/out.json" | grep -oE '"/[^"]*"' | tr -d '"' | sort -u | while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    if grep -qxF "$_d package" "$REPO/package/openwrt/ownership.map" 2>/dev/null; then
        printf 'EXACT %s\n' "$_d" >> "$T/ownbad"
    fi
    case "$_d" in
        /usr/lib/z2k/platform/openwrt/*|/etc/init.d/z2k*|/etc/hotplug.d/*|/usr/lib/z2k/share/seed.tar.gz|/usr/lib/z2k/share/adapter.api)
            printf 'PREFIX %s\n' "$_d" >> "$T/ownbad" ;;
    esac
done
[ -s "$T/ownbad" ] && _t_bad "gen: package-owned в манифесте: $(tr '\n' ' ' < "$T/ownbad")" || _t_ok

# --- sha mismatch: отказ ---
printf '# TAMPERED\n' >> "$T/tree/lib/a.sh"
sh "$GEN" --source-manifest "$T/src.json" --tree "$T/tree" --ref "p-2" \
    --api-min 1 --out "$T/out2.json" --allow-dirty >/dev/null 2>&1 \
    && _t_bad "gen: sha-mismatch принят" || _t_ok
# --- --refresh-stale-hashes: правда дерева с громким списком ---
sh "$GEN" --source-manifest "$T/src.json" --tree "$T/tree" --ref "p-2" \
    --api-min 1 --out "$T/out2r.json" --allow-dirty --refresh-stale-hashes \
    > "$T/refresh.log" 2>&1
assert_eq "gen refresh rc" "0" "$?"
_newsha="$(sha256sum "$T/tree/lib/a.sh" | awk '{print $1}')"
assert_eq "gen refresh: хэш дерева" "$_newsha" \
    "$(sed -n 's/^  "lib\/a.sh": "\(.*\)",\?$/\1/p' "$T/out2r.json" | head -1)"
if grep -q 'refreshed=' "$T/refresh.log" 2>/dev/null && grep -q 'lib/a.sh' "$T/refresh.log" 2>/dev/null; then
    _t_ok
else
    _t_bad "gen refresh: нет громкого списка"
fi
assert_eq "gen refresh: optional WARP hash" "$_sha_warp" \
    "$(sed -n 's/^  "z2k-warpd\/builds\/z2k-warpd-linux-arm64": "\(.*\)",\?$/\1/p' "$T/out2r.json" | head -1)"
if grep -q 'z2k-warpd/builds/z2k-warpd-linux-arm64' "$T/out2r.json" 2>/dev/null \
   && ! grep -A1 '"install_map"' "$T/out2r.json" | grep -q 'z2k-warpd/builds'; then
    _t_ok
else
    _t_bad "gen refresh: WARP hash изменён без install_map destination"
fi
# z2k-detect is the strategy-picker binary and follows the same snapshot-only
# architecture-specific path.  A stale hash here restores the old CLI and
# makes the final picker reject -deadline/-progress-file despite a fresh
# source rebuild.
printf 'detect-fixture\n' > "$T/tree/z2k-detect/builds/z2k-detect-linux-arm64"
_sha_detect="$(sha256sum "$T/tree/z2k-detect/builds/z2k-detect-linux-arm64" | awk '{print $1}')"
sh "$GEN" --source-manifest "$T/src.json" --tree "$T/tree" --ref "p-2" \
    --api-min 1 --out "$T/out2rd.json" --allow-dirty --refresh-stale-hashes \
    > "$T/refresh-detect.log" 2>&1
assert_eq "gen refresh detect rc" "0" "$?"
assert_eq "gen refresh: optional detect hash" "$_sha_detect" \
    "$(sed -n 's/^  "z2k-detect\/builds\/z2k-detect-linux-arm64": "\(.*\)",\?$/\1/p' "$T/out2rd.json" | head -1)"
grep -q 'z2k-detect/builds/z2k-detect-linux-arm64' "$T/out2rd.json" 2>/dev/null \
    && _t_ok || _t_bad "gen refresh: detect hash missing"

# --- dirty tree: отказ без флага ---
rm -rf "$T/grepo" && mkdir -p "$T/grepo" && cd "$T/grepo" || exit 1
git init -q 2>/dev/null || exit 1
git config user.email "t@t" 2>/dev/null; git config user.name "t" 2>/dev/null
: > f && git add f 2>/dev/null && git commit -qm x 2>/dev/null
echo dirty >> f
cd "$REPO" || exit 1
sh "$GEN" --source-manifest "$T/src.json" --tree "$T/grepo" --ref "p-2" \
    --api-min 1 --out "$T/out3.json" >/dev/null 2>&1
assert_eq "gen dirty rc" "1" "$?"

# --- deliverables для promotion gate (R13/R14) ---
printf 'platform/openwrt/warp.sh\npackage/openwrt/Makefile\nlib/a.sh\ndocs/x.md\n' > "$T/changed.txt"
_gotd="$(sh "$GEN" --print-deliverables "$T/changed.txt" 2>/dev/null)"
assert_eq "deliverables: только lib" "lib/a.sh" "$_gotd"
printf 'platform/openwrt/warp.sh\npackage/openwrt/Makefile\n' > "$T/changed-pkg.txt"
_gotd="$(sh "$GEN" --print-deliverables "$T/changed-pkg.txt" 2>/dev/null)"
assert_eq "deliverables: package-only пусто (R13)" "" "$_gotd"

# --- §46: каждый ключ install_map результата — sha + updater-dest ---
# (Никакого ключа без эталона и без цели: молча недоставляемое запрещено.)
python3 - "$T/out.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
mp = m['install_map']
shas = m['files_sha256']
bad = [k for k in mp if k not in shas or not mp[k]]
if bad:
    sys.stderr.write('NO-SHA-OR-DEST: %s\n' % ' '.join(bad))
    sys.exit(1)
print('install_map shape ok: %d keys' % len(mp))
PYEOF
[ "$?" = "0" ] && _t_ok || _t_bad "install_map shape"

_t_done
