#!/bin/sh
# Раннее восстановление прерванной транзакции z2kOW при загрузке OpenWrt.
# Файл запускается ссылкой S21z2kow-install-recovery до служб z2k и WebPanel.

z2k_ow_boot_recovery_main() {
    local _br_script _br_engine _br_work _br_hook _br_record _br_tag _br_seq
    local _br_state _br_service _br_panel _br_lock _br_tmp_work _br_rc=0

    _br_script="$(readlink -f "$0" 2>/dev/null)" || {
        echo "z2k-openwrt: не удалось определить путь загрузочного восстановления" >&2
        return 1
    }
    [ -n "$_br_script" ] && [ -f "$_br_script" ] || {
        echo "z2k-openwrt: файл загрузочного восстановления недоступен" >&2
        return 1
    }
    _br_engine=${_br_script%/*}
    _br_work=${_br_engine%/*}
    [ "$_br_engine" != "$_br_script" ] \
        && [ "${_br_engine##*/}" = recovery-engine ] \
        && [ "${_br_work##*/}" = .z2k-install ] || {
            echo "z2k-openwrt: неверное расположение движка восстановления" >&2
            return 1
        }

    Z2K_ADAPTER_DIR="$_br_engine"
    # release.sh ожидает эти динамические имена при recovery и HTTP-проверке.
    # Каталог адаптера вычисляется после загрузки сохранённого paths.sh.
    export Z2K_ADAPTER_DIR
    . "$_br_engine/paths.sh" || { echo "z2k-openwrt: не удалось загрузить пути восстановления" >&2; return 1; }
    . "$_br_engine/env.sh" || { echo "z2k-openwrt: не удалось загрузить окружение восстановления" >&2; return 1; }
    . "$_br_engine/release_state.sh" || { echo "z2k-openwrt: не удалось загрузить читатель состояния восстановления" >&2; return 1; }
    . "$_br_engine/release.sh" || { echo "z2k-openwrt: не удалось загрузить движок восстановления" >&2; return 1; }
    # Функции восстановления загружаются из сохранённого движка, но после восстановления
    # HTTP-проверка должна подключить webpanel.sh из восстановленного payload.
    _adapter="$(z2k_ow_path "$Z2K_OW_CANON_ROOT_SUFFIX/platform/openwrt")"
    # procd наследует окружение этого процесса. Сервисы после восстановления должны
    # использовать установленный каталог, а не удаляемый сохранённый движок.
    Z2K_ADAPTER_DIR="$_adapter"
    export Z2K_ADAPTER_DIR

    _br_hook="$(z2k_ow_path /etc/rc.d/S21z2kow-install-recovery)"
    [ -f "$_br_work/recovery-hook" ] && [ ! -L "$_br_work/recovery-hook" ] \
        || { echo "z2k-openwrt: нет доверенной записи загрузочного восстановления; журнал оставлен" >&2; return 1; }
    [ "$(cat "$_br_work/recovery-hook" 2>/dev/null)" = "$_br_hook" ] \
        || { echo "z2k-openwrt: запись загрузочного восстановления не совпадает; журнал оставлен" >&2; return 1; }
    [ -L "$_br_hook" ] && [ "$(readlink "$_br_hook" 2>/dev/null)" = "$_br_script" ] \
        || { echo "z2k-openwrt: загрузочная ссылка восстановления изменилась; журнал оставлен" >&2; return 1; }

    [ -f "$_br_work/temporary-work" ] && [ ! -L "$_br_work/temporary-work" ] \
        || { echo "z2k-openwrt: не найден временный путь транзакции; журнал оставлен" >&2; return 1; }
    _br_tmp_work="$(cat "$_br_work/temporary-work" 2>/dev/null)" || return 1
    case "$_br_tmp_work" in
        /*) ;;
        *) echo "z2k-openwrt: неверный временный путь транзакции; журнал оставлен" >&2; return 1 ;;
    esac
    [ "$_br_tmp_work" != / ] || {
        echo "z2k-openwrt: небезопасный временный путь транзакции; журнал оставлен" >&2
        return 1
    }
    _tmp_work="$_br_tmp_work"

    _br_state="$(z2k_ow_path "${Z2K_OW_INSTALLED_RELEASE_FILE:-/etc/z2k/state/installed-release}")"
    _br_service="$(z2k_ow_path /etc/init.d/z2k)"
    _br_panel="$(z2k_ow_path /etc/init.d/z2k-webpanel)"
    _br_lock="$(z2k_ow_path "${Z2K_OW_INSTALL_LOCK:-/usr/lib/.z2k-install.lock}")"
    z2k_ow_install_lock_acquire "$_br_lock" || return 1

    if [ -f "$_br_work/transaction-active" ]; then
        _br_record="$(z2k_ow_release_state_read "$_br_work/transaction-target" 2>/dev/null)" || {
            echo "z2k-openwrt: цель прерванной транзакции повреждена; журнал оставлен" >&2
            _br_rc=1
        }
        if [ "$_br_rc" = 0 ]; then
            _br_tag="$(printf '%s\n' "$_br_record" | sed -n 's/^tag=//p' | head -1)"
            _br_seq="$(printf '%s\n' "$_br_record" | sed -n 's/^seq=//p' | head -1)"
            z2k_ow_recover_transaction "$_br_work" "$_br_state" \
                "$_br_service" "$_br_tag" "$_br_seq" "$_br_panel" || _br_rc=1
        fi
    else
        # До начала файловой транзакции можно удалить только принадлежащую
        # установщику временную область; чужие пути остаются нетронутыми.
        z2k_ow_cleanup_install_workspace "$_br_work" "$_br_tmp_work" || _br_rc=1
    fi

    z2k_ow_install_lock_release "$_br_lock" || {
        echo "z2k-openwrt: не удалось снять блокировку загрузочного восстановления" >&2
        _br_rc=1
    }
    return "$_br_rc"
}

z2k_ow_boot_recovery_main "$@"
exit $?
