#!/bin/sh
# tests/openwrt/test_ow_upstream_diff.sh - §8/§13: UPSTREAM_ADAPTER_BOUNDARY.
# Всё, что этап добавил/изменил относительно BASELINE, обязано лежать в:
#   platform/  package/  tests/openwrt/  docs/openwrt-adapter-contract.md
# плюс allowlisted common-хуки (см. ALLOWLIST ниже). Иначе — провал с
# категорией seam'а: будущий upstream merge, задевший наш seam, виден сразу.
#
# После каждого upstream sync BASELINE сдвигается на новый upstream HEAD
# (иначе легитимные upstream-изменения вечно краснят guard).
. "$(dirname "$0")/helper.sh"
_t_plan "ow-upstream-diff"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE="$(cat "$REPO/tests/openwrt/BASELINE")"
export GIT_CONFIG_NOSYSTEM=1
_g="git -c safe.directory=$REPO -C $REPO"

# Разрешённые common-модификации (файл: зачем). Расширять — только с записью
# сюда и в contract § sync invariant.
#   .gitattributes: только +eol=lf (проверяется отдельно ниже)
#   lib/config_official.sh: PHASE3-чтение через ${ZAPRET2_DIR} (§2)
#   lib/release_map.sh: platform-диспетчер + openwrt-таблица (§3)
#   lib/auto_update.sh: targetless fail-safe, Z2K_CONFIG_FILE/merge хуки,
#     platform gate (§3/§6/§2.1)
#   scripts/gen_file_hashes.sh: platform-маркер только для non-keenetic (§2.1;
#     keenetic-реген байт-идентичен — сторожит channel-тест)
#   files/z2k-config-validator.sh: FAKE_DIR + lua EXTRA хуки (freeze audit:
#     без них validate ветирует любой OpenWrt-конфиг)
#   UPDATES.json: ТОЛЬКО files_sha256 hash-обновления allowlisted lib-файлов
#   docs/openwrt-foundation-state-machine.md: модель аудита (docs, не код)
ALLOWLIST=".gitattributes lib/config_official.sh lib/release_map.sh lib/auto_update.sh scripts/gen_file_hashes.sh files/z2k-config-validator.sh UPDATES.json docs/openwrt-foundation-state-machine.md"

_changed="$($_g diff --name-only "$BASELINE"...HEAD 2>/dev/null)"
# --ignore-cr-at-eol: на Windows-чекаутах (autocrlf) весь worktree выглядит
# изменённым; флаг гасит чисто-CRLF шум, настоящие правки остаются видны.
_staged="$($_g diff --ignore-cr-at-eol --name-only --cached 2>/dev/null)"
_unstaged="$($_g diff --ignore-cr-at-eol --name-only 2>/dev/null)"
# -uall: новые каталоги раскрывать пофайлово, иначе guard слеп к составу.
_untracked="$($_g status --porcelain -uall 2>/dev/null | sed -n 's/^?? //p')"
_all="$(printf '%s\n%s\n%s\n%s' "$_changed" "$_staged" "$_unstaged" "$_untracked" | sed '/^[[:space:]]*$/d' | sort -u)"

echo "UPSTREAM_ADAPTER_BOUNDARY:"
echo "COMMON_UPSTREAM_DIFF:"

_seam_of() {
    # $1 — путь; печатает категорию seam'а
    case "$1" in
        files/lua/*) echo "lua" ;;
        *detect*|*circular*|*rotat*) echo "detectors" ;;
        strats_new2.txt|quic_strats.ini|lib/strategies.sh|lib/config_official.sh) echo "strategies" ;;
        webpanel/*) echo "common-webpanel" ;;
        lib/auto_update.sh|lib/release_map.sh|files/z2k-config-validator.sh|scripts/gen_file_hashes.sh) echo "update-system" ;;
        *warp*|*Warp*|*WARP*) echo "warp" ;;
        *) echo "other-common" ;;
    esac
}

if [ -z "$_all" ]; then
    echo "none"
    _t_ok
else
    _bad="$(printf '%s\n' "$_all" | grep -vE '^(platform/|package/|tests/openwrt/|docs/openwrt-adapter-contract\.md$)' || true)"
    # .gitattributes: только чистое добавление eol=lf-строк.
    _attr_ok=""
    if printf '%s\n' "$_bad" | grep -qx '.gitattributes'; then
        _attr_all="$( { $_g diff "$BASELINE"...HEAD -- .gitattributes 2>/dev/null; \
                        $_g diff --cached -- .gitattributes 2>/dev/null; } \
            | grep -E '^[+-]' | grep -vE '^[+-]{3}' || true)"
        _attr_removed="$(printf '%s\n' "$_attr_all" | grep -E '^-' || true)"
        _attr_added="$(printf '%s\n' "$_attr_all" | grep -E '^\+' || true)"
        _attr_foreign="$(printf '%s\n' "$_attr_added" | grep -v -e 'eol=lf' -e '^+#' -e '^\+$' || true)"
        if [ -z "$_attr_removed" ] && [ -n "$_attr_added" ] && [ -z "$_attr_foreign" ]; then
            _attr_ok="1"
        fi
    fi
    _unallowed=""
    for _f in $_bad; do
        case "$_f" in
            .gitattributes) [ -n "$_attr_ok" ] && continue ;;
            lib/config_official.sh|lib/release_map.sh|lib/auto_update.sh|scripts/gen_file_hashes.sh|files/z2k-config-validator.sh|docs/openwrt-foundation-state-machine.md) continue ;;
            UPDATES.json)
                # Манифест следует за деревом: разрешены только hash-обновления
                # allowlisted lib-файлов в files_sha256 (ни новых ключей, ни
                # других секций, ни install_map-правок руками).
                # --ignore-cr-at-eol на worktree-диффах: Windows-чекаут красит
                # весь файл в CRLF-шум (см. шапку файла).
                _umd="$( { $_g diff "$BASELINE"...HEAD -- UPDATES.json 2>/dev/null; \
                            $_g diff --cached -- UPDATES.json 2>/dev/null; \
                            $_g diff --ignore-cr-at-eol -- UPDATES.json 2>/dev/null; } \
                    | grep -E '^[+-]' | grep -vE '^[+-]{3}' || true)"
                _umd_bad="$(printf '%s\n' "$_umd" \
                    | grep -vE '^[+-]  "lib/(config_official|release_map|auto_update)\.sh": "[0-9a-f]{64}",?$' || true)"
                [ -z "$_umd_bad" ] && continue ;;
        esac
        _unallowed="$_unallowed $_f:$(_seam_of "$_f")"
    done
    if [ -z "$_unallowed" ]; then
        echo "none (adapter-only files: $(printf '%s' "$_all" | wc -l | tr -d ' '))"
        echo "ALLOWLISTED: $ALLOWLIST"
        _t_ok
    else
        echo "$_unallowed"
        _t_bad "seam нарушен:$_unallowed"
    fi
fi

_t_done
