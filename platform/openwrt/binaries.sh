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
# Манифест: $Z2K_AU_TMP_DIR/UPDATES.json; отсутствует — тянем au_fetch_manifest
# (подписанный канал; свежий install — TOFU). Нет сети/манифеста — громкий
# rc!=0 БЕЗ частичных записей (шаг пишет только verified-файлы); старт позже
# упадёт в preflight с точной причиной, а не молчаливым stopped.
#
# Требует выставленных путей (paths.sh + env.sh) и $Z2K_LIB/{utils.sh,
# auto_update.sh}. Вызыватель (postinst) обязан НЕ ронять транзакцию:
# best-effort снаружи, enforcement — в start preflight.

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
    if [ ! -s "$Z2K_AU_TMP_DIR/UPDATES.json" ]; then
        if au_fetch_manifest 2>/dev/null; then
            : # канал ok — production path (подписанный канал всегда первый)
        elif [ -s "$Z2K_ROOT/share/snapshot-manifest.json" ] && \
             [ -s "$Z2K_ROOT/share/snapshot-commit" ]; then
            # Snapshot fallback: канала нет (офлайн/снапшот до релиза ветки),
            # но сборка положила point-in-time truth. Привязка к коммиту —
            # immutable raw-URL вместо плавающей ветки.
            cp -f "$Z2K_ROOT/share/snapshot-manifest.json" \
                "$Z2K_AU_TMP_DIR/UPDATES.json" 2>/dev/null || {
                echo "z2k-openwrt: ensure-binaries: snapshot-манифест не лёг" >&2
                return 1
            }
            Z2K_AU_TARGET_REF="$(tr -d ' \t\r\n' < "$Z2K_ROOT/share/snapshot-commit" 2>/dev/null)"
            case "$Z2K_AU_TARGET_REF" in
                ''|*[!0-9a-f]*) echo "z2k-openwrt: ensure-binaries: бит snapshot-commit" >&2; return 1 ;;
            esac
            export Z2K_AU_TARGET_REF
            au_manifest_platform_ok "$Z2K_AU_TMP_DIR/UPDATES.json" || return 1
            au_log "ensure-binaries: канал недоступен — snapshot-манифест ($Z2K_AU_TARGET_REF)"
        else
            echo "z2k-openwrt: ensure-binaries: нет манифеста (сеть/канал?)" >&2
            return 1
        fi
    fi
    # Только файлы, никаких owner stop/start (см. флаг): postinst не
    # стартует сервисы; владельцы на fresh-установке заведомо не запущены.
    Z2K_AU_NO_OWNER_START=1; export Z2K_AU_NO_OWNER_START
    au_step_refresh_binaries
}
