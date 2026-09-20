# package/openwrt/Makefile - OpenWrt-пакет z2k-adapter.
#
# Граница владения (машиночитаемо: ownership.map, сторожит тест):
#   пакет ВЛАДЕЕТ: adapter (platform/openwrt), init/hotplug, метаданные,
#     bootstrap (postinst), дефолт config, seed.tar.gz (bootstrap-seed).
#     Runtime closure (/opt/z2k... /opt/zapret2/*) — ОТДЕЛЬНЫЙ пакет
#     package/z2k-runtime (свои PKGARCH/VERSION: arch-specific несовместим
#     с PKGARCH:=all этого файла, см. его шапку).
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
PKG_RELEASE:=42
# RELEASE 7 (p-84.21 sync): WARP parity, fw-check, soundcloud proof.
# RELEASE 8 (p-84.22 sync): новый seed (amazonaws/cloudfront в extra-domains);
# состав seed — часть package content, тот же релиз под новым деревом давал
# бы два разных артефакта с одним именем.
# RELEASE 9: resolve openssl-util with the adapter. WARP and updater manifest
# signatures need Ed25519 verification before a pinned z2k-verify is available.
# RELEASE 10: standalone WARP installs load OpenWrt paths/env before common
# auto_update.sh captures verifier defaults, so it uses the packaged public key.
# RELEASE 11: ship the diagnostics helper at the root path used by the webpanel.
# RELEASE 12: common WARP status ignores late responses after route navigation.
# RELEASE 13: snapshot packages provide one authoritative manifest/ref helper
# to WARP provisioning; production provisioning remains signature-required.
# RELEASE 14: candidate snapshot generation refreshes optional WARP digests
# from the exact source tree, so the packaged seed carries rebuilt WARP bytes.
# RELEASE 15: normalize BusyBox route output before WARP PBR ownership checks.
# RELEASE 16: publish WARP transport, proxy and Go runtime env atomically in
# one procd env block (BusyBox replaces earlier env blocks).
# RELEASE 17: rebuild the active procd service on transport changes so the
# daemon receives the newly selected transport env instead of a stale respawn.
# RELEASE 18: make that service rebuild lock-aware for direct lifecycle calls;
# only an outer user action lock is released and reacquired around procd.
# RELEASE 19: accept p-84.23 QUIC pool semantics with OpenWrt-owned state
# migration, selected-hour cron, narrow auto-update gate, and channel-scoped
# webpanel history.
# RELEASE 20 (p-84.24/p-84.25 sync): upstream DNS measurement, expanded
# TCP16/QUIC data, WARP H2 peer pinning, and state-bulk/panel parity.
# RELEASE 21: OpenWrt gaming-list cron passes the canonical config and the
# platform WARP reload hook, so refreshed enabled lists reach nft sets live.
# RELEASE 22: additive seed migration installs the gaming-list helper when an
# older package payload predates it, without re-extracting updater-owned files.
# RELEASE 23: healthy core and feature ticks converge by read-only verification;
# regeneration, firewall repair, and persistent writes happen only on drift.
# RELEASE 24 (p-84.26 sync): upstream mobile group reset fix, p-84.26
# payload/cache-bust, and explicit package/payload coherence evidence.
# RELEASE 25: typed domain-picker deadlines/progress/cancellation and the
# OpenWrt webpanel contract for preserving partial diagnostic results.
# RELEASE 26: p-84.27 upstream seed and payload sync.
# RELEASE 28: p-85.1 common webpanel sync with explicit OpenWrt boundaries;
# pending-vs-full update history, no Keenetic installer/helper in OpenWrt.
# RELEASE 29 (p-85.2): retire the package-owned background discovery daemon;
# keep z2k-detect only as an on-demand diagnostic binary and remove its stale
# daemon state during upgrade.
# RELEASE 30: close OpenWrt runtime-path/health boundaries and make the
# webpanel postinst fail closed unless its service is actually running.
# RELEASE 32: include the OpenWrt-only platform CGI seam in the updater
# manifest so a CI package upgrade converges all executable panel payload,
# not just common upstream CGI files.
# RELEASE 37: use BusyBox-safe FLOWOFFLOAD trimming so software/hardware mode
# survives every subsequent config regeneration and is reported honestly.
# RELEASE 38: use the canonical OpenWrt Discord hostlist when the upstream
# TCP_Discord.txt compatibility mirror is absent; keep the mirror preferred.
# RELEASE 39: validate user-owned strategy overrides in their actual OpenWrt
# runtime directory and make WebUI duplicate checks consume the persistent
# autohostlist ledger instead of the immutable payload path.
# RELEASE 40: compare embedded snapshot hashes for updater-owned panel CGI so
# a structurally compatible but stale installed payload is repaired in CI mode.
# RELEASE 41: persist OpenWrt auto-hostlist discoveries in state while keeping
# the nfqws2 live file separate from the panel ledger and immutable payload.
# RELEASE 42 (p-85.4 sync + WebUI refresh): consume upstream p-85.3/p-85.4
# payload changes and deliver the new OpenWrt FLOWOFFLOAD presentation through
# the normal snapshot/update path. Runtime settings and dataplane ownership are
# unchanged.
# RELEASE 31: converge stale updater-owned panel payload from an embedded CI
# snapshot through the existing verified reinstall path; production packages
# fail closed with an explicit panel-payload incompatibility.
# RELEASE 33: preserve the fresh-install gate through GNU make expansion and
# move webpanel readiness to rc.common's post-procd service_started hook.
# RELEASE 34: an older adapter can have a valid installed payload/tag but no
# .payload-initialized marker; do not mistake that upgrade state for fresh and
# regenerate the user config during package post-upgrade.
# RELEASE 35: restore the upstream 50-stun4all and 50-discord-media custom.d
# behavior on OpenWrt through zapret2's own custom_runner/nft lifecycle.
# RELEASE 36: keep the nounset-safe webpanel capability probe deliverable as a
# real apk upgrade; same-version package bytes are not an apk upgrade.
# PKGARCH:=all: ADAPTER-пакет везёт только shell/data (seed — lib/lua/fake/
# lists/strats/webpanel; z2k-owned TG/RT/WARP/manual z2k-detect едут updater binary
# flow, НЕ в APK — иначе каждый апстрим-бинер требовал бы пересборки, §52).
# Внешний pinned dataplane — отдельный пакет package/z2k-runtime
# (arch-specific, свои PKGARCH/VERSION).
PKGARCH:=all
PKG_MAINTAINER:=z2k contributors
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/z2k-adapter
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k OpenWrt adapter (thin layer over upstream z2k + zapret2 runtime)
  URL:=https://github.com/necronicle/z2k
  # +openssl-util: signed WARP/updater manifests need the documented OpenSSL
  # Ed25519 verifier fallback on OpenWrt; let apk resolve the dependency.
  # +z2k-zapret2-runtime: dataplane closure ставит отдельный пакет
  # (package/z2k-runtime — apk тянет его сам, установка z2kOW сама
  # обеспечивает runtime, parity с upstream installer); Model A: fresh
  # install без него — нерабочий продукт (§2).
  # Versioned (>=) через EXTRA_DEPENDS — нативный механизм OpenWrt для
  # версионных constraint'ов (в DEPENDS им не место: там kconfig-символы).
  # Каноническая грамматика 25.12 (include/package-pack.mk, FormatDepends):
  # слово 1 = package, слово 2 = version constraint; сам OpenWrt пишет
  # ucode (>=2022.03.22), hostapd-common (=$(PKG_VERSION)-r$(PKG_RELEASE)).
  # Пробел между comparator и version НЕДОПУСТИМ (ломает токенизацию),
  # равно как и его отсутствие между именем и скобкой.
  # live-урок p-84.17 — apk upgrade НЕ co-upgrade'ит уже установленный dep
  # без constraint'а. Нижняя граница = текущий runtime APK; консистентность
  # с package/z2k-runtime/Makefile сторожит тест. Lockstep: snapshot бампит все.
  DEPENDS:=+kmod-nft-queue +conntrack +openssl-util +z2k-zapret2-runtime
  EXTRA_DEPENDS:=z2k-zapret2-runtime (>=1.0.5.1-r4)
endef

define Package/z2k-adapter/description
Minimal OpenWrt adapter for z2k: procd service, path/env bridge,
config generation via untouched upstream libs, firewall delegation
to the zapret2 runtime. No fork of common z2k logic.
endef

# Subpackage панели (§22 контракта): только optionality + init + зависимости.
# CGI/www/template едут подписанным updater'ом (§23), НЕ пакетом — иначе
# UI-правки требовали бы пересборки пакета. DEPENDS — только проверенное
# по живому 25.12.5-фиду (Stage 8 live): lighttpd обязателен; mod_cgi и
# mod_setenv — без них postinst/старт валятся; mod_alias — нужен alias.url
# /cgi-bin/ -> webpanel/cgi (файла в document-root нет, симлинки updater
# может снести — только декларативный маппинг).
define Package/z2k-webpanel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=z2k webpanel (optional lighttpd frontend over upstream CGI)
  URL:=https://github.com/necronicle/z2k
  # Versioned adapter-dep через EXTRA_DEPENDS (тот же live-урок: без
  # constraint'а upgrade webpanel оставляет старый adapter). Граница =
  # текущий adapter APK (версия/релиз этого же файла; тест сверяет побуквенно).
  DEPENDS:=z2k-adapter +lighttpd +lighttpd-mod-cgi +lighttpd-mod-setenv +lighttpd-mod-alias
  EXTRA_DEPENDS:=z2k-adapter (>=0.1.0-r42)
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

# Snapshot-манифест сборки (point-in-time truth для fresh-provisioning без
# канала): build-release.sh кладёт кандидатный манифест и source commit
# в Z2K_OW_SNAPSHOT_MANIFEST/Z2K_OW_SNAPSHOT_COMMIT — здесь забираем их
# в PKG_BUILD_DIR. Без переменных — тихий noop (dev-сборки).
# НЕ путать с seed: seed — updater-owned payload, это — package-owned
# bootstrap-данные (ownership.map).
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	[ -z "$(Z2K_OW_SNAPSHOT_MANIFEST)" ] || cp -f "$(Z2K_OW_SNAPSHOT_MANIFEST)" $(PKG_BUILD_DIR)/snapshot-manifest.json
	[ -z "$(Z2K_OW_SNAPSHOT_COMMIT)" ] || printf '%s\n' "$(Z2K_OW_SNAPSHOT_COMMIT)" > $(PKG_BUILD_DIR)/snapshot-commit
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
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/etc/sysctl.d/99-z2k.conf $(1)/etc/sysctl.d/99-z2k.conf
	$(INSTALL_DIR) $(1)/usr/lib/z2k/platform/openwrt/custom.d
	$(INSTALL_BIN) $(Z2K_TREE)/platform/openwrt/custom.d/50-stun4all \
		$(Z2K_TREE)/platform/openwrt/custom.d/50-discord-media \
		$(1)/usr/lib/z2k/platform/openwrt/custom.d/
	$(INSTALL_DIR) $(1)/usr/lib/z2k/share
	$(INSTALL_BIN) ./files/etc/init.d/z2k $(1)/etc/init.d/z2k
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/90-z2k $(1)/etc/hotplug.d/iface/90-z2k
	$(INSTALL_BIN) $(Z2K_TREE)/files/z2k-diag.sh $(1)/usr/lib/z2k/z2k-diag.sh
	$(INSTALL_DATA) ./files/etc/z2k/config.default $(1)/usr/lib/z2k/share/config.default
	# Adapter API (Stage 7 §6): package-owned source of truth; updater его
	# никогда не перезаписывает. Абсолютный путь через Z2K_TREE (как seed).
	$(INSTALL_DATA) $(Z2K_TREE)/package/openwrt/ADAPTER_API $(1)/usr/lib/z2k/share/adapter.api
	# Panel contract is package-owned evidence for the updater-owned CGI. It is
	# never a replacement for the CGI/static payload itself.
	$(INSTALL_DATA) $(Z2K_TREE)/package/openwrt/PANEL_API $(1)/usr/lib/z2k/share/panel.api
	# Snapshot-манифест сборки + commit (готовит Build/Prepare выше, только
	# если build-release.sh их передал; dev-сборки без них — файлов нет,
	# ensure тогда работает только через канал).
	if [ -f $(PKG_BUILD_DIR)/snapshot-manifest.json ]; then $(INSTALL_DATA) $(PKG_BUILD_DIR)/snapshot-manifest.json $(1)/usr/lib/z2k/share/snapshot-manifest.json; fi
	if [ -f $(PKG_BUILD_DIR)/snapshot-commit ]; then $(INSTALL_DATA) $(PKG_BUILD_DIR)/snapshot-commit $(1)/usr/lib/z2k/share/snapshot-commit; fi
	# platform/ — в КОРНЕ дерева, а рецепт работает из package/openwrt/
	# (./files/... ниже — package-local, им префикс не нужен). Относительный
	# ./platform/... здесь указывал в никуда (поймано реальным CI-раном).
	$(INSTALL_DATA) $(Z2K_TREE)/platform/openwrt/*.sh $(1)/usr/lib/z2k/platform/openwrt/
	# Entrypoints исполняются напрямую (cron exec, updater [ -x ]) —
	# им нужен +x и в пакете, и в seed. INSTALL_BIN ставит 0755 сам;
	# 7 entrypoints лежат в git-индексе как 100755 (держит warp-static
	# тест), plain cp переносит +x в seed сам. Остальные .sh в индексе
	# 644 — их прямой запуск из дерева в Linux-чекауте падает Permission
	# denied, поэтому везде явный `sh`.
	$(INSTALL_BIN) $(Z2K_TREE)/platform/openwrt/update.sh $(Z2K_TREE)/platform/openwrt/tg-check.sh \
		$(Z2K_TREE)/platform/openwrt/rt-check.sh $(Z2K_TREE)/platform/openwrt/rt-proc.sh \
		$(Z2K_TREE)/platform/openwrt/warp.sh $(Z2K_TREE)/platform/openwrt/warp-proc.sh \
		$(Z2K_TREE)/platform/openwrt/warp-check.sh $(Z2K_TREE)/platform/openwrt/fw-check.sh \
		$(Z2K_TREE)/platform/openwrt/diag.sh $(1)/usr/lib/z2k/platform/openwrt/
	sh $(Z2K_TREE)/package/openwrt/make-seed.sh $(Z2K_TREE) $(PKG_BUILD_DIR)/seed.tar.gz
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/seed.tar.gz $(1)/usr/lib/z2k/share/seed.tar.gz
endef

define Package/z2k-adapter/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
Z2K_ROOT="$${Z2K_ROOT:-/usr/lib/z2k}"
# Fresh-install parity с upstream finalize (сервис running в конце установки):
# маркер меряем ДО seed_ensure (extract ставит его) — upgrade с маркером сюда
# не попадает никогда.
Z2K_OW_WAS_FRESH=0
# Seed — ТОЛЬКО для неинициализированной установки (marker-правило внутри):
# package upgrade при целом payload ничего не извлекает (Model A).
. "$$Z2K_ROOT/platform/openwrt/paths.sh"
if [ ! -f "$${Z2K_ETC:-/etc/z2k}/.payload-initialized" ]; then
    # Pre-r34 installs may have a complete payload and installed-tag but lack
    # the marker (the marker is install-meta, not user config). Such a state
    # is an upgrade/recovery, never a fresh install: starting z2k here would
    # regenerate /etc/z2k/config and violate the package's user-config rule.
    if [ ! -f "$${Z2K_AU_INSTALLED_TAG_FILE:-$${Z2K_STATE:-/etc/z2k/state}/installed-tag}" ] \
       && [ ! -f "$${Z2K_ROOT}/share/payload.meta" ]; then
        Z2K_OW_WAS_FRESH=1
    fi
fi
. "$$Z2K_ROOT/platform/openwrt/bootstrap.sh"
z2k_ow_retire_discovery || {
    echo "z2k-openwrt: postinst: не удалось безопасно удалить старую автодетекцию" >&2
    exit 1
}
z2k_ow_seed_ensure || exit 1
# z2k-owned binaries (TG/RT/manual detect): fresh-install provisioning best-effort
# (platform/openwrt/binaries.sh reuses au_step_refresh_binaries: manifest
# hashes + atomic replace, но БЕЗ owner bounce). Транзакцию НЕ роняем: без
# сети отказ здесь штатен, enforcement — в start preflight (fail loudly).
# env.sh обязателен здесь (postinst иначе не выставляет Z2K_PLATFORM/
# канал/состояние апдейтера, и platform-gate манифеста увидел бы keenetic).
if . "$$Z2K_ROOT/platform/openwrt/env.sh" 2>/dev/null \
    && . "$$Z2K_ROOT/platform/openwrt/webpanel.sh" 2>/dev/null \
    && . "$$Z2K_ROOT/platform/openwrt/reinstall.sh" 2>/dev/null \
    && . "$$Z2K_ROOT/platform/openwrt/binaries.sh" 2>/dev/null \
    && . "$$Z2K_ROOT/lib/utils.sh" 2>/dev/null \
    && . "$$Z2K_ROOT/lib/auto_update.sh" 2>/dev/null; then
    # A package upgrade is allowed to update updater-owned panel bytes only
    # through the same verified install_map/hash/immutable-ref path as the
    # updater. A production APK without an embedded snapshot must not guess
    # or extract seed.tar.gz over an initialized payload.
    if ! z2k_ow_panel_payload_compatible >/dev/null 2>&1; then
        z2k_ow_panel_payload_sync || exit 1
    fi
    z2k_ow_panel_payload_compatible || {
        echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: executable webpanel payload is incompatible with this adapter; signed updater delivery is required" >&2
        exit 1
    }
    z2k_ow_ensure_binaries 2>&1 || echo "z2k-openwrt: postinst: binaries доставит обновление (см. лог выше)" >&2
else
    echo "z2k-openwrt: PANEL_PAYLOAD_MISMATCH: нет updater libs для проверки executable webpanel; установка остановлена" >&2
    exit 1
fi
# Ежесуточный updater через cron (строка с маркером, идемпотентно).
. "$$Z2K_ROOT/platform/openwrt/schedule.sh"
z2k_ow_cron_install || exit 1
# TG health-check cron (своя строка/маркер, см. schedule.sh).
z2k_ow_tg_cron_install || exit 1
# RT health-check cron (своя строка/маркер).
z2k_ow_rt_cron_install || exit 1
# WARP selfheal cron (своя строка/маркер).
z2k_ow_warp_cron_install || exit 1
# Core firewall health cron (p-84.20 parity; своя строка/маркер).
z2k_ow_fw_cron_install || exit 1
# TCP tuning живьём (parity step_tcp_tuning; warn-only, см. ниже).
if [ -f /etc/sysctl.d/99-z2k.conf ]; then
    sysctl -p /etc/sysctl.d/99-z2k.conf >/dev/null 2>&1 \
        || echo "z2k-openwrt: postinst: sysctl.d не применился (применится при загрузке)" >&2
fi
# BBR — как upstream (try + silent fallback): модуля может не быть, тогда
# остаётся cubic. Не персистим: строка bbr в sysctl.d шумела бы в boot-лог
# на ядрах без модуля; rmem-ключи выше — всегда валидны.
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
# Fresh-install autostart (parity: upstream finalize поднимает сервис в конце
# установки). ТОЛЬКО fresh (см. Z2K_OW_WAS_FRESH выше): upgrade running-сервис
# не трогает. Best-effort: preflight объяснит отказ громко, транзакцию не
# роняем — offline-установка валидна, старт позже вручную/кнопкой.
if [ "$${Z2K_OW_WAS_FRESH}" = "1" ]; then
    /etc/init.d/z2k enable >/dev/null 2>&1 \
        || echo "z2k-openwrt: postinst: enable не удался" >&2
    if /etc/init.d/z2k start 2>&1; then
        sleep 2
        if /etc/init.d/z2k running >/dev/null 2>&1; then
            echo "z2k-openwrt: postinst: core запущен (fresh install)" >&2
        else
            echo "z2k-openwrt: postinst: core не поднялся — смотрите лог, стартуйте вручную" >&2
        fi
    else
        echo "z2k-openwrt: postinst: start отказался (preflight выше) — стартуйте вручную после устранения" >&2
    fi
fi
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

define Package/z2k-webpanel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/z2k-webpanel enable || exit 1
if /etc/init.d/z2k-webpanel running >/dev/null 2>&1; then
    exit 0
fi
/etc/init.d/z2k-webpanel start || exit 1
/etc/init.d/z2k-webpanel running >/dev/null 2>&1 || {
    echo "z2k-openwrt: webpanel postinst: service is not running" >&2
    exit 1
}
exit 0
endef

$(eval $(call BuildPackage,z2k-adapter))
$(eval $(call BuildPackage,z2k-webpanel))
