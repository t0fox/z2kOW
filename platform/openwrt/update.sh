#!/bin/sh
# platform/openwrt/update.sh - package-owned OpenWrt updater entrypoint.
#
# Тонкий execution-context adapter (НЕ fork auto_update.sh):
#   paths.sh -> env.sh -> common libs -> common updater functions.
# Порядок обязателен: дефолты channel/paths/state вычисляются в момент
# сорсинга common-модулей (тест: UPDATER_COMMON_SOURCED_BEFORE_PLATFORM_ENV).
#
# Использование: update.sh [apply|check]
#   apply (default) — unattended-гейт Z2K_AUTO_UPDATE_ENABLED (обход через
#     Z2K_AU_MANUAL=1), jitter для планового пути, затем au_run_apply;
#   check — dry-run без применения (au_run_check).
# Ветки .z2k-branch gate НЕТ: канал = env (Z2K_AU_BRANCH), см. contract.

Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="${Z2K_ETC:-/etc/z2k}"

# PATH cron на OpenWrt урезан (/usr/bin:/bin) — докладываем sbin ВПЕРЕДИ,
# а не сбрасываем целиком: сброс убил бы и тестовые stub'ы, и осознанный
# PATH оператора. Чужих /opt-деревьев не предполагаем.
export PATH="/usr/sbin:/sbin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/paths.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/env.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/bootstrap.sh" || exit 1
. "$Z2K_LIB/utils.sh" || exit 1
. "$Z2K_LIB/auto_update.sh" || exit 1

# shellcheck disable=SC1090,SC1091
. "$Z2K_ROOT/platform/openwrt/reinstall.sh" || exit 1
. "$Z2K_ROOT/platform/openwrt/stack-update.sh" || exit 1

# Platform reinstall policy: full verified payload reinstall
# (z2k_ow_payload_reinstall, контракт §9). Keenetic z2k.sh под root здесь
# выполняться НЕ должен. Executor вызывается au_apply_reinstall ПОСЛЕ
# verified fetch манифеста; провал НЕ двигает тег и НЕ трогает payload
# по построению (files → meta → tag, откат до tag).
Z2K_AU_REINSTALL_EXECUTOR="${Z2K_AU_REINSTALL_EXECUTOR:-z2k_ow_payload_reinstall}"
export Z2K_AU_REINSTALL_EXECUTOR

ACTION="${1:-apply}"

# Метки ручного запуска — та же дисциплина, что в Keenetic entry: прочитать
# в локальные, снять из окружения (иначе утекут в дочерние процессы).
AU_MANUAL="${Z2K_AU_MANUAL:-0}"
AU_NO_JITTER="${Z2K_AU_NO_JITTER:-0}"
unset Z2K_AU_MANUAL Z2K_AU_NO_JITTER

# Narrow fail-safe parser for the unattended destructive path.  Do not use
# safe_config_read here: this gate must notice every explicit supported zero,
# including export/spacing/comments/CRLF, and must stay conservative when a
# config contains conflicting assignments.  It deliberately reads data only;
# the OpenWrt config is executable shell text and must never be sourced here.
z2k_ow_auto_update_disabled() {
    local _cfg="${1:-${Z2K_CONFIG:-/etc/z2k/config}}"
    [ -r "$_cfg" ] || return 1
    awk '
        {
            line = $0
            gsub(/\r/, "", line)
            if (line !~ /^[ \t]*(export[ \t]+)?Z2K_AUTO_UPDATE_ENABLED[ \t]*=/)
                next
            sub(/^[ \t]*/, "", line)
            sub(/^export[ \t]+/, "", line)
            sub(/^Z2K_AUTO_UPDATE_ENABLED[ \t]*=[ \t]*/, "", line)
            sub(/[ \t]*#.*/, "", line)
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line == "0" || line == "\"0\"" || line == "\0470\047")
                found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$_cfg" 2>/dev/null
}

# User gate — только плановый apply; check и ручной apply идут всегда.
if z2k_ow_auto_update_disabled "$Z2K_CONFIG" \
    && [ "$ACTION" = "apply" ] && [ "$AU_MANUAL" != "1" ]; then
    echo "Автообновление отключено в настройках — плановое обновление пропущено."
    mkdir -p "$(dirname "$Z2K_AU_LOG_FILE")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [auto-update] отключено в настройках — плановое обновление пропущено" \
        >> "$Z2K_AU_LOG_FILE" 2>/dev/null
    exit 0
fi

# Pre-flight локальных инвариантов (§9 state-machine) — ДО любого fetch:
# z2k_ow_seed_ensure приводит (marker, payload, tag) к доказанному виду:
# empty -> re-seed (tag := seed), partial+marker -> invalidate + fail,
# mismatch tag/meta -> reconcile, ok -> noop. После него:
# marker present + payload ok + tag == payload.meta, ИНАЧЕ сюда не доходим
# (common first-run resync тем самым недостижим — никакого false-current).
z2k_ow_seed_ensure || exit 1

case "$ACTION" in
    apply)
        # Разброс 0..60 мин — только плановому пути (под cron stdin не tty).
        # Ручной (Z2K_AU_MANUAL=1) не ждёт и БЕЗ отдельного NO_JITTER:
        # manual сам по себе означает no jitter (см. contract §14).
        if [ "${Z2K_OW_PACKAGE_STAGE_DONE:-0}" != 1 ] \
            && [ ! -t 0 ] && [ "$AU_NO_JITTER" != "1" ] && [ "$AU_MANUAL" != "1" ]; then
            JITTER=$(z2k_host_jitter 3600)
            au_log "ночной разброс: жду ${JITTER}с"
            sleep "$JITTER"
        fi
        # For production installs, apply the existing signed OpenWrt package
        # transaction first. A successful transaction requests one launcher
        # re-exec, so the subsequent API gate and payload updater use the newly
        # installed adapter implementation. CI snapshots remain internal and
        # skip this production-only package updater.
        _src=0
        z2k_ow_prepare_stack_apply || _src=$?
        if [ "$_src" = 10 ]; then
            export Z2K_OW_PACKAGE_STAGE_DONE=1
            export Z2K_AU_MANUAL="$AU_MANUAL" Z2K_AU_NO_JITTER="$AU_NO_JITTER"
            exec /bin/sh "$Z2K_ROOT/platform/openwrt/update.sh" apply
        fi
        [ "$_src" = 0 ] || exit "$_src"

        # The package updater has now had the chance to advance the OpenWrt
        # adapter API. Refuse the payload transition before any mutation when
        # the installed adapter still cannot support its required window.
        _grc=0
        z2k_ow_adapter_gate apply || _grc=$?
        [ "$_grc" = 0 ] || exit "$_grc"
        au_run_apply
        ;;
    check)
        # A check never mutates packages; it only gates the signed upstream
        # release window and reports the user-facing p-tag result.
        _grc=0
        z2k_ow_adapter_gate check || _grc=$?
        [ "$_grc" = 0 ] || exit "$_grc"
        au_run_check
        ;;
    *)
        echo "usage: update.sh [apply|check]"
        exit 1
        ;;
esac
