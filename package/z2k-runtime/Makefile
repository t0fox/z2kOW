# package/z2k-runtime/Makefile - OpenWrt-пакет z2k-zapret2-runtime.
#
# ОТДЕЛЬНАЯ директория (а не станза в package/openwrt/Makefile): PKGARCH,
# PKG_VERSION и PKG_SOURCE в OpenWrt — глобалы файла, и runtime arch-specific
# (arm64 ELF внутри) несовместим с PKGARCH:=all адаптера. Разделение держит
# обе версии честными (build-release.sh парсит версию адаптера первым матчем).
#
# Pin — единственное место правды (§3), дублируется в provenance.json
# (RUNTIME_* через build-release.sh) и в closure-тесте:
#   TAG (upstream tag):            v1.0.5.1-z2k-r2
#   TARBALL:                       zapret2-v1.0.5.1-z2k-r2-openwrt-embedded.tar.gz
#   URL:  https://github.com/necronicle/zapret2-z2k/releases/download/v1.0.5.1-z2k-r2/zapret2-v1.0.5.1-z2k-r2-openwrt-embedded.tar.gz
#   SHA256:                        be3df5508cd0c2bbbfe220aecc5fbf43594d42a3eedf8bcdaa844bb5a01aba8e
#   TARGET ARCH:                   aarch64 (mediatek/filogic); ELF64 AArch64 EXEC,
#                                  static (без PT_INTERP) — доказано CI-гейтом.
# Почему repack, а не сборка из исходников: upstream не публикует .ipk,
# пребилды статичны и musl-clean, install — shell+procd; сборка потребовала бы
# весь LuaJIT/netfilter тулчейн в SDK. Форк necronicle/zapret2-z2k (а не
# bol-van/zapret): те же бинарники + packet-level патчи под ТСПУ, layout
# идентичен upstream (см. lib/install.sh §4).
# Состав: runtime-closure.txt рядом (дрейф сторожит тест).
# Владение: /opt/zapret2/* целиком (класс package в ownership.map updater
# это дерево не пишет никогда).

include $(TOPDIR)/rules.mk

PKG_NAME:=z2k-zapret2-runtime
PKG_VERSION:=1.0.5.1-z2k-r2
PKG_RELEASE:=1
PKG_SOURCE:=zapret2-v1.0.5.1-z2k-r2-openwrt-embedded.tar.gz
PKG_SOURCE_URL:=https://github.com/necronicle/zapret2-z2k/releases/download/v1.0.5.1-z2k-r2/
PKG_HASH:=be3df5508cd0c2bbbfe220aecc5fbf43594d42a3eedf8bcdaa844bb5a01aba8e
# Лицензия upstream не задекларирована (в tarball нет LICENSE, GitHub license
# API пуст и у форка, и у bol-van/zapret): честный Unknown вместо угаданного
# идентификатора. Уточнить при первом bump'е, если upstream задекларирует.
PKG_LICENSE:=Unknown
PKG_MAINTAINER:=z2k contributors

# Topdir внутри tarball — явный (не wildcard): OpenWrt распаковывает PKG_SOURCE
# в PKG_BUILD_DIR БЕЗ strip (tar -C PKG_BUILD_DIR/..), смена layout upstream =
# fail closed (недостающий файл роняет install громко, доказано CI-раном).
Z2K_RT_TOPDIR:=zapret2-v1.0.5.1-z2k-r2
# Бинарный каталог tarball для нашего единственного таргета захардкожен
# (НЕ через $(ARCH)): package-Makefile парсится и сканером метаданных, где
# ARCH пуст, и любой ifneq-гард ронял бы регистрацию пакета молча (поймано
# локальным SDK-репро: пустая stanza в .packageinfo, сборка 0.17с вхолостую).
# Чужой арке здесь неоткуда взяться: guard ниже — в recipe (там ARCH верный),
# плюс adbdump-гейт build-release.sh сверяет arch каждого .apk.
Z2K_RT_BINARCH:=linux-arm64

include $(INCLUDE_DIR)/package.mk

define Package/z2k-zapret2-runtime
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k pinned zapret2 dataplane runtime (nfqws2 + lua + nft functions)
  URL:=https://github.com/necronicle/zapret2-z2k
  # kmod-ядро NFQUEUE-пути (зеркалит check_prerequisites_openwrt upstream:
  # nftables path); curl НЕ нужен (качает SDK на хосте, не роутер).
  DEPENDS:=+nftables +kmod-nft-nat +kmod-nft-offload +kmod-nft-queue
endef

define Package/z2k-zapret2-runtime/description
Pinned zapret2 dataplane runtime for z2k (repack of the upstream embedded
release, verified by SHA256 at build): nfqws2/ip2net/mdig binaries, lua,
nft functions and ipset helpers under /opt/zapret2. Owned
wholly by this package; z2k updater never writes here.
endef

# Компилировать нечего (пребилды): пустые переопределения, как у adapter
# (иначе SDK падает "No targets specified").
define Build/Configure
endef

define Build/Compile
endef

# conffiles НЕТ: дерево runtime целиком owned, пользовательских настроек
# внутри нет (конфиг демона — /etc/z2k/config, user-owned).

# Раскладка — ЯВНО по одному файлу (совпадает с runtime-closure.txt 1:1,
# дрейф сторожит тест побайтно, а не по каталогам): декларативнее
# install_bin.sh и воспроизводимо без запуска чужого кода на хосте сборки.
# lua распаковываем здесь (как Keenetic installer §4: движок ест plain .lua;
# gzip на роутере не требуем).
define Package/z2k-zapret2-runtime/install
	# Arch-guard в recipe (здесь ARCH верный, в отличие от parse-time):
	# пакет arch-specific, чужой таргет — громкий отказ, не чужой бинарь.
	[ "$(ARCH)" = "aarch64" ] || { echo "z2k-zapret2-runtime: unsupported ARCH [$(ARCH)], only aarch64" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/opt/zapret2/nfq2 $(1)/opt/zapret2/ip2net $(1)/opt/zapret2/mdig
	$(INSTALL_DIR) $(1)/opt/zapret2/lua $(1)/opt/zapret2/init.d/openwrt
	$(INSTALL_DIR) $(1)/opt/zapret2/common $(1)/opt/zapret2/ipset
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/binaries/$(Z2K_RT_BINARCH)/nfqws2 $(1)/opt/zapret2/nfq2/nfqws2
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/binaries/$(Z2K_RT_BINARCH)/ip2net $(1)/opt/zapret2/ip2net/ip2net
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/binaries/$(Z2K_RT_BINARCH)/mdig $(1)/opt/zapret2/mdig/mdig
	gzip -dc $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/lua/zapret-lib.lua.gz > $(1)/opt/zapret2/lua/zapret-lib.lua
	gzip -dc $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/lua/zapret-antidpi.lua.gz > $(1)/opt/zapret2/lua/zapret-antidpi.lua
	gzip -dc $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/lua/zapret-auto.lua.gz > $(1)/opt/zapret2/lua/zapret-auto.lua
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/init.d/openwrt/functions $(1)/opt/zapret2/init.d/openwrt/functions
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/base.sh $(1)/opt/zapret2/common/base.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/fwtype.sh $(1)/opt/zapret2/common/fwtype.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/linux_iphelper.sh $(1)/opt/zapret2/common/linux_iphelper.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/ipt.sh $(1)/opt/zapret2/common/ipt.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/nft.sh $(1)/opt/zapret2/common/nft.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/linux_fw.sh $(1)/opt/zapret2/common/linux_fw.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/linux_daemons.sh $(1)/opt/zapret2/common/linux_daemons.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/list.sh $(1)/opt/zapret2/common/list.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/common/custom.sh $(1)/opt/zapret2/common/custom.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/ipset/create_ipset.sh $(1)/opt/zapret2/ipset/create_ipset.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/$(Z2K_RT_TOPDIR)/ipset/def.sh $(1)/opt/zapret2/ipset/def.sh
endef

$(eval $(call BuildPackage,z2k-zapret2-runtime))
