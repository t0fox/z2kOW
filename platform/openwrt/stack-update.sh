#!/bin/sh
# Prepare the OpenWrt part of the single upstream update action. Signed APK
# package installation runs first so the following launcher can enforce the
# new adapter API before applying the upstream payload.
z2k_ow_prepare_stack_apply() {
    # The first process has already completed the package stage. It re-enters
    # the installed launcher so newly installed adapter files and API state are
    # loaded before the payload gate runs.
    if [ "${Z2K_OW_PACKAGE_STAGE_DONE:-0}" = 1 ]; then
        unset Z2K_OW_PACKAGE_STAGE_DONE
        return 0
    fi

    local _cli="${Z2K_PRODUCT_UPDATE_BIN:-/usr/bin/z2kow}" _status _state _rc
    local _manifest="${Z2K_AU_TMP_DIR:-${Z2K_TMP:-/tmp/z2k}/update}/UPDATES.json"
    local _installed _decision _action

    # Keep the signed upstream p-release as the only update authority. The
    # OpenWrt package transaction belongs to an available payload update; a
    # current engine must not trigger an independent product update lane.
    au_fetch_manifest || {
        echo "Не удалось проверить обновление движка zapret2." >&2
        return 1
    }
    _installed="(не установлен)"
    [ -f "${Z2K_AU_INSTALLED_TAG_FILE:-${Z2K_ETC:-/etc/z2k}/state/installed-tag}" ] \
        && _installed=$(cat "${Z2K_AU_INSTALLED_TAG_FILE:-${Z2K_ETC:-/etc/z2k}/state/installed-tag}" 2>/dev/null)
    _decision=$(au_decide "$_installed" "$_manifest") || {
        echo "Не удалось проверить обновление движка zapret2." >&2
        return 1
    }
    _action=$(printf '%s\n' "$_decision" | head -n 1 | awk '{print $1}')
    case "$_action" in
        none) return 0 ;;
        patch|reinstall) ;;
        *)
            echo "Не удалось проверить обновление движка zapret2." >&2
            return 1
            ;;
    esac

    [ -x "$_cli" ] || {
        echo "Не удалось завершить обновление компонентов OpenWrt." >&2
        return 1
    }
    _status=$("$_cli" status --json 2>/dev/null) || {
        echo "Не удалось завершить обновление компонентов OpenWrt." >&2
        return 1
    }
    _state=$(printf '%s\n' "$_status" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$_state" ] || {
        echo "Не удалось завершить обновление компонентов OpenWrt." >&2
        return 1
    }
    case "$_state" in
        snapshot) return 0 ;;
        snapshot-inconsistent)
            echo "Не удалось завершить обновление компонентов OpenWrt." >&2
            return 1
            ;;
    esac

    "$_cli" update --non-interactive >/dev/null 2>&1 || {
        _rc=$?
        echo "Не удалось завершить обновление компонентов OpenWrt." >&2
        return "$_rc"
    }
    # 10 is a private handoff status: update.sh re-execs once to load the files
    # just installed by the established package updater before payload apply.
    return 10
}
