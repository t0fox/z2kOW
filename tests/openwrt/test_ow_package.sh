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
assert_contains "postinst bootstrap" "$MK" "z2k_ow_bootstrap"
assert_contains "postinst seed first" "$MK" "seed.tar.gz"
assert_contains "prerm stop" "$MK" "init.d/z2k stop"
assert_contains "seed builder" "$MK" "make-seed.sh"
assert_contains "materialize in seed" "$REPO/package/openwrt/make-seed.sh" "z2k_ow_materialize"
assert_contains "conffiles init" "$MK" "/etc/init.d/z2k"
assert_contains "conffiles hotplug" "$MK" "/etc/hotplug.d/iface/90-z2k"

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
