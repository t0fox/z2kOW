#!/bin/sh
# tests/openwrt/test_ow_package.sh - Step 12: package skeleton целостен.
# Статическая проверка Makefile: имя, BuildPackage, все источники существуют,
# postinst делает bootstrap, prerm останавливает сервис.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-package"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MK="$REPO/package/openwrt/Makefile"
PF="$REPO/package/openwrt/files"

assert_contains "PKG_NAME" "$MK" "PKG_NAME:=z2k-adapter"
assert_contains "BuildPackage" "$MK" "BuildPackage,z2k-adapter"
assert_contains "init.d install" "$MK" "files/etc/init.d/z2k"
assert_contains "hotplug install" "$MK" "files/etc/hotplug.d/iface/90-z2k"
assert_contains "prerm uninstall" "$MK" "z2k_ow_uninstall"
assert_contains "uninstall stops service" "$REPO/platform/openwrt/uninstall.sh" "stop"
assert_contains "uninstall cron" "$REPO/platform/openwrt/uninstall.sh" "z2k_ow_cron_remove"
assert_contains "uninstall purges payload" "$REPO/platform/openwrt/uninstall.sh" 'rm -rf "$Z2K_ROOT"'
assert_contains "uninstall purges tmp" "$REPO/platform/openwrt/uninstall.sh" 'rm -rf "$Z2K_TMP"'
assert_contains "seed builder" "$MK" "make-seed.sh"
assert_contains "materialize in seed" "$REPO/package/openwrt/make-seed.sh" "z2k_ow_materialize"
assert_contains "postinst seed-guard" "$MK" "z2k_ow_seed_ensure"

# conffiles НЕТ осознанно: init/hotplug — package-owned код, обновляется
# вместе с пакетом (Model A). Проверяем STANZA, а не слово (оно есть в
# комментарии-обосновании выше).
if grep -q 'define Package/z2k-adapter/conffiles' "$MK"; then
    _t_bad "conffiles stanza present (должна отсутствовать)"
else
    _t_ok
fi

# Model A: пакет НЕ ставит payload напрямую (только seed) — иначе конфликт
# владения с апдейтером. Прямых lua/fake/lists/lib-строк в install нет.
if grep -A25 'define Package/z2k-adapter/install' "$MK" \
    | grep -E 'files/(lua|fake|lists)|INSTALL_DATA.*\./lib/' >/dev/null; then
    _t_bad "пакет ставит payload напрямую (должен только seed)"
else
    _t_ok
fi

# каждый источник install-цели существует в репо
_missing=""
for _s in etc/init.d/z2k etc/hotplug.d/iface/90-z2k etc/z2k/config.default; do
    [ -f "$PF/$_s" ] || _missing="$_missing $_s"
done
for _s in platform/openwrt/paths.sh platform/openwrt/env.sh \
          platform/openwrt/optbase.sh platform/openwrt/generate.sh \
          platform/openwrt/bootstrap.sh platform/openwrt/materialize.sh \
          platform/openwrt/firewall.sh platform/openwrt/uci.sh \
          lib/utils.sh lib/strategies.sh lib/config_official.sh \
          strats_new2.txt quic_strats.ini; do
    [ -f "$REPO/$_s" ] || [ -e "$REPO/$_s" ] || _missing="$_missing $_s"
done
[ -n "$(ls "$REPO/files/lua/"*.lua 2>/dev/null)" ] || _missing="$_missing files/lua/*.lua"
[ -n "$(ls "$REPO/files/fake/"*.bin 2>/dev/null)" ] || _missing="$_missing files/fake/*.bin"
[ -n "$(ls "$REPO/files/lists/"*.txt 2>/dev/null)" ] || _missing="$_missing files/lists/*.txt"
[ -z "$_missing" ] && _t_ok || _t_bad "источников нет в репо:$_missing"

# conffile-ловушки нет: пакет НЕ ставит /etc/z2k/config (им владеет bootstrap)
if grep -qE '\(1\)/etc/z2k/config' "$MK"; then
    _t_bad "пакет ставит /etc/z2k/config напрямую (должен bootstrap)"
else
    _t_ok
fi

_t_done
