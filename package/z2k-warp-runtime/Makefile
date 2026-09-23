# OpenWrt-only z2k-warpd build with the nft PairSet backend.
# The upstream prebuilt binaries retain Keenetic's ipset backend; this package
# compiles the same p-85.10 source for the router and installs it at a
# package-owned path so the WARP feature updater cannot overwrite it.

include $(TOPDIR)/rules.mk

PKG_NAME:=z2k-warp-runtime
PKG_VERSION:=85.10.0
PKG_RELEASE:=1
PKGARCH:=aarch64_cortex-a53
PKG_MAINTAINER:=z2k contributors
PKG_LICENSE:=Unknown

include $(INCLUDE_DIR)/package.mk

Z2K_TREE:=$(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

define Package/z2k-warp-runtime
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k WARP runtime with OpenWrt nft domain routing
  URL:=https://github.com/necronicle/z2k
  DEPENDS:=+kmod-nfnetlink-log
endef

define Package/z2k-warp-runtime/description
OpenWrt-target z2k-warpd built from the signed p-85.10 source tree. The
package enables passive IPv4 DNS observation and client-scoped nft routing;
the upstream Keenetic binary remains unchanged and keeps its ipset backend.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/src/openwrt-overlay
	$(CP) $(Z2K_TREE)/z2k-warpd/go.mod $(Z2K_TREE)/z2k-warpd/go.sum $(PKG_BUILD_DIR)/src/
	$(CP) -a $(Z2K_TREE)/z2k-warpd/cmd $(Z2K_TREE)/z2k-warpd/internal $(PKG_BUILD_DIR)/src/
	$(CP) -a $(Z2K_TREE)/z2k-warpd/third_party $(PKG_BUILD_DIR)/src/
	$(CP) $(Z2K_TREE)/z2k-warpd/openwrt-overlay/overlay.json $(Z2K_TREE)/z2k-warpd/openwrt-overlay/go.mod $(PKG_BUILD_DIR)/src/openwrt-overlay/
	$(CP) $(Z2K_TREE)/z2k-warpd/openwrt-overlay/ipset.go $(PKG_BUILD_DIR)/src/openwrt-overlay/
endef

define Build/Configure
endef

define Build/Compile
	[ "$(ARCH)" = "aarch64" ] || { echo "z2k-warp-runtime: unsupported ARCH [$(ARCH)], only aarch64" >&2; exit 1; }
	cd $(PKG_BUILD_DIR)/src && go test -tags openwrt -overlay openwrt-overlay/overlay.json ./...
	cd $(PKG_BUILD_DIR)/src && GOTOOLCHAIN=local GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build -tags openwrt -overlay openwrt-overlay/overlay.json -trimpath -buildvcs=false \
		-ldflags="-s -w -X main.version=p-85.10-openwrt" \
		-o $(PKG_BUILD_DIR)/z2k-warpd ./cmd/z2k-warpd
endef

define Package/z2k-warp-runtime/install
	[ "$(ARCH)" = "aarch64" ] || { echo "z2k-warp-runtime: unsupported ARCH [$(ARCH)], only aarch64" >&2; exit 1; }
	$(INSTALL_DIR) $(1)/usr/lib/z2k/platform/openwrt/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/z2k-warpd $(1)/usr/lib/z2k/platform/openwrt/bin/z2k-warpd
endef

$(eval $(call BuildPackage,z2k-warp-runtime))
