#!/bin/sh
# tests/openwrt/test_ow_upstream_diff.sh - Step 13: common upstream untouched.
# Всё, что этап добавил/изменил относительно BASELINE, обязано лежать в:
#   platform/  package/  tests/openwrt/  docs/openwrt-adapter-contract.md
# Плюс ровно одно исключение: .gitattributes, и только добавление eol=lf-строк
# (иначе extensionless файлы слоя уедут в CRLF). Иначе — архитектурный сигнал.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-upstream-diff"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE="$(cat "$REPO/tests/openwrt/BASELINE")"
export GIT_CONFIG_NOSYSTEM=1
_g="git -c safe.directory=$REPO -C $REPO"

_changed="$($_g diff --name-only "$BASELINE"...HEAD 2>/dev/null)"
# --ignore-cr-at-eol: на Windows-чекаутах (autocrlf) весь worktree выглядит
# изменённым; флаг гасит чисто-CRLF шум, настоящие правки остаются видны.
_staged="$($_g diff --ignore-cr-at-eol --name-only --cached 2>/dev/null)"
_unstaged="$($_g diff --ignore-cr-at-eol --name-only 2>/dev/null)"
# -uall: новые каталоги раскрывать пофайлово, иначе guard слеп к составу.
_untracked="$($_g status --porcelain -uall 2>/dev/null | sed -n 's/^?? //p')"
_all="$(printf '%s\n%s\n%s\n%s' "$_changed" "$_staged" "$_unstaged" "$_untracked" | sed '/^[[:space:]]*$/d' | sort -u)"

if [ -z "$_all" ]; then
    echo "COMMON_UPSTREAM_DIFF:"
    echo "none"
    _t_ok
else
    _bad="$(printf '%s\n' "$_all" | grep -vE '^(platform/|package/|tests/openwrt/|docs/openwrt-adapter-contract\.md$)' || true)"
    # Единственное разрешённое исключение: .gitattributes, и только если дифф —
    # чистое добавление eol=lf-строк (без этого extensionless файлы адаптера
    # уезжают в CRLF на Windows-чекаутах и ломаются на роутере).
    if [ "$_bad" = ".gitattributes" ]; then
        # Собираем + / - строки из range-диффа и staged-диффа.
        _attr_all="$( { $_g diff "$BASELINE"...HEAD -- .gitattributes 2>/dev/null; \
                        $_g diff --cached -- .gitattributes 2>/dev/null; } \
            | grep -E '^[+-]' | grep -vE '^[+-]{3}' || true)"
        _attr_removed="$(printf '%s\n' "$_attr_all" | grep -E '^-' || true)"
        _attr_added="$(printf '%s\n' "$_attr_all" | grep -E '^\+' || true)"
        _attr_foreign="$(printf '%s\n' "$_attr_added" | grep -v -e 'eol=lf' -e '^+#' -e '^\+$' || true)"
        if [ -z "$_attr_removed" ] && [ -n "$_attr_added" ] && [ -z "$_attr_foreign" ]; then
            _bad=""
        fi
    fi
    echo "COMMON_UPSTREAM_DIFF:"
    if [ -z "$_bad" ]; then
        echo "none (adapter-only files: $(printf '%s' "$_all" | wc -l | tr -d ' '))"
        _t_ok
    else
        echo "$_bad"
        _t_bad "вне allowlist: $_bad"
    fi
fi

_t_done
