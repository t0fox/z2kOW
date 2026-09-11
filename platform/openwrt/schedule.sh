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

z2k_ow_cron_install() {
    mkdir -p "$(dirname "$Z2K_CRON_TAB")" 2>/dev/null || return 1
    [ -f "$Z2K_CRON_TAB" ] || : > "$Z2K_CRON_TAB" || return 1
    grep -qF "# z2k-updater" "$Z2K_CRON_TAB" 2>/dev/null && return 0
    printf '%s\n' "$Z2K_CRON_LINE" >> "$Z2K_CRON_TAB" || return 1
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
    grep -vF "# z2k-updater" "$Z2K_CRON_TAB" > "$Z2K_CRON_TAB.new" 2>/dev/null || return 1
    mv -f "$Z2K_CRON_TAB.new" "$Z2K_CRON_TAB" || return 1
    return 0
}
