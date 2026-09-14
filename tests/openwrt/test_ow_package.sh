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
if grep -q 'Z2K_OW_WAS_FRESH" = "1"' "$MK"; then _t_ok
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

# detect-сервис (parity S98z2k-detect): отдельный procd, Z2K_DISCOVER-gate.
DET="$REPO/package/openwrt/files/etc/init.d/z2k-detect"
assert_file "detect init существует" "$DET"
assert_contains "detect instance" "$DET" 'procd_open_instance "z2k-detect"'
assert_contains "detect ставится пакетом" "$MK" "files/etc/init.d/z2k-detect"
assert_contains "detect ownership" "$REPO/package/openwrt/ownership.map" "/etc/init.d/z2k-detect package"
assert_contains "detect fresh enable" "$MK" "/etc/init.d/z2k-detect enable"
# Функционально: flag 0/absent -> instance нет; flag 1 + бинарь -> instance.
DT="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-pkgd.XXXXXX")" || exit 1
trap 'rm -rf "$DT"' EXIT INT TERM
mkdir -p "$DT/etc"
printf '#!/bin/sh\nexit 0\n' > "$DT/z2k-detect-bin"
chmod +x "$DT/z2k-detect-bin"
Z2K_ETC="$DT/etc" Z2K_DETECT_BIN="$DT/z2k-detect-bin"
export Z2K_ETC Z2K_DETECT_BIN
# shellcheck disable=SC1090,SC1091
. "$DET" || { echo "FAIL[ow-package]: source z2k-detect" >&2; exit 1; }
procd_open_instance() { printf 'INST:%s\n' "$1" >> "$DT/procd.calls"; }
procd_set_param() { return 0; }
procd_close_instance() { return 0; }
: > "$DT/procd.calls"
printf 'ENABLED=1\n' > "$DT/etc/config"
start_service >/dev/null 2>&1
if grep -q . "$DT/procd.calls" 2>/dev/null; then
    _t_bad "detect без флага открыла instance (default обязан быть off)"
else
    _t_ok
fi
printf 'ENABLED=1\nZ2K_DISCOVER=1\n' > "$DT/etc/config"
: > "$DT/procd.calls"
if start_service >/dev/null 2>&1 && grep -q 'INST:z2k-detect' "$DT/procd.calls" 2>/dev/null; then
    _t_ok
else
    _t_bad "detect с флагом не открыла instance"
fi
rm -rf "$DT"

_t_done
