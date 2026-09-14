#!/bin/sh
# tests/openwrt/test_ow_runtime_package.sh - статика пакета z2k-zapret2-runtime.
# Pin, состав, зависимости, arch-guard — всё, что делает пакет пакетом.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-runtime-package"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MK="$REPO/package/z2k-runtime/Makefile"
ADAPT="$REPO/package/openwrt/Makefile"

assert_file "runtime Makefile существует" "$MK"
assert_contains "runtime PKG_NAME" "$MK" "PKG_NAME:=z2k-zapret2-runtime"
assert_contains "runtime stanza" "$MK" "define Package/z2k-zapret2-runtime"
assert_contains "runtime BuildPackage" "$MK" "BuildPackage,z2k-zapret2-runtime"

# Pin (§3): tag/url/sha в одном месте, точные строки.
assert_contains "pin tag" "$MK" "Z2K_RT_TAG:=v1.0.5.1-z2k-r2"
assert_contains "pin tarball" "$MK" "zapret2-v1.0.5.1-z2k-r2-openwrt-embedded.tar.gz"
assert_contains "pin url" "$MK" "https://github.com/necronicle/zapret2-z2k/releases/download/v1.0.5.1-z2k-r2/"
assert_contains "pin sha" "$MK" "PKG_HASH:=be3df5508cd0c2bbbfe220aecc5fbf43594d42a3eedf8bcdaa844bb5a01aba8e"
assert_contains "pin topdir" "$MK" "Z2K_RT_TOPDIR:=zapret2-v1.0.5.1-z2k-r2"
assert_contains "pin binarch" "$MK" "Z2K_RT_BINARCH:=linux-arm64"
assert_contains "unpack strips topdir" "$MK" 'PKG_UNPACK=tar -C $(PKG_BUILD_DIR) --strip-components=1 -xzf $(DL_DIR)/$(PKG_SOURCE)'

# APK-версия — digits only + numeric release (дефисы запрещены грамматикой
# APK: "1.0.5.1-z2k-r2-r1 invalid", доказано CI-раном; repack идёт счётчиком).
assert_contains "apk version digits" "$MK" "PKG_VERSION:=1.0.5.1"
assert_contains "apk release tracks repack" "$MK" "PKG_RELEASE:=2"
if grep -qE '^PKG_(VERSION|RELEASE):=.*-' "$MK"; then
    _t_bad "дефис в PKG_VERSION/RELEASE (invalid APK version)"
else
    _t_ok
fi

# Arch-guard: только тестируемый таргет, чужая арка — fail closed.
# Гард ЖИВЁТ в recipe (там ARCH верный): parse-time ifneq ронял регистрацию
# пакета молча (scan без ARCH), доказано SDK-репро.
assert_contains "arch guard recipe" "$MK" '[ "$(ARCH)" = "aarch64" ]'
assert_contains "arch guard msg" "$MK" 'unsupported ARCH'
assert_contains "binarch hardcode" "$MK" 'Z2K_RT_BINARCH:=linux-arm64'

# DEPENDS runtime: ядро NFQUEUE-пути (зеркало upstream prereqs).
_dep="$(sed -n '/^define Package\/z2k-zapret2-runtime$/,/^endef$/p' "$MK" 2>/dev/null | grep -E '^  DEPENDS:=')"
assert_eq "DEPENDS exact" "  DEPENDS:=+nftables +kmod-nft-nat +kmod-nft-offload +kmod-nft-queue" "$_dep"

# Adapter зависит от runtime (fresh install без него — нерабочий продукт).
assert_contains "adapter depends runtime" "$ADAPT" "+z2k-zapret2-runtime"

# conffiles нет: дерево runtime целиком owned, настроек внутри нет.
if grep -q 'define Package/z2k-zapret2-runtime/conffiles' "$MK"; then
    _t_bad "conffiles stanza present (должна отсутствовать)"
else
    _t_ok
fi

# Версия адаптера — по-прежнему первый PKG_VERSION в его Makefile
# (build-release.sh парсит первым матчем; runtime-версии живут отдельно).
_ver1="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$ADAPT" | head -1 | tr -d ' \t\r\n')"
assert_eq "adapter version first" "0.1.0" "$_ver1"

# Preflight wiring (§7): init зовёт проверку ДО procd, firewall её определяет.
INIT="$REPO/package/openwrt/files/etc/init.d/z2k"
FW="$REPO/platform/openwrt/firewall.sh"
assert_contains "preflight defined" "$FW" "z2k_ow_runtime_preflight() {"
assert_contains "preflight msg" "$FW" "runtime_missing:"
assert_contains "init calls preflight" "$INIT" "z2k_ow_runtime_preflight || return 1"
_lp="$(grep -n 'z2k_ow_runtime_preflight || return 1' "$INIT" | head -1 | cut -d: -f1)"
_lo="$(grep -n 'procd_open_instance' "$INIT" | head -1 | cut -d: -f1)"
if [ -n "$_lp" ] && [ -n "$_lo" ] && [ "$_lp" -lt "$_lo" ]; then _t_ok
else _t_bad "init: preflight не до procd ($_lp/$_lo)"; fi

# Wanted semantics (§6): TG/RT скипаются без бинарника (контролируемо),
# WARP — optional (кнопка). Якоря guards, не дающие исполнить missing binary.
assert_contains "tg wanted guard" "$REPO/platform/openwrt/tg.sh" "z2k_ow_tg_wanted"
assert_contains "rt wanted guard" "$REPO/platform/openwrt/rt.sh" "z2k_ow_rt_wanted"
assert_contains "warp wanted guard" "$REPO/platform/openwrt/warp.sh" "warp_wanted_boot"

# postinst: ensure-binaries best-effort (транзакцию не роняет).
assert_contains "postinst ensure hook" "$ADAPT" "z2k_ow_ensure_binaries"
assert_contains "postinst env first" "$ADAPT" "platform/openwrt/env.sh"

_t_done
