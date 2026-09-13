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
# PKGARCH:=all: пакет везёт только shell/data (seed — lib/lua/fake/lists/
# strats/webpanel; TG/RT/WARP/z2k-detect едут updater binary flow, НЕ в APK —
# иначе каждый апстрим-бинер требовал бы пересборки, §52). Доказательство —
# ELF-scan seed в tests (test_ow_release_package.sh). Появится arch-специфика
# в пакете — arch станет target'ной; угадывать запрещено (§20).
PKGARCH:=all
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

# Subpackage панели (§22 контракта): только optionality + init + зависимости.
# CGI/www/template едут подписанным updater'ом (§23), НЕ пакетом — иначе
# UI-правки требовали бы пересборки пакета. DEPENDS — только проверенное:
# lighttpd обязателен; mod_cgi/mod_setenv валидируются на старте с громкой
# ошибкой (имена mod-пакетов 25.12-фида подтвердить к Stage 7, не угадывать).
define Package/z2k-webpanel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k webpanel (optional lighttpd frontend over upstream CGI)
  URL:=https://github.com/necronicle/z2k
  DEPENDS:=z2k-adapter +lighttpd
endef

define Package/z2k-webpanel/description
Optional web UI for z2k: dedicated lighttpd instance serving the unchanged
upstream frontend/CGI through a tiny platform adapter. Lifecycle independent
from the core z2k service.
endef

# Пакет — только shell/data (seed собирает make-seed.sh на install-фазе):
# компилировать нечего. Без пустых переопределений SDK пытается гнать
# дефолтный Build/Configure+Build/Compile в пустом build_dir и падает
# "No targets specified" (поймано реальным CI-раном). Стандартный паттерн
# script-only пакетов OpenWrt.
define Build/Configure
endef

define Build/Compile
endef

# conffiles НЕТ осознанно (Model A): init/hotplug — package-owned код,
# обязаны обновляться вместе с пакетом, а не сохраняться как user-config.
# /etc/z2k/* пакет вообще не поставляет (bootstrap создаёт, см. ownership.map
# класс user) — сохранять менеджеру там нечего.

# Корень дерева z2k (in-tree layout: этот Makefile лежит в
# <tree>/package/openwrt/). Через $(CURDIR), НЕ через MAKEFILE_LIST: SDK
# инклудит Makefile относительным путём (через симлинк package/z2k), и
# $(lastword $(MAKEFILE_LIST)) там относителен — abspath от него уводил в
# /home/runner (поймано реальным CI-раном). CURDIR install-рецептов всегда
# абсолютен и равен каталогу пакета (./files/... ниже на него опираются).
Z2K_TREE:=$(abspath $(CURDIR)/../..)

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
	# Adapter API (Stage 7 §6): package-owned source of truth; updater его
	# никогда не перезаписывает. Абсолютный путь через Z2K_TREE (как seed).
	$(INSTALL_DATA) $(Z2K_TREE)/package/openwrt/ADAPTER_API $(1)/usr/lib/z2k/share/adapter.api
	$(INSTALL_DATA) ./platform/openwrt/*.sh $(1)/usr/lib/z2k/platform/openwrt/
	# Entrypoints исполняются напрямую (cron exec, updater [ -x ]) —
	# им нужен +x и в пакете, и в seed (INSTALL_BIN ставит 0755 сам;
	# git-индекс хранит 644 — прямой запуск .sh из дерева в Linux-чекауте
	# падает Permission denied, поэтому везде явный `sh`).
	$(INSTALL_BIN) ./platform/openwrt/update.sh ./platform/openwrt/tg-check.sh \
		./platform/openwrt/rt-check.sh ./platform/openwrt/rt-proc.sh \
		./platform/openwrt/warp.sh ./platform/openwrt/warp-proc.sh \
		./platform/openwrt/warp-check.sh $(1)/usr/lib/z2k/platform/openwrt/
	sh $(Z2K_TREE)/package/openwrt/make-seed.sh $(Z2K_TREE) $(PKG_BUILD_DIR)/seed.tar.gz
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
# WARP selfheal cron (своя строка/маркер).
z2k_ow_warp_cron_install || exit 1
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

define Package/z2k-webpanel/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/z2k-webpanel $(1)/etc/init.d/z2k-webpanel
endef

$(eval $(call BuildPackage,z2k-adapter))
$(eval $(call BuildPackage,z2k-webpanel))
