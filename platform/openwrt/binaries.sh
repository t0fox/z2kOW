#!/bin/sh
# platform/openwrt/binaries.sh - fresh-install provisioning z2k-owned binaries.
#
# Дыра: seed.tag == current tag => update transition отсутствует =>
# au_step_refresh_binaries не вызывается => tg-mtproxy-client, z2k-rt-proxy
# и z2k-detect отсутствуют навсегда (warpd — optional, ставится кнопкой
# «Установить WARP»; его отсутствие здесь норма, шаг его пропускает сам).
#
# z2k_ow_ensure_binaries закрывает дыру ТЕМ ЖЕ шагом updater'а (arch mapping,
# manifest hashes, atomic tmp+verify+rename — см. au_step_refresh_binaries),
# но с Z2K_AU_NO_OWNER_START=1: файлы кладутся, сервисы не трогаются.
# Upgrade с валидными бинарниками — NOOP; даунлоадер не дублируется.
#
# Манифест — ДВА режима (fail-closed audit L):
#   snapshot-пакет (сборка положила share/snapshot-manifest.json +
#   share/snapshot-commit): embedded truth АВТОРИТЕТНА — канал не опрашиваем
#   ДАЖЕ если он онлайн. Иначе point-in-time reproducibility ломается в день
#   появления production channel: свежина приедет штатным апдейтером позже,
#   а fresh-provisioning обязан ставить ровно то, что запечено в snapshot.
#   production-пакет (embedded файлов нет): подписанный канал первый.
# Нет сети/манифеста — громкий rc!=0 БЕЗ частичных записей (шаг пишет только
# verified-файлы); старт позже упадёт в preflight с точной причиной,
# а не молчаливым stopped.
#
# Требует выставленных путей (paths.sh + env.sh) и $Z2K_LIB/{utils.sh,
# auto_update.sh}. Вызыватель (postinst) обязан НЕ ронять транзакцию:
# best-effort снаружи, enforcement — в start preflight.

_z2k_ow_manifest_helper_load() {
    command -v z2k_ow_manifest_prepare >/dev/null 2>&1 && return 0
    local _d="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_d/manifest.sh" ] || return 1
    # shellcheck disable=SC1090,SC1091
    . "$_d/manifest.sh"
}

z2k_ow_ensure_binaries() {
    [ -n "${Z2K_BIN:-}" ] || {
        echo "z2k-openwrt: ensure-binaries: нет Z2K_BIN (подключите paths.sh)" >&2
        return 1
    }
    mkdir -p "$Z2K_BIN" 2>/dev/null || {
        echo "z2k-openwrt: ensure-binaries: не создаётся $Z2K_BIN" >&2
        return 1
    }
    Z2K_AU_TMP_DIR="${Z2K_AU_TMP_DIR:-${Z2K_TMP:-/tmp/z2k}/update}"
    export Z2K_AU_TMP_DIR
    mkdir -p "$Z2K_AU_TMP_DIR" 2>/dev/null || {
        echo "z2k-openwrt: ensure-binaries: не создаётся $Z2K_AU_TMP_DIR" >&2
        return 1
    }
    _z2k_ow_manifest_helper_load || {
        echo "z2k-openwrt: ensure-binaries: нет manifest helper" >&2
        return 1
    }
    z2k_ow_manifest_prepare "$Z2K_AU_TMP_DIR/UPDATES.json" || {
        echo "z2k-openwrt: ensure-binaries: не удалось подготовить манифест" >&2
        return 1
    }
    if [ "${Z2K_OW_MANIFEST_MODE:-}" = snapshot ]; then
        au_log "ensure-binaries: snapshot-манифест authoritative ($Z2K_AU_TARGET_REF)"
    fi
    # Только файлы, никаких owner stop/start (см. флаг): postinst не
    # стартует сервисы; владельцы на fresh-установке заведомо не запущены.
    Z2K_AU_NO_OWNER_START=1; export Z2K_AU_NO_OWNER_START
    au_step_refresh_binaries
}
