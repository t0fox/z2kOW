#!/bin/sh
# platform/openwrt/uninstall.sh - prerm-логика пакетным удалением (S9).
# Вынесена в функцию, чтобы lifecycle-тесты вызывали ТОТ ЖЕ код, что postinst-
# окружение (Makefile prerm — тонкая обёртка). Никогда не валит удаление.

# z2k_ow_uninstall — остановить, снять свою cron-строку, погасить сервис,
# снести payload-дерево целиком (updater-извлечённые файлы opkg не знает)
# и runtime-/tmp. Убрать ACTIVE installation metadata (marker + tag + dirty +
# fails): после удаления payload они утверждали бы ложь (I1/I2). Сохранить:
# /etc/z2k/config, user-lists/*, daemon-state (state.tsv/discovered/tcp16),
# trust-pin (TOFU канала), чужие cron-строки.
# Требует выставленных Z2K_ROOT/Z2K_ETC/Z2K_TMP (paths.sh).
# Purge = rm -rf /etc/z2k вручную (explicit, отдельно).
z2k_ow_uninstall() {
    "${Z2K_INITSRC:-/etc/init.d/z2k}" stop 2>/dev/null || true
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/schedule.sh" 2>/dev/null && {
        z2k_ow_cron_remove 2>/dev/null || true
        z2k_ow_tg_cron_remove 2>/dev/null || true
        z2k_ow_rt_cron_remove 2>/dev/null || true
        z2k_ow_warp_cron_remove 2>/dev/null || true
        z2k_ow_fw_cron_remove 2>/dev/null || true
    } || true
    # TG firewall (Stage 3): chains И sets из runtime-таблицы — она внешняя
    # и переживает удаление пакета; оставить = litter. Best-effort, рано:
    # дальше сносится payload вместе с самим tg.sh.
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/tg.sh" 2>/dev/null && \
        z2k_ow_tg cleanup 2>/dev/null || true
    # RT (Stage 4): nft + DNS-пины ours. User-DNS не трогаем никогда.
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/rt.sh" 2>/dev/null && \
        z2k_ow_rt cleanup 2>/dev/null || true
    # WARP (Stage 5): PBR down + chains/sets. Device/lists/флаг живут в /etc
    # и переживают удаление по frozen-контракту (purge — вручную).
    Z2K_WARP_SOURCE_ONLY=1; export Z2K_WARP_SOURCE_ONLY
    # shellcheck disable=SC1090,SC1091
    . "$Z2K_ROOT/platform/openwrt/warp.sh" 2>/dev/null && \
        z2k_ow_warp cleanup 2>/dev/null || true
    "${Z2K_INITSRC:-/etc/init.d/z2k}" disable 2>/dev/null || true
    rm -f "$Z2K_ETC/.payload-initialized" \
          "$Z2K_ETC/state/installed-tag" \
          "$Z2K_ETC/state/dirty-tree" \
          "$Z2K_ETC/state/au-delivery-fails" \
          "$Z2K_ETC/state/quic-pool-key-migrated" 2>/dev/null || true
    rm -rf "$Z2K_ROOT" 2>/dev/null || true
    rm -rf "$Z2K_TMP" 2>/dev/null || true
    return 0
}
