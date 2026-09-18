#!/bin/sh
# platform/openwrt/env.sh - мост между путями OpenWrt и именами upstream z2k.
#
# Upstream lib/*.sh параметризованы окружением (ZAPRET2_DIR, CONFIG_DIR,
# LISTS_DIR — все через ${VAR:-default}), поэтому перенаправление всего
# strategy/config-конвейера на OpenWrt-дерево делается БЕЗ правок common:
# достаточно выставить переменные ДО подключения lib/utils.sh.
#
# Lua-состояние тоже выведено наружу через env-хуки движка:
#   Z2K_STATE_DIR_OVERRIDE  (files/lua/z2k-state-persist.lua)
#   Z2K_TCP16_ASN/NETS/SNI, Z2K_SNI_PIN (files/lua/z2k-tcp16.lua)
#
# Использование: . paths.sh; . env.sh; затем . $Z2K_LIB/utils.sh ...
#
# Предусловие: пути уже выставлены (paths.sh подключён вызывающим).
# Автосорсинг paths.sh здесь невозможен: при `. env.sh` $0 — это вызывающий.

# Platform identity для common-кода (constitution, не дефолт):
# au_manifest_platform_ok gate, au_service_for_binary owner mapping,
# z2k_install_paths_for dispatch — все читают ${Z2K_PLATFORM:-keenetic}.
# БЕЗ этой строки в проде (update.sh) common видел keenetic: platform gate
# пропускал чужие манифесты, а binary-координация молча скипалась
# (Stage 3/RT root-cause, доказано аудитом Stage 4). Keenetic этот файл
# не сорсит — там дефолт keenetic нетронут.
Z2K_PLATFORM="${Z2K_PLATFORM:-openwrt}"
export Z2K_PLATFORM

# Корень payload — единственная точка входа upstream-конвейера.
ZAPRET2_DIR="${ZAPRET2_DIR:-$Z2K_ROOT}"
CONFIG_DIR="${CONFIG_DIR:-$Z2K_CONF_DIR}"
LISTS_DIR="${LISTS_DIR:-$Z2K_LISTS_DIR}"
export ZAPRET2_DIR CONFIG_DIR LISTS_DIR

# FWTYPE для ГЕНЕРАЦИИ конфига: современный OpenWrt = nftables/fw4.
# В сам конфиг не пишется (там остаётся закомментированным — zapret2
# linux_fwtype автодетектит backend при каждом apply). Нужно только ветке
# IPv6-автодетекта create_official_config (проверка наличия nft).
FWTYPE="${FWTYPE:-nftables}"
export FWTYPE

# Lua: состояние autocircular — в persistent /etc/z2k/state.
Z2K_STATE_DIR_OVERRIDE="${Z2K_STATE_DIR_OVERRIDE:-$Z2K_STATE}"
Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE="${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE:-$Z2K_TMP}"
export Z2K_STATE_DIR_OVERRIDE Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE

# Тот же файл глазами shell-стороны: шаг reset-state апдейтера чистит
# ${STATE_FILE} (дефолт — keenetic-путь; здесь указываем наш).
STATE_FILE="${STATE_FILE:-$Z2K_STATE/state.tsv}"
export STATE_FILE
# Тот же fallback глазами reset-state: lua пишет запасную копию в
# ${Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE}/z2k-autocircular-state.tsv (см. выше),
# шаг чистит её через этот hook (lib/auto_update.sh au_step_reset_state).
Z2K_AU_STATE_FALLBACK="${Z2K_AU_STATE_FALLBACK:-$Z2K_AUTOCIRCULAR_FALLBACK_OVERRIDE/z2k-autocircular-state.tsv}"
export Z2K_AU_STATE_FALLBACK

# Пара 3-way merge extra-domains (au_merge_extra_domains): shipped-база из
# payload, runtime-мерж в user-lists. Keenetic-дефолты — в самом хуке.
Z2K_EXTRA_DOMAINS_SHIPPED="${Z2K_EXTRA_DOMAINS_SHIPPED:-$Z2K_LISTS_DIR/extra-domains.txt}"
Z2K_EXTRA_DOMAINS_RUNTIME="${Z2K_EXTRA_DOMAINS_RUNTIME:-$Z2K_USER_LISTS/extra-domains.txt}"
export Z2K_EXTRA_DOMAINS_SHIPPED Z2K_EXTRA_DOMAINS_RUNTIME

# Lua: tcp16-карты. ASN/SNI — рантайм-состояние (/etc), NETS/PIN — shipped.
Z2K_TCP16_ASN="${Z2K_TCP16_ASN:-$Z2K_STATE/tcp16_asn.txt}"
Z2K_TCP16_NETS="${Z2K_TCP16_NETS:-$Z2K_LISTS_DIR/tcp16_nets.txt}"
Z2K_TCP16_SNI="${Z2K_TCP16_SNI:-$Z2K_STATE/tcp16_sni.txt}"
Z2K_SNI_PIN="${Z2K_SNI_PIN:-$Z2K_LISTS_DIR/sni_wl_pin.txt}"
export Z2K_TCP16_ASN Z2K_TCP16_NETS Z2K_TCP16_SNI Z2K_SNI_PIN

# Конфиг, который читает zapret2 runtime (QNUM/marks/ports/offload):
# это и есть наш канонический /etc/z2k/config (см. generate.sh).
ZAPRET_CONFIG="${ZAPRET_CONFIG:-$Z2K_CONFIG}"
export ZAPRET_CONFIG

# Канонический конфиг для шагов апдейтера (regen-config/validate-config/
# restart-service): тот же файл. PLATFORM HOOK в lib/auto_update.sh читает
# именно эту переменную; unset = keenetic-путь, там её никто не выставляет.
Z2K_CONFIG_FILE="${Z2K_CONFIG_FILE:-$Z2K_CONFIG}"
export Z2K_CONFIG_FILE

# Init-скрипт для шага restart-service семантики (au_step_restart_service
# вызывает "$INIT_SCRIPT restart"). utils.sh уважает предустановку.
INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"
export INIT_SCRIPT

# Каталог Go-бинарников для шага refresh-binaries (au_step_refresh_binaries
# кладёт в ${Z2K_AU_SBIN}). Persistent, согласно storage-модели.
Z2K_AU_SBIN="${Z2K_AU_SBIN:-$Z2K_BIN}"
export Z2K_AU_SBIN

# --- Канал обновлений: OpenWrt-line, НЕ upstream Keenetic ---
#
# Updater читает ИМЕННО эти переменные (lib/auto_update.sh:18-20, условные
# присваивания — Keenetic их не выставляет и едет как раньше):
#   Z2K_AU_BRANCH / Z2K_AU_REPO_RAW / Z2K_AU_MANIFEST_URL (последний выводится
#   из REPO_RAW сам, его не задаём).
# Вариант A: production-ветка z2k-enhanced-openwrt (создаётся к первому
# OpenWrt-релизу; dev-ветки роутеры не опрашивают). upstream sync -> manifest
# с Z2K_PLATFORM=openwrt на ней -> роутер забирает без перенастройки.
# Всё переопределяемо окружением.
Z2K_AU_BRANCH="${Z2K_AU_BRANCH:-z2k-enhanced-openwrt}"
Z2K_AU_REPO_RAW="${Z2K_AU_REPO_RAW:-https://raw.githubusercontent.com/t0fox/z2kOW/${Z2K_AU_BRANCH}}"
export Z2K_AU_BRANCH Z2K_AU_REPO_RAW

# Та же линия для списков/бинарников (z2k_fetch через GITHUB_RAW; utils.sh
# уважает предустановку) и для Z2K_GITHUB_RAW-пина в генерируемом конфиге.
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/t0fox/z2kOW/${Z2K_AU_BRANCH}}"
export GITHUB_RAW

# Корень repo для неизменяемых ссылок (au_repo_base: $BASE/$TARGET_REF).
# Отдельная переменная, а не обрезка REPO_RAW: у base нет суффикса ветки,
# выводить одно из другого строковой хирургией хрупко. Keenetic-дефолт —
# в самом хуке au_repo_base; здесь только openwrt-значение.
Z2K_AU_RAW_BASE="${Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/t0fox/z2kOW}"
export Z2K_AU_RAW_BASE

# --- Состояние апдейтера: всё условное в common, здесь — openwrt-значения ---
# Persistent (переживают reboot/upgrade):
Z2K_AU_INSTALLED_TAG_FILE="${Z2K_AU_INSTALLED_TAG_FILE:-$Z2K_STATE/installed-tag}"
Z2K_AU_TRUST_PIN="${Z2K_AU_TRUST_PIN:-$Z2K_ETC/.trust/pinned}"
# Transient (tmpfs; locks/logs/downloads — см. storage-модель):
Z2K_AU_LOCK_FILE="${Z2K_AU_LOCK_FILE:-$Z2K_LOCKS/update.lock}"
Z2K_AU_LOG_FILE="${Z2K_AU_LOG_FILE:-$Z2K_LOG/z2k-auto-update.log}"
Z2K_AU_TMP_DIR="${Z2K_AU_TMP_DIR:-$Z2K_TMP/update}"
export Z2K_AU_INSTALLED_TAG_FILE Z2K_AU_TRUST_PIN Z2K_AU_LOCK_FILE Z2K_AU_LOG_FILE Z2K_AU_TMP_DIR
# Счётчик delivery-неудач и dirty-маркер — persistent state (не payload!):
# счётчик в read-only ${ZAPRET2_DIR}/state молча не пишется и 3-strikes
# эскалация не срабатывает; dirty обязан переживать reboot.
Z2K_AU_FAILS_FILE="${Z2K_AU_FAILS_FILE:-$Z2K_STATE/au-delivery-fails}"
Z2K_AU_DIRTY_TREE_FILE="${Z2K_AU_DIRTY_TREE_FILE:-$Z2K_STATE/dirty-tree}"
export Z2K_AU_FAILS_FILE Z2K_AU_DIRTY_TREE_FILE

# Embedded CI snapshot authority. 125 means "no snapshot, continue with the
# common path"; every other non-zero result is a malformed/failed snapshot and
# therefore fails closed.
z2k_platform_fetch_manifest() {
    [ "${Z2K_PLATFORM:-}" = "openwrt" ] || return 125
    local _d="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
    [ -r "$_d/manifest.sh" ] || return 125
    # shellcheck disable=SC1090
    . "$_d/manifest.sh" || return 2
    z2k_ow_manifest_snapshot_mode
    case "$?" in
        1) return 125 ;;
        0|2)
            z2k_ow_manifest_prepare "${Z2K_AU_TMP_DIR:-${Z2K_TMP:-/tmp/z2k}/update}/UPDATES.json" \
                || return 2
            return 0
            ;;
        *) return 2 ;;
    esac
}

# A snapshot's separate full commit pin outranks the history's human release
# ref, which may be a tag absent from the adapter fork. Production manifests
# continue through au_manifest_ref unchanged.
z2k_platform_manifest_ref() {
    [ "${Z2K_PLATFORM:-}" = "openwrt" ] || return 0
    [ "${Z2K_OW_MANIFEST_MODE:-}" = snapshot ] || return 0
    [ -n "${Z2K_AU_TARGET_REF:-}" ] || return 0
    printf '%s\n' "$Z2K_AU_TARGET_REF"
}
# PUBKEY/VERIFY_BIN не задаём: их дефолты уже идут через ZAPRET2_DIR/Z2K_AU_SBIN
# (${Z2K_ROOT}/etc/z2k-update-pub.pem и ${Z2K_BIN}/z2k-verify) — тест сверяет.

# ZAPRET_BASE читает только валидатор (бинарник) и Keenetic S99 (не наш
# путь): указываем на runtime. INIT_SCRIPT уже выставлен выше — валидатор
# возьмёт его как источник --blob-регистраций (в нашем init их нет, как и
# на macOS: проверка карты молча скипается, NOT veto).
# FAKE_DIR ($Z2K_ROOT/fake) и lua EXTRA ($Z2K_ROOT/lua) — хуки валидатора
# (blob-файлы по имени + z2k-детекторы; fork-lua сканируется из ZAPRET_BASE).
ZAPRET_BASE="${ZAPRET_BASE:-$Z2K_ZAPRET2_RUNTIME}"
export ZAPRET_BASE
# Z2K_FAKE_DIR ($Z2K_ROOT/fake) и Z2K_LUA_DIR ($Z2K_ROOT/lua) уже выставлены
# paths.sh выше — здесь только экспортируем для валидатора и движка.
export Z2K_FAKE_DIR Z2K_LUA_DIR
Z2K_LUA_EXTRA_DIRS="${Z2K_LUA_EXTRA_DIRS:-$Z2K_LUA_DIR}"
export Z2K_LUA_EXTRA_DIRS

# LAN-сети для zapret2 ifsets (значение задаёт uci.sh, здесь — дефолт).
OPENWRT_LAN="${OPENWRT_LAN:-lan}"
export OPENWRT_LAN

# Adapter-owned RT exclusion (владение J): 5 RT-доменов живут в ОТДЕЛЬНОМ
# файле, а не дописываются в user-owned whitelist.txt. Генератор подхватывает
# его через platform-neutral hook Z2K_HOSTLIST_EXCLUDE_EXTRA (только если файл
# существует). Содержимое — exact-5 при активном RT, пусто при стопе (truncate,
# не delete: конфиг ссылается на путь, missing-file ронял бы рестарт демона).
# Писатель один (rt.sh, atomic rename); панель/пользователь его не трогают.

Z2K_RT_EXCLUDE="${Z2K_RT_EXCLUDE:-$Z2K_ETC/rt-exclude.txt}"
export Z2K_RT_EXCLUDE
Z2K_HOSTLIST_EXCLUDE_EXTRA="${Z2K_HOSTLIST_EXCLUDE_EXTRA:-$Z2K_RT_EXCLUDE}"
export Z2K_HOSTLIST_EXCLUDE_EXTRA

# Common diagnostics delegate OS-specific probes (procd/nft/runtime paths) to
# this tiny adapter hook.  Unset on Keenetic, so its upstream diagnostics stay
# byte-for-byte unchanged.
Z2K_DIAG_HOOK="${Z2K_DIAG_HOOK:-$Z2K_ADAPTER_DIR/diag.sh}"
export Z2K_DIAG_HOOK

# z2k_ow_core_ready — предикат "dataplane готов": маркер core-ready СУЩЕСТВУЕТ
# (его создаёт start_service последним и снимает первым stop/failed start)
# И сервис running. Reconvergence (hotplug/cron check/rules) разрешена только
# при ready — иначе manual stop/failed start воскресали бы правилами.
# INIT_SCRIPT переопределяем для тестов (на роутере — /etc/init.d/z2k).
z2k_ow_core_ready() {
    [ -f "${Z2K_CORE_READY:-${Z2K_RUN:-/tmp/z2k/runtime}/core-ready}" ] || return 1
    "${INIT_SCRIPT:-/etc/init.d/z2k}" running >/dev/null 2>&1
}
