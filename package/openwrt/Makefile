# package/openwrt/Makefile - OpenWrt-пакет z2k-adapter (skeleton).
#
# Граница владения (см. docs/openwrt-adapter-contract.md):
#   пакет ВЛАДЕЕТ: adapter (platform/openwrt), init/hotplug, метаданные,
#     bootstrap (postinst), дефолт /etc/z2k/config, file mapping payload.
#   пакет НЕ владеет (пока): updater-семантика, common z2k payload как
#     версионируемая сущность — payload копируется как есть из этого дерева.
#
# BUILD-TIME требование: до упаковки выполнить материализацию Strategy.txt
# (payload read-only, в boot-пути её нет):
#   ZAPRET2_DIR=<staging>/usr/lib/z2k CONFIG_DIR=<staging-tmp> \
#     sh -c '. lib/utils.sh; . lib/strategies.sh; . platform/openwrt/materialize.sh;
#            z2k_ow_materialize <staging>/usr/lib/z2k/manifests'
# bootstrap.sh на роутере проверяет результат fail-closed.

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
  DEPENDS:=+kmod-nft-queue
endef

define Package/z2k-adapter/description
Minimal OpenWrt adapter for z2k: procd service, path/env bridge,
config generation via untouched upstream libs, firewall delegation
to the zapret2 runtime. No fork of common z2k logic.
endef

# Mapping repo -> target (см. contract § filesystem):
#   platform/openwrt/*.sh -> /usr/lib/z2k/platform/openwrt/
#   lib/*.sh              -> /usr/lib/z2k/lib/
#   files/lua/*           -> /usr/lib/z2k/lua/
#   files/fake/*          -> /usr/lib/z2k/fake/
#   files/lists/*.txt     -> /usr/lib/z2k/lists/
#   files/lists/extra_strats/* -> /usr/lib/z2k/extra_strats/
#   strats_new2.txt, quic_strats.ini -> /usr/lib/z2k/manifests/
#   files/etc/z2k/config.default -> /usr/lib/z2k/share/config.default
define Package/z2k-adapter/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/usr/lib/z2k/platform/openwrt/custom.d
	$(INSTALL_DIR) $(1)/usr/lib/z2k/lib $(1)/usr/lib/z2k/lua $(1)/usr/lib/z2k/fake
	$(INSTALL_DIR) $(1)/usr/lib/z2k/lists $(1)/usr/lib/z2k/extra_strats
	$(INSTALL_DIR) $(1)/usr/lib/z2k/manifests $(1)/usr/lib/z2k/share
	$(INSTALL_BIN) ./files/etc/init.d/z2k $(1)/etc/init.d/z2k
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/90-z2k $(1)/etc/hotplug.d/iface/90-z2k
	$(INSTALL_DATA) ./files/etc/z2k/config.default $(1)/usr/lib/z2k/share/config.default
	$(INSTALL_DATA) ./platform/openwrt/*.sh $(1)/usr/lib/z2k/platform/openwrt/
	$(INSTALL_DATA) ./lib/*.sh $(1)/usr/lib/z2k/lib/
	$(INSTALL_DATA) ./files/lua/*.lua $(1)/usr/lib/z2k/lua/
	$(INSTALL_DATA) ./files/fake/*.bin $(1)/usr/lib/z2k/fake/
	$(INSTALL_DATA) ./files/lists/*.txt $(1)/usr/lib/z2k/lists/
	cp -a ./files/lists/extra_strats/* $(1)/usr/lib/z2k/extra_strats/
	$(INSTALL_DATA) ./strats_new2.txt ./quic_strats.ini $(1)/usr/lib/z2k/manifests/
endef

define Package/z2k-adapter/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
Z2K_ROOT="$${Z2K_ROOT:-/usr/lib/z2k}"
. "$$Z2K_ROOT/platform/openwrt/paths.sh"
. "$$Z2K_ROOT/platform/openwrt/bootstrap.sh"
z2k_ow_bootstrap || exit 1
exit 0
endef

define Package/z2k-adapter/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/z2k stop 2>/dev/null
/etc/init.d/z2k disable 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,z2k-adapter))
