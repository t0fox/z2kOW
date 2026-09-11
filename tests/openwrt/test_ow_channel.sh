#!/bin/sh
# tests/openwrt/test_ow_channel.sh - Gap 2: OpenWrt update channel end-to-end.
#   env -> t0fox/z2kOW production branch (не necronicle, не dev-ветка);
#   генератор: keenetic-реген байт-идентичен, openwrt-реген = +platform;
#   gate: openwrt-манифест принят, keenetic/поддельный отвергнуты, тег стоит;
#   старые парсеры слепы к platform-ключу.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-channel"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-ch.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# --- 1. env указывает на OpenWrt-канал ---
(
    unset Z2K_AU_BRANCH Z2K_AU_REPO_RAW GITHUB_RAW
    Z2K_ROOT=/x Z2K_ETC=/y Z2K_TMP=/t
    . "$REPO/platform/openwrt/paths.sh" >/dev/null
    . "$REPO/platform/openwrt/env.sh" >/dev/null
    [ "$Z2K_AU_BRANCH" = "z2k-enhanced-openwrt" ] || exit 1
    case "$Z2K_AU_REPO_RAW" in
        https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt) ;;
        *) exit 1 ;;
    esac
    case "$GITHUB_RAW" in
        https://raw.githubusercontent.com/t0fox/z2kOW/z2k-enhanced-openwrt) ;;
        *) exit 1 ;;
    esac
) && _t_ok || _t_bad "env не указывает на OpenWrt-канал"
if grep -q 'necronicle' "$REPO/platform/openwrt/env.sh"; then
    _t_bad "env.sh ссылается на necronicle (тихий fallback)"
else
    _t_ok
fi

# --- 2. Keenetic-дефолты нетронуты (без env.sh) ---
(
    unset Z2K_AU_BRANCH Z2K_AU_REPO_RAW Z2K_AU_MANIFEST_URL
    . "$REPO/lib/auto_update.sh" >/dev/null 2>&1
    [ "$Z2K_AU_BRANCH" = "z2k-enhanced" ] || exit 1
    case "$Z2K_AU_MANIFEST_URL" in
        *necronicle/z2k/z2k-enhanced/UPDATES.json) ;;
        *) exit 1 ;;
    esac
) && _t_ok || _t_bad "Keenetic-дефолты канала изменились"

# --- 3. генератор end-to-end в worktree (реальный UPDATES.json не трогаем) ---
if WT="$T/wt" git -C "$REPO" worktree add --detach "$T/wt" HEAD >/dev/null 2>&1; then
    _wt_ok=1
    trap 'git -C "$REPO" worktree remove --force "$T/wt" >/dev/null 2>&1; rm -rf "$T"' EXIT INT TERM
    cp "$WT/UPDATES.json" "$T/orig.json"
    ( cd "$WT" && Z2K_PLATFORM=keenetic sh scripts/gen_file_hashes.sh >/dev/null 2>&1 )
    if cmp -s "$WT/UPDATES.json" "$T/orig.json"; then
        _t_ok
    else
        _t_bad "keenetic-реген изменил манифест"
    fi
    ( cd "$WT" && Z2K_PLATFORM=openwrt sh scripts/gen_file_hashes.sh >/dev/null 2>&1 )
    _owdiff="$(diff "$T/orig.json" "$WT/UPDATES.json" | grep -E '^[<>]' || true)"
    echo "$_owdiff" | grep -q '"platform": "openwrt"' && _t_ok \
        || _t_bad "openwrt-реген без platform-маркера: $_owdiff"
    [ "$(printf '%s' "$_owdiff" | grep -cE '^[<>]')" = "2" ] && _t_ok \
        || _t_bad "openwrt-реген тронул лишнее: $_owdiff"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WT/UPDATES.json" \
        && _t_ok || _t_bad "openwrt-манифест не JSON"
else
    _t_bad "worktree недоступен (git worktree add)"
fi

# --- 4. gate функционально ---
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" >/dev/null 2>&1 || exit 1
. "$REPO/lib/auto_update.sh" >/dev/null 2>&1 || exit 1
au_log() { :; }
_mk() {
    # $1 файл; $2 platform-строка (пусто = без ключа); $3 доп. цели install_map
    {
        printf '{"current": "p-9",\n'
        [ -n "$2" ] && printf '  "platform": "%s",\n' "$2"
        printf '  "install_map": {\n   "files/lua/z2k-alert.lua": ["/usr/lib/z2k/lua/z2k-alert.lua"]%s\n  },\n' "$3"
        printf '  "files_sha256": {\n   "files/lua/z2k-alert.lua": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n  },\n'
        printf '  "history": []}\n'
    } > "$1"
}
_mk "$T/ow.json" "openwrt" ""
_mk "$T/keen.json" "" ""
_mk "$T/forged.json" "openwrt" ',\n   "files/S99zapret2.new": ["/opt/etc/init.d/S99zapret2"]'
Z2K_PLATFORM=openwrt; export Z2K_PLATFORM
au_manifest_platform_ok "$T/ow.json" && _t_ok || _t_bad "openwrt-манифест отвергнут"
au_manifest_platform_ok "$T/keen.json" >/dev/null 2>&1 \
    && _t_bad "keenetic-манифест принят на OpenWrt" || _t_ok
au_manifest_platform_ok "$T/forged.json" >/dev/null 2>&1 \
    && _t_bad "поддельный (keenetic-цели) принят" || _t_ok
unset Z2K_PLATFORM
au_manifest_platform_ok "$T/keen.json" && _t_ok || _t_bad "Keenetic без env сломан"
au_manifest_platform_ok "$T/forged.json" && _t_ok || _t_bad "Keenetic без env сломан (2)"

# --- 5. старые парсеры слепы к ключу (та же пара с ключом и без) ---
_pairs_ow="$(au_manifest_pairs "$T/ow.json" | LC_ALL=C sort)"
_mk "$T/ow-nokey.json" "" ""
_pairs_base="$(au_manifest_pairs "$T/ow-nokey.json" | LC_ALL=C sort)"
assert_eq "pairs слепы к platform" "$_pairs_base" "$_pairs_ow"
[ -n "$_pairs_ow" ] && _t_ok || _t_bad "pairs пусты — проверка потеряла смысл"
_tg1="$(au_manifest_install_targets "$T/ow.json" files/lua/z2k-alert.lua)"
assert_eq "targets работают с ключом" "/usr/lib/z2k/lua/z2k-alert.lua" "$_tg1"

_t_done
