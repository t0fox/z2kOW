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

# User gate — только плановый apply; check и ручной apply идут всегда.
AU_ENABLED=$(safe_config_read "Z2K_AUTO_UPDATE_ENABLED" "$Z2K_CONFIG" "1")
if [ "$AU_ENABLED" = "0" ] && [ "$ACTION" = "apply" ] && [ "$AU_MANUAL" != "1" ]; then
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

# Adapter API gate (Stage 7 §7): ПОСЛЕ seed_ensure, ДО au_run_apply.
# Порядок осознанный: seed_ensure не трогает байты payload (на целом —
# чистый noop, I5), но восстанавливает tag (healed install), а гейту tag
# нужен всегда — иначе установка с потерянным тегом обходила бы проверку
# окна (fresh install закрыт coherence seed на сборке, §10 контракта).
# apply + too old → rc 1; check + too old → ADAPTER_UPDATE_REQUIRED, rc 2.
# Ничего из нового манифеста до гейта не применяется.
_grc=0
z2k_ow_adapter_gate "$ACTION" || _grc=$?
if [ "$_grc" != "0" ]; then exit "$_grc"; fi

case "$ACTION" in
    apply)
        # Разброс 0..60 мин — только плановому пути (под cron stdin не tty).
        # Ручной (Z2K_AU_MANUAL=1) не ждёт и БЕЗ отдельного NO_JITTER:
        # manual сам по себе означает no jitter (см. contract §14).
        if [ ! -t 0 ] && [ "$AU_NO_JITTER" != "1" ] && [ "$AU_MANUAL" != "1" ]; then
            JITTER=$(z2k_host_jitter 3600)
            au_log "ночной разброс: жду ${JITTER}с"
            sleep "$JITTER"
        fi
        au_run_apply
        ;;
    check)
        au_run_check
        ;;
    *)
        echo "usage: update.sh [apply|check]"
        exit 1
        ;;
esac
