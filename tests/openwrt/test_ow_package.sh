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
assert_contains "customd bridge install" "$MK" "platform/openwrt/*.sh"
assert_contains "upstream STUN helper install" "$MK" "custom.d/50-stun4all"
assert_contains "upstream Discord helper install" "$MK" "custom.d/50-discord-media"
assert_file "customd bridge source exists" "$REPO/platform/openwrt/customd.sh"
assert_file "upstream STUN helper source exists" "$REPO/platform/openwrt/custom.d/50-stun4all"
assert_file "upstream Discord helper source exists" "$REPO/platform/openwrt/custom.d/50-discord-media"
assert_file "diagnostics source exists" "$REPO/files/z2k-diag.sh"
assert_contains "adapter installs diagnostics helper at runtime lookup path" "$MK" \
    '$(Z2K_TREE)/files/z2k-diag.sh $(1)/usr/lib/z2k/z2k-diag.sh'
assert_contains "diagnostics helper has one package owner" "$REPO/package/openwrt/ownership.map" \
    "/usr/lib/z2k/z2k-diag.sh package"
assert_contains "adapter resolves TUN and OpenSSL dependencies" "$MK" \
    "DEPENDS:=+kmod-nft-queue +kmod-tun +conntrack +openssl-util +z2k-zapret2-runtime"
# Stage 6: опциональный сабпакет панели (зависимость + свой init, без payload).
assert_contains "webpanel subpackage" "$MK" "Package/z2k-webpanel"
assert_contains "webpanel BuildPackage" "$MK" "BuildPackage,z2k-webpanel"
assert_contains "webpanel depends adapter" "$MK" "DEPENDS:=z2k-adapter +lighttpd"
# Versioned DEPENDS (live-урок p-84.17 §12): constraint'ы обязаны равняться
# текущим версиям пакетов — иначе lockstep дрейфует молча.
# adapter: PKG_VERSION-PKG_RELEASE этого же файла; runtime: из его Makefile.
_aver="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
_arel="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' \t\r\n')"
_rver="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$REPO/package/z2k-runtime/Makefile" | head -1 | tr -d ' \t\r\n')"
_rrel="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$REPO/package/z2k-runtime/Makefile" | head -1 | tr -d ' \t\r\n')"
assert_contains "webpanel dep == adapter version" "$MK" "EXTRA_DEPENDS:=z2k-adapter (>=${_aver}-r${_arel})"
assert_contains "adapter dep == runtime version" "$MK" "EXTRA_DEPENDS:=z2k-zapret2-runtime (>=${_rver}-r${_rrel})"
# A same-version APK is not an upgrade on OpenWrt.  Both fixes therefore
# require a real adapter release bump, and the webpanel must require that same
# release rather than silently retaining an older adapter.
assert_eq "adapter release bumped for WARP probe source dependency" "48" "$_arel"
assert_contains "nounset CGI probe remains guarded" "$REPO/platform/openwrt/customd.sh" \
    'nounset must not abort this probe'
assert_contains "BusyBox-safe FLOWOFFLOAD reader shipped" "$REPO/platform/openwrt/env.sh" \
    'BusyBox tr treats'
assert_file "autohostlist lifecycle source exists" "$REPO/platform/openwrt/autohostlist.sh"
assert_contains "init loads autohostlist lifecycle" "$REPO/package/openwrt/files/etc/init.d/z2k" \
    'platform/openwrt/autohostlist.sh'
# Каноническая грамматика FormatDepends (два провала доказали оба края):
# "name (>=ver)" — пробел только между именем и скобкой. Проверяем форму
# строго, чтобы правка не вернула ни "pkg>=ver", ни "(>= ver)".
for _dep in "z2k-adapter (>=${_aver}-r${_arel})" "z2k-zapret2-runtime (>=${_rver}-r${_rrel})"; do
    if printf '%s' "$_dep" | grep -qE '^[A-Za-z0-9+._-]+ \(([<>=!]+[^ )]+)\)$'; then _t_ok
    else _t_bad "dep не в канонической форме: [$_dep]"; fi
done
assert_contains "webpanel init install" "$MK" "files/etc/init.d/z2k-webpanel"
assert_contains "prerm uninstall" "$MK" "z2k_ow_uninstall"
assert_contains "uninstall stops service" "$REPO/platform/openwrt/uninstall.sh" "stop"
assert_contains "uninstall cron" "$REPO/platform/openwrt/uninstall.sh" "z2k_ow_cron_remove"
assert_contains "uninstall purges payload" "$REPO/platform/openwrt/uninstall.sh" 'rm -rf "$Z2K_ROOT"'
assert_contains "uninstall purges tmp" "$REPO/platform/openwrt/uninstall.sh" 'rm -rf "$Z2K_TMP"'
assert_contains "seed builder" "$MK" "make-seed.sh"
assert_contains "materialize in seed" "$REPO/package/openwrt/make-seed.sh" "z2k_ow_materialize"
assert_contains "postinst seed-guard" "$MK" "z2k_ow_seed_ensure"
assert_contains "panel contract source" "$REPO/package/openwrt/PANEL_API" "1"
assert_contains "panel contract install" "$MK" "share/panel.api"
assert_contains "panel mismatch is explicit" "$MK" "PANEL_PAYLOAD_MISMATCH"

# TCP tuning (parity step_tcp_tuning): package-owned sysctl.d + best-effort apply.
SYSCTL="$REPO/package/openwrt/files/etc/sysctl.d/99-z2k.conf"
assert_file "sysctl.d tuning существует" "$SYSCTL"
for _k in "net.ipv4.tcp_rmem = 4096 524288 4194304" "net.ipv4.tcp_wmem = 4096 524288 4194304" \
          "net.core.rmem_max = 4194304" "net.core.wmem_max = 4194304"; do
    assert_contains "sysctl key: $_k" "$SYSCTL" "$_k"
done
if grep -q 'tcp_congestion_control' "$SYSCTL"; then
    _t_bad "sysctl.d: bbr-строка (шумит в boot-лог без модуля; только runtime-try)"
else
    _t_ok
fi
assert_contains "sysctl.d ставится пакетом" "$MK" "files/etc/sysctl.d/99-z2k.conf"
assert_contains "postinst sysctl best-effort" "$MK" "sysctl -p /etc/sysctl.d/99-z2k.conf"
assert_contains "postinst bbr try" "$MK" "tcp_congestion_control=bbr"

# Fresh-install autostart (parity: upstream finalize поднимает сервис).
# Upgrade running-сервис не трогает (только WAS_FRESH-ветка).
assert_contains "postinst fresh marker" "$MK" "Z2K_OW_WAS_FRESH"
assert_contains "postinst enable fresh" "$MK" "/etc/init.d/z2k enable"
assert_contains "postinst start fresh" "$MK" "/etc/init.d/z2k start"
assert_contains "postinst running check" "$MK" "/etc/init.d/z2k running"
assert_contains "postinst preserves fresh variable through make" "$MK" \
    'if [ "$${Z2K_OW_WAS_FRESH}" = "1" ]; then'
assert_contains "postinst treats existing installed tag as upgrade" "$MK" \
    'Z2K_AU_INSTALLED_TAG_FILE:-$${Z2K_STATE:-/etc/z2k/state}/installed-tag'
assert_contains "postinst treats existing payload meta as upgrade" "$MK" \
    'Z2K_ROOT}/share/payload.meta'
if grep -q 'Z2K_OW_WAS_FRESH}" = "1"' "$MK"; then _t_ok
else _t_bad "postinst: autostart без WAS_FRESH-гейта (тронет upgrade)"; fi

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
          platform/openwrt/manifest.sh \
          platform/openwrt/state.sh \
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

# p-85.2: background discovery is not an OpenWrt service. The binary remains
# updater-owned for explicit probe/classify/quic/voice/tcp16/dnsms commands.
assert_not_contains "detect init not packaged" "$MK" 'files/etc/init.d/z2k-detect'
assert_not_contains "detect not enabled on fresh install" "$MK" '/etc/init.d/z2k-detect enable'
assert_not_contains "detect has no package owner" "$REPO/package/openwrt/ownership.map" '/etc/init.d/z2k-detect package'
assert_not_contains "discovery flag absent from adapter" "$REPO/platform/openwrt/bootstrap.sh" 'Z2K_DISCOVER'
assert_not_contains "bootstrap no longer creates discovery bridge" "$REPO/platform/openwrt/bootstrap.sh" 'ln -s.*discovered-domains'
assert_not_contains "daemon command absent" "$REPO/z2k-detect/cmd/z2k-detect/main.go" 'case "run"'
assert_file "manual detector source remains" "$REPO/z2k-detect/cmd/z2k-detect/main.go"

_t_done
