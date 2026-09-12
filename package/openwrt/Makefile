# package/openwrt/Makefile - OpenWrt-пакет z2k-adapter.
#
# Граница владения (машиночитаемо: ownership.map, сторожит тест):
#   пакет ВЛАДЕЕТ: adapter (platform/openwrt), init/hotplug, метаданные,
#     bootstrap (postinst), дефолт config, seed.tar.gz (bootstrap-seed).
#   пакет НЕ поставляет напрямую: lib/lua/fake/lists/extra_strats/strats —
#     они updater-owned; в пакет едут только внутри seed.tar.gz, postinst
#     извлекает их в /, дальше их перезаписывает подписанный апдейтер.
#   пакет НЕ трогает никогда: /etc/z2k/config, /etc/z2k/state/*,
#     /etc/z2k/user-lists/* (user-owned; bootstrap — только если отсутствует).
#
# Сборка seed: package/openwrt/make-seed.sh (состав = openwrt-назначения
# release_map минус package-owned; Strategy.txt прематериализованы).

include $(TOPDIR)/rules.mk

PKG_NAME:=z2k-adapter
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=z2k contributors
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/z2k-adapter
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k OpenWrt adapter (thin layer over upstream z2k + zapret2 runtime)
  URL:=https://github.com/necronicle/z2k
  DEPENDS:=+kmod-nft-queue +conntrack
endef

define Package/z2k-adapter/description
Minimal OpenWrt adapter for z2k: procd service, path/env bridge,
config generation via untouched upstream libs, firewall delegation
to the zapret2 runtime. No fork of common z2k logic.
endef

# conffiles НЕТ осознанно (Model A): init/hotplug — package-owned код,
# обязаны обновляться вместе с пакетом, а не сохраняться как user-config.
# /etc/z2k/* пакет вообще не поставляет (bootstrap создаёт, см. ownership.map
# класс user) — сохранять менеджеру там нечего.

# Корень дерева z2k (in-tree layout: этот Makefile лежит в
# <tree>/package/openwrt/). Seed собирается из него же.
Z2K_TREE:=$(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)

# ВНИМАНИЕ: пакет намеренно НЕ ставит lib/lua/fake/lists напрямую —
# см. шапку и ownership.map. Источники ниже: adapter (package-owned),
# config-шаблон, seed (собирается make-seed.sh из этого же дерева).
define Package/z2k-adapter/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/usr/lib/z2k/platform/openwrt/custom.d
	$(INSTALL_DIR) $(1)/usr/lib/z2k/share
	$(INSTALL_BIN) ./files/etc/init.d/z2k $(1)/etc/init.d/z2k
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/90-z2k $(1)/etc/hotplug.d/iface/90-z2k
	$(INSTALL_DATA) ./files/etc/z2k/config.default $(1)/usr/lib/z2k/share/config.default
	$(INSTALL_DATA) ./platform/openwrt/*.sh $(1)/usr/lib/z2k/platform/openwrt/
	$(Z2K_TREE)/package/openwrt/make-seed.sh $(Z2K_TREE) $(PKG_BUILD_DIR)/seed.tar.gz
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/seed.tar.gz $(1)/usr/lib/z2k/share/seed.tar.gz
endef

define Package/z2k-adapter/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
Z2K_ROOT="$${Z2K_ROOT:-/usr/lib/z2k}"
# Seed — ТОЛЬКО для неинициализированной установки (marker-правило внутри):
# package upgrade при целом payload ничего не извлекает (Model A).
. "$$Z2K_ROOT/platform/openwrt/paths.sh"
. "$$Z2K_ROOT/platform/openwrt/bootstrap.sh"
z2k_ow_seed_ensure || exit 1
# Ежесуточный updater через cron (строка с маркером, идемпотентно).
. "$$Z2K_ROOT/platform/openwrt/schedule.sh"
z2k_ow_cron_install || exit 1
# TG health-check cron (своя строка/маркер, см. schedule.sh).
z2k_ow_tg_cron_install || exit 1
# RT health-check cron (своя строка/маркер).
z2k_ow_rt_cron_install || exit 1
exit 0
endef

define Package/z2k-adapter/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
Z2K_ROOT="$${Z2K_ROOT:-/usr/lib/z2k}"
Z2K_ETC="$${Z2K_ETC:-/etc/z2k}"
Z2K_TMP="$${Z2K_TMP:-/tmp/z2k}"
# Uninstall policy (см. foundation-state-machine §2 S9): вся логика — в
# z2k_ow_uninstall (та же функция в lifecycle-тестах). Здесь только вызов.
# Ничего здесь не должно валить удаление.
. "$$Z2K_ROOT/platform/openwrt/paths.sh" 2>/dev/null
. "$$Z2K_ROOT/platform/openwrt/uninstall.sh" 2>/dev/null
z2k_ow_uninstall 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,z2k-adapter))
