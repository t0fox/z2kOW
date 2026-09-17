#!/bin/sh
# platform/openwrt/schedule.sh - периодический запуск updater (cron, вариант B).
#
# Выбор: cron вместо procd-демона — ноль resident-кода ради суточной задачи
# (критерий §11: минимум custom code). Cron-строка одна, jitter — внутри
# launcher (update.sh): cron срабатывает раз в сутки, разброс 0..60 мин
# делает launcher. Ручной запуск — тот же launcher без jitter.
#
# Строка живёт в /etc/crontabs/root (задания выполняются от root; отдельные
# файлы в /etc/crontabs/ crond трактует как чужие crontab). postinst зовёт
# install, prerm — remove. Z2K_CRON_TAB переопределяем для тестов.
#
# Предусловие: paths.sh подключён (Z2K_ROOT в строке cron).

Z2K_CRON_TAB="${Z2K_CRON_TAB:-/etc/crontabs/root}"
Z2K_CRON_LINE="17 2 * * * $Z2K_ROOT/platform/openwrt/update.sh apply # z2k-updater"
# WARP gaming lists: the common helper owns the source parser and atomic list
# refresh; OpenWrt supplies only its payload root and its own log location.
# Keep this as a separate marker so update/install and health schedules do not
# overwrite one another.
Z2K_WARP_GAMES_CRON_LINE="37 2 * * * ZAPRET2_DIR=$Z2K_ROOT CONFIG_FILE=${Z2K_CONFIG:-/etc/z2k/config} Z2K_WARP_IPSET_SCRIPT=$Z2K_ROOT/platform/openwrt/warp.sh LOG_FILE=${Z2K_LOG:-/tmp/z2k/logs}/z2k-warp-games.log sh $Z2K_ROOT/z2k-update-lists.sh warp-games # z2k-warp-games"
# TG health-check (Stage 3): конвергенция rules + probe + kill-only backoff.
# Отдельный маркер и отдельные функции: updater-строку не трогаем.
Z2K_TG_CRON_LINE="*/5 * * * * $Z2K_ROOT/platform/openwrt/tg-check.sh check # z2k-tg-health"
# RT health-check (Stage 4): конвергенция RT + halt-teardown при стойкой
# смерти. Свой маркер, тот же атомарный приём.
Z2K_RT_CRON_LINE="*/5 * * * * $Z2K_ROOT/platform/openwrt/rt-check.sh check # z2k-rt-health"
# WARP selfheal (Stage 5): converge-to-ready-or-fail-open. Каденс честные
# 60 секунд (cron-абстракция — минуты; ложную 25s гарантию не даём).
Z2K_WARP_CRON_LINE="*/1 * * * * $Z2K_ROOT/platform/openwrt/warp-check.sh check # z2k-warp-health"
# Core firewall health (p-84.20): сверка каждого required инварианта, одна
# попытка re-apply, упорный провал снимает ready. Каденс 5 минут, как TG/RT.
Z2K_FW_CRON_LINE="*/5 * * * * $Z2K_ROOT/platform/openwrt/fw-check.sh check # z2k-fw-health"

# Read the selected hour as data.  The config is a shell fragment, so never
# source it from cron/postinst.  The last assignment wins for the normal
# case (matching shell config semantics); an invalid last assignment falls
# back to 02.  Quotes are accepted only around the complete two-digit value.
z2k_ow_schedule_hour() {
    local _cfg="${1:-${Z2K_CONFIG:-/etc/z2k/config}}" _hour
    [ -r "$_cfg" ] || { printf '02'; return 0; }
    _hour=$(awk '
        function trim(s) {
            sub(/^[ \t]+/, "", s)
            sub(/[ \t]+$/, "", s)
            return s
        }
        {
            line = $0
            gsub(/\r/, "", line)
            if (line !~ /^[ \t]*(export[ \t]+)?Z2K_AU_HOUR[ \t]*=/)
                next
            sub(/^[ \t]*/, "", line)
            sub(/^export[ \t]+/, "", line)
            sub(/^Z2K_AU_HOUR[ \t]*=[ \t]*/, "", line)
            sub(/[ \t]*#.*/, "", line)
            line = trim(line)
            if (line ~ /^"[0-9][0-9]"$/ || line ~ /^\047[0-9][0-9]\047$/) {
                line = substr(line, 2, 2)
            }
            seen = 1
            candidate = (line ~ /^[0-9][0-9]$/ && (line + 0) <= 23) ? line : ""
        }
        END {
            print (seen && candidate != "" ? candidate : "02")
        }
    ' "$_cfg" 2>/dev/null)
    case "$_hour" in
        [01][0-9]|2[0-3]) ;;
        *) _hour=02 ;;
    esac
    printf '%s' "$_hour"
}

z2k_ow_cron_install() {
    local _hour
    _hour=$(z2k_ow_schedule_hour "${Z2K_CONFIG:-/etc/z2k/config}") || return 1
    Z2K_CRON_LINE="17 $_hour * * * $Z2K_ROOT/platform/openwrt/update.sh apply # z2k-updater"
    Z2K_WARP_GAMES_CRON_LINE="37 $_hour * * * ZAPRET2_DIR=$Z2K_ROOT CONFIG_FILE=${Z2K_CONFIG:-/etc/z2k/config} Z2K_WARP_IPSET_SCRIPT=$Z2K_ROOT/platform/openwrt/warp.sh LOG_FILE=${Z2K_LOG:-/tmp/z2k/logs}/z2k-warp-games.log sh $Z2K_ROOT/z2k-update-lists.sh warp-games # z2k-warp-games"
    mkdir -p "$(dirname "$Z2K_CRON_TAB")" 2>/dev/null || return 1
    [ -f "$Z2K_CRON_TAB" ] || : > "$Z2K_CRON_TAB" || return 1
    # Дедупликация: схлопываем все старые marker-строки в одну актуальную
    # (иначе правка расписания в новой версии плодила бы дубли).
    # Запись — temp в том же каталоге + rename (shared crontab нельзя
    # оставить обрезанным при сбое).
    awk '!index($0, "# z2k-updater") && !index($0, "# z2k-warp-games")' \
        "$Z2K_CRON_TAB" > "$Z2K_CRON_TAB.new" 2>/dev/null || return 1
    printf '%s\n' "$Z2K_CRON_LINE" >> "$Z2K_CRON_TAB.new" || return 1
    printf '%s\n' "$Z2K_WARP_GAMES_CRON_LINE" >> "$Z2K_CRON_TAB.new" || return 1
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
    awk '!index($0, "# z2k-updater") && !index($0, "# z2k-warp-games")' \
        "$Z2K_CRON_TAB" > "$Z2K_CRON_TAB.new" 2>/dev/null || return 1
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

z2k_ow_rt_cron_install() {
    _z2k_ow_cron_swap_line "# z2k-rt-health" "$Z2K_RT_CRON_LINE" || return 1
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null || true
        pidof crond >/dev/null 2>&1 || /etc/init.d/cron start 2>/dev/null || true
    fi
    return 0
}

z2k_ow_rt_cron_remove() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    _z2k_ow_cron_swap_line "# z2k-rt-health" "" || return 1
    return 0
}

z2k_ow_warp_cron_install() {
    _z2k_ow_cron_swap_line "# z2k-warp-health" "$Z2K_WARP_CRON_LINE" || return 1
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null || true
        pidof crond >/dev/null 2>&1 || /etc/init.d/cron start 2>/dev/null || true
    fi
    return 0
}

z2k_ow_warp_cron_remove() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    _z2k_ow_cron_swap_line "# z2k-warp-health" "" || return 1
    return 0
}

z2k_ow_fw_cron_install() {
    _z2k_ow_cron_swap_line "# z2k-fw-health" "$Z2K_FW_CRON_LINE" || return 1
    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enabled 2>/dev/null || /etc/init.d/cron enable 2>/dev/null || true
        pidof crond >/dev/null 2>&1 || /etc/init.d/cron start 2>/dev/null || true
    fi
    return 0
}

z2k_ow_fw_cron_remove() {
    [ -f "$Z2K_CRON_TAB" ] || return 0
    _z2k_ow_cron_swap_line "# z2k-fw-health" "" || return 1
    return 0
}
