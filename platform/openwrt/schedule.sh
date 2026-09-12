#!/bin/sh
# platform/openwrt/schedule.sh - периодический запуск updater (cron, вариант B).
#
# Выбор: cron вместо procd-демона — ноль resident-кода ради суточной задачи
# (критерий §11: минимум custom code). Cron-строка одна, jitter — внутри
# launcher (update.sh): cron срабатывает раз в сутки, разброс 0..90 мин
# делает launcher. Ручной запуск — тот же launcher без jitter.
#
# Строка живёт в /etc/crontabs/root (задания выполняются от root; отдельные
# файлы в /etc/crontabs/ crond трактует как чужие crontab). postinst зовёт
# install, prerm — remove. Z2K_CRON_TAB переопределяем для тестов.
#
# Предусловие: paths.sh подключён (Z2K_ROOT в строке cron).

Z2K_CRON_TAB="${Z2K_CRON_TAB:-/etc/crontabs/root}"
Z2K_CRON_LINE="17 2 * * * $Z2K_ROOT/platform/openwrt/update.sh apply # z2k-updater"
# TG health-check (Stage 3): конвергенция rules + probe + kill-only backoff.
# Отдельный маркер и отдельные функции: updater-строку не трогаем.
Z2K_TG_CRON_LINE="*/5 * * * * $Z2K_ROOT/platform/openwrt/tg-check.sh check # z2k-tg-health"

z2k_ow_cron_install() {
    mkdir -p "$(dirname "$Z2K_CRON_TAB")" 2>/dev/null || return 1
    [ -f "$Z2K_CRON_TAB" ] || : > "$Z2K_CRON_TAB" || return 1
    # Дедупликация: схлопываем все старые marker-строки в одну актуальную
    # (иначе правка расписания в новой версии плодила бы дубли).
    # Запись — temp в том же каталоге + rename (shared crontab нельзя
    # оставить обрезанным при сбое).
    grep -vF "# z2k-updater" "$Z2K_CRON_TAB" 2>/dev/null > "$Z2K_CRON_TAB.new" || {
        # grep rc=1 = все строки были нашими (или файл пуст): new пуст, и это
        # нормально — ниже допишем единственную строку. rc>1 = реальная ошибка.
        [ $? -eq 1 ] || return 1
        : > "$Z2K_CRON_TAB.new" || return 1
    }
    printf '%s\n' "$Z2K_CRON_LINE" >> "$Z2K_CRON_TAB.new" || return 1
    mv -f "$Z2K_CRON_TAB.new" "$Z2K_CRON_TAB" || return 1
    # cron в части сборок выключен по умолчанию — фиксируем намерение
    # (enable) и поднимаем best-effort, если его нет в процессах; дважды
    # не поднимаем (pidof-guard, не `start` вслепую). postinst от этого
    # не падает никогда.
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null || true
        pidof crond >/dev/null 2>&1 || /etc/init.d/cron start 2>/dev/null || true
    fi
    return 0
}

z2k_ow_cron_remove() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    # Та же атомарность; z2k-only файл (все строки наши) после remove пуст,
    # но цел — grep rc=1 здесь НЕ ошибка (см. install выше).
    grep -vF "# z2k-updater" "$Z2K_CRON_TAB" > "$Z2K_CRON_TAB.new" 2>/dev/null
    _rc=$?
    if [ "$_rc" -gt 1 ]; then
        rm -f "$Z2K_CRON_TAB.new" 2>/dev/null
        return 1
    fi
    [ -f "$Z2K_CRON_TAB.new" ] || : > "$Z2K_CRON_TAB.new"
    mv -f "$Z2K_CRON_TAB.new" "$Z2K_CRON_TAB" || return 1
    return 0
}

# --- TG health cron (тот же атомарный приём, свой маркер) ---

_z2k_ow_cron_swap_line() {
    # $1 marker-to-drop, $2 line-to-add (пусто = только удалить)
    mkdir -p "$(dirname "$Z2K_CRON_TAB")" 2>/dev/null || return 1
    [ -f "$Z2K_CRON_TAB" ] || : > "$Z2K_CRON_TAB" || return 1
    grep -vF "$1" "$Z2K_CRON_TAB" 2>/dev/null > "$Z2K_CRON_TAB.new" || {
        [ $? -eq 1 ] || return 1
        : > "$Z2K_CRON_TAB.new" || return 1
    }
    [ -n "$2" ] && { printf '%s\n' "$2" >> "$Z2K_CRON_TAB.new" || return 1; }
    mv -f "$Z2K_CRON_TAB.new" "$Z2K_CRON_TAB" || return 1
    return 0
}

z2k_ow_tg_cron_install() {
    _z2k_ow_cron_swap_line "# z2k-tg-health" "$Z2K_TG_CRON_LINE" || return 1
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null || true
        pidof crond >/dev/null 2>&1 || /etc/init.d/cron start 2>/dev/null || true
    fi
    return 0
}

z2k_ow_tg_cron_remove() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    _z2k_ow_cron_swap_line "# z2k-tg-health" "" || return 1
    return 0
}
