#!/bin/sh
# platform/openwrt/uninstall.sh - prerm-логика пакетным удалением (S9).
# Вынесена в функцию, чтобы lifecycle-тесты вызывали ТОТ ЖЕ код, что postinst-
# окружение (Makefile prerm — тонкая обёртка). Никогда не валит удаление.

# z2k_ow_uninstall — остановить, снять свою cron-строку, погасить сервис,
# снести payload-дерево целиком (updater-извлечённые файлы opkg не знает)
# и runtime-/tmp. НЕ трогает /etc/z2k/* и чужие cron-строки (см. S9).
# Требует выставленных Z2K_ROOT/Z2K_TMP (paths.sh). Путь init-скрипта —
# Z2K_INITSRC (дефолт — пакетный; переопределяем для тестов).
z2k_ow_uninstall() {
    "${Z2K_INITSRC:-/etc/init.d/z2k}" stop 2>/dev/null || true
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/schedule.sh" 2>/dev/null && \
        z2k_ow_cron_remove 2>/dev/null || true
    "${Z2K_INITSRC:-/etc/init.d/z2k}" disable 2>/dev/null || true
    rm -rf "$Z2K_ROOT" 2>/dev/null || true
    rm -rf "$Z2K_TMP" 2>/dev/null || true
    return 0
}
