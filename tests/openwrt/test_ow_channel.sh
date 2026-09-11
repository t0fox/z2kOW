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
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/release_map.sh" 2>/dev/null || { echo "FAIL[ow-channel]: release_map" >&2; exit 1; }

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

# --- 3. генератор end-to-end в изолированном клоне ---
# Предусловие: дерево, влияющее на regen (lib/scripts/файлы/UPDATES.json),
# ЗАКОММИЧЕНО. Клон собирается из HEAD: при грязном дереве сравнение
# "таблица(worktree) vs regen(committed)" ложно краснеет — скипаем e2e
# честно (остальные секции теста от дерева не зависят).
# (clone, НЕ worktree: у worktree общий gitdir с $REPO, а regen пишет
# UPDATES.json — любая ошибка cd/gen отравила бы настоящий манифест;
# tripwire ниже это сторожит). Реальный UPDATES.json тест не трогает.
_orig_sum="$(cksum "$REPO/UPDATES.json")"
if git -C "$REPO" status --porcelain -- lib scripts files strats_new2.txt quic_strats.ini UPDATES.json webpanel 2>/dev/null | grep -q .; then
    echo "SKIP[ow-channel]: generator e2e needs committed tree"
else
CLONE="$T/clone"
if git clone -q "$REPO" "$CLONE" 2>/dev/null; then
    cp "$CLONE/UPDATES.json" "$T/orig.json"
    ( cd "$CLONE" && Z2K_PLATFORM=keenetic sh scripts/gen_file_hashes.sh >/dev/null 2>&1 )
    if cmp -s "$CLONE/UPDATES.json" "$T/orig.json"; then
        _t_ok
    else
        _t_bad "keenetic-реген изменил манифест"
    fi
    ( cd "$CLONE" && Z2K_PLATFORM=openwrt sh scripts/gen_file_hashes.sh >/dev/null 2>&1 )
    _owdiff="$(diff "$T/orig.json" "$CLONE/UPDATES.json" | grep -E '^[<>]' || true)"
    # +platform ровно один раз
    [ "$(printf '%s\n' "$_owdiff" | grep -c '"platform": "openwrt"')" = "1" ] \
        && _t_ok || _t_bad "platform-маркер не ровно один: $_owdiff"
    # files_sha256 openwrt-пары — keenetic-пары key+hash плюс только ключи
    # С openwrt-маппингом (quic_strats.ini: маппится только на openwrt —
    # keenetic его апдейтером не возит вовсе, см. таблицу).
    # Сравнение по key+hash БЕЗ висячих запятых (позиция последней строки
    # в блоках разная — запятая там текст, а не смысл).
    _shablock() { sed -n '/"files_sha256"/,/^  \},$/p' "$1" | grep -E '^  "' | sed 's/,$//'; }
    _shablock "$T/orig.json" > "$T/sha-orig.txt"
    _sha_new_bad=""
    _sha_extra="$(_shablock "$CLONE/UPDATES.json" | grep -vxFf "$T/sha-orig.txt" || true)"
    for _kl in $(printf '%s\n' "$_sha_extra" | sed 's/^  "//; s/":.*//' ); do
        [ -n "$(Z2K_PLATFORM=openwrt z2k_install_paths "$_kl" 2>/dev/null)" ] \
            || _sha_new_bad="$_sha_new_bad $_kl"
    done
    [ -z "$_sha_new_bad" ] && _t_ok || _t_bad "sha без openwrt-маппинга: $_sha_new_bad"
    # install_map openwrt-линии = таблица: для каждого ключа из ОБОИХ файлов
    # назначения regen обязаны совпасть с z2k_install_paths_for openwrt.
    _keys="$( { grep -oE '^  "[^"]+": \[' "$T/orig.json"; grep -oE '^  "[^"]+": \[' "$CLONE/UPDATES.json"; } \
        | sed 's/^  "//; s/": \[$//' | LC_ALL=C sort -u)"
    _map_bad=""
    for _k in $_keys; do
        _want="$(Z2K_PLATFORM=openwrt z2k_install_paths "$_k" 2>/dev/null | LC_ALL=C sort | tr '\n' '|')"
        _got="$(grep -F "  \"$_k\": [" "$CLONE/UPDATES.json" \
            | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
            | grep -v '^$' | LC_ALL=C sort | tr '\n' '|')"
        [ "$_got" = "$_want" ] || _map_bad="$_map_bad $_k"
    done
    [ -z "$_map_bad" ] && _t_ok || _t_bad "карта не сходится с таблицей:$_map_bad"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CLONE/UPDATES.json" \
        && _t_ok || _t_bad "openwrt-манифест не JSON"
else
    _t_bad "clone недоступен (git clone $REPO)"
fi
fi
# tripwire: настоящий манифест не тронут тестом
assert_eq "UPDATES.json untouched" "$_orig_sum" "$(cksum "$REPO/UPDATES.json")"

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
