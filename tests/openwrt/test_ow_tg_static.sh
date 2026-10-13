#!/bin/sh
# tests/openwrt/test_ow_tg_static.sh - Stage 3 Layer A: статика TG glue.
# Никаких Keenetic /opt/* путей (кроме read-only migration cleanup ниже),
# iptables/ipset/NDM, shell-supervisor'а, второго сервиса;
# один процесс на оба порта; ownership disjoint; секреты не печатаются.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-static"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TG="$REPO/platform/openwrt/tg.sh"
TGC="$REPO/platform/openwrt/tg-check.sh"
INIT="$REPO/platform/openwrt/files/etc/init.d/z2k"
HOTPLUG="$REPO/platform/openwrt/files/etc/hotplug.d/iface/90-z2k"
SCHED="$REPO/platform/openwrt/schedule.sh"
UNINST="$REPO/platform/openwrt/uninstall.sh"
BUILDER="$REPO/scripts/openwrt/stage-rootfs.sh"
AU="$REPO/lib/auto_update.sh"

assert_file "tg.sh существует" "$TG"
assert_file "tg-check.sh существует" "$TGC"

# Запреты проверяем по коду БЕЗ комментариев. UDP-путь p-85.8 больше не
# запускается: только migration helper может упоминать его точный старый path
# для checksum-guarded удаления.
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tgs.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
_TGCODE="$T/tg.code"; _TGCCODE="$T/tgc.code"; _RETIRE="$REPO/platform/openwrt/tg-retire-udp.sh"
sed 's/#.*$//' "$TG" > "$_TGCODE"
sed 's/#.*$//' "$TGC" > "$_TGCCODE"
assert_contains "legacy path used only by one-shot migration" "$_RETIRE" \
    'Z2K_OW_LEGACY_SHELL="${Z2K_OW_LEGACY_SHELL:-/opt/bin/sh}"'
assert_contains "legacy migration verifies exact helper bytes" "$_RETIRE" \
    'sha256sum "$Z2K_OW_LEGACY_SHELL"'
assert_contains "legacy migration removes only checksum-matched helper" "$_RETIRE" \
    'rm -f "$Z2K_OW_LEGACY_SHELL"'
if sed 's/#.*$//' "$_RETIRE" | grep -qE '^[[:space:]]*"\$Z2K_OW_LEGACY_SHELL"([[:space:]]|$)'; then
    _t_bad "migration executes the retired legacy shell"
else
    _t_ok
fi

# --- нет keenetic-путей и чужого firewall-стека в glue ---
for _f in "$_TGCODE" "$_TGCCODE"; do
    _b="glue"
    assert_not_contains "$_b: нет /opt" "$_f" '/opt'
    assert_not_contains "$_b: нет iptables" "$_f" 'iptables'
    assert_not_contains "$_b: нет ipset" "$_f" 'ipset'
    assert_not_contains "$_b: нет NDM" "$_f" 'NDM|ndm'
done
# conntrack только целевой -D -d (никакого flush всего): каждая кодовая
# строка, ВЫЗЫВАЮЩАЯ бинарник (не имя функции), обязана содержать "-D -d".
_tg_ct_calls="$(grep -E '(^|[;|& ]+)conntrack ' "$_TGCODE" || true)"
if [ -n "$_tg_ct_calls" ] && [ -z "$(printf '%s\n' "$_tg_ct_calls" | grep -vF -- '-D -d' || true)" ]; then
    _t_ok
else
    _t_bad "tg.sh: conntrack-вызов не целевой (-D -d): [$_tg_ct_calls]"
fi

# --- нет shell-supervisor'а (это делает procd) ---
# (Z2K_TG_PIDFILE — procd pidfile-параметр, не supervisor-PIDFILE: требуем
# отсутствие ГОЛОГО PIDFILE=/GENFILE= присваивания)
for _pat in 'while :' '(^|[^_A-Za-z0-9])PIDFILE=' '(^|[^_A-Za-z0-9])GENFILE=' 'sleep \$backoff'; do
    assert_not_contains "tg.sh: нет supervisor-признака ($_pat)" "$_TGCODE" "$_pat"
done
assert_contains "tg.sh: respawn через procd" "$TG" 'procd_set_param respawn 3600 5 5'
assert_not_contains "Telegram TCP lifecycle has no UDP transport" "$_TGCODE" 'telegram-udp|UDP_ROUTE|UDP_READY|Z2K_TG_UDP_RELAY'
# голого respawn (неявные дефолты) и retry=0 (бесконечный шторм) быть не должно
if grep -qE 'procd_set_param respawn[[:space:]]*$' "$TG"; then
    _t_bad "tg.sh: голый respawn без explicit параметров"
else
    _t_ok
fi
if grep -qE 'procd_set_param respawn [0-9]+ [0-9]+ 0([^0-9]|$)' "$TG"; then
    _t_bad "tg.sh: retry=0 (бесконечный crash-loop)"
else
    _t_ok
fi
# приоритеты — plain integers (арифметика dstnat/filter - N зависит от парсера)
for _bad in 'priority dstnat -' 'priority dstnat +' 'priority filter -' 'priority filter +'; do
    assert_not_contains "tg.sh: нет арифметики приоритетов ($_bad)" "$_TGCODE" "$_bad"
done

# --- один прозрачный слушатель Rust без релея и второго обработчика CDN ---
assert_contains "tg.sh: Rust слушает только :1443" "$TG" '"--port=$Z2K_TG_PORT"'
assert_contains "tg.sh: transparent включён как единственный режим" "$TG" 'z2k_ow_tg_with_argv'
assert_not_contains "tg.sh: удалённые CLI-флаги отсутствуют" "$TG" '(^|[[:space:]])(--transparent|--pool-size|--no-outbound-proxy)([=[:space:]]|$)'
assert_contains "tg.sh: использует persistent-кэш Telegram DC" "$TG" '--dc-map-path='
assert_contains "tg.sh: задаёт ограниченную частоту обновления карты DC" "$TG" '--dc-map-refresh-secs='
assert_contains "tg.sh: ограничение одновременных сессий" "$TG" '--max-connections=$Z2K_TG_MAX_CONNECTIONS'
assert_contains "tg.sh: лимит вычисляется по бюджету FD/RAM" "$TG" 'z2k_ow_tg_connection_budget'
assert_contains "tg-policy.sh: Auto поддерживает 17 одновременных соединений" \
    "$REPO/platform/openwrt/tg-policy.sh" 'Z2K_TG_CONNECTION_AUTO_CAP_DEFAULT="32"'
assert_contains "tg-policy.sh: HTTP transport включён только для проверяемых Telegram-адресов" \
    "$REPO/platform/openwrt/tg-policy.sh" 'Z2K_TG_TCP_PORTS_DEFAULT="80 443 5222"'
assert_contains "tg-policy.sh: Manual проверяется по верхней границе" \
    "$REPO/platform/openwrt/tg-policy.sh" 'Z2K_TG_CONNECTION_HARD_CAP="128"'
assert_not_contains "tg.sh: порт CDN 1444 не используется" "$_TGCODE" '1444|Z2K_TG_CDN_PORT'
assert_not_contains "tg.sh: настройки старого relay отсутствуют" "$_TGCODE" 'Z2K_RELAY_URL|Z2K_RELAY_SECRET|relay-id-file|TG_MTPROTO_PROXY'
assert_not_contains "tg.sh: старый Go-клиент не запускается" "$_TGCODE" 'exec .*tg-mtproxy-client|procd_set_param command .*tg-mtproxy-client'
assert_contains "tg.sh: CIDR-наборы заменяются одним nft batch" "$TG" 'nft -f -'
assert_contains "tg.sh: CIDR batch helper присутствует" "$TG" '_z2k_ow_tg_nft_sets_commit'
assert_not_contains "tg.sh: нет отдельных команд flush CIDR set" "$_TGCODE" 'nft flush set'
_TG_UI="$REPO/webpanel/www/js/pages/toggles.js"
assert_contains "панель показывает неподдерживаемый тип" "$_TG_UI" 'Тип не поддерживается'
assert_contains "панель отключает включение при неподдерживаемом типе" "$_TG_UI" 'setLockAware(enableBtn, tgRunning || tgUnavailable);'
assert_contains "панель отключает управление при отсутствии Rust-бинарника" "$_TG_UI" 'const tgUnavailable = !tgSupported || !tgInstalled;'
# второго сервиса нет
if [ -f "$REPO/platform/openwrt/files/etc/init.d/z2k-tg" ]; then
    _t_bad "второй init-сервис z2k-tg существует (должен быть один owner)"
else
    _t_ok
fi
assert_not_contains "init: нет второго open_instance" "$INIT" 'procd_open_instance "z2k-tg-second"'

# --- nft: своя chains/sets, чужой таблицы не создаём ---
assert_not_contains "tg.sh: нет add table" "$_TGCODE" 'add table|create table'
assert_not_contains "tg.sh: нет второй таблицы z2k" "$_TGCODE" 'table inet z2k'
assert_contains "tg.sh: таблица runtime" "$TG" 'Z2K_TG_NFT_TABLE'
assert_contains "tg.sh: проверка таблицы до записей" "$TG" '_z2k_ow_tg_table_ok'
# ни одного ACCEPT/input-открытия: `accept` в коде — ТОЛЬКО scoped
# dnat-accept guard'а (уже проверен выше построчно); -j ACCEPT и голых
# accept-вердиктов вне guard'а быть не должно.
assert_not_contains "tg.sh: нет -j ACCEPT" "$_TGCODE" '\-j ACCEPT'
# UDP's four forward accepts are deliberately scoped to the dedicated TUN and
# the Telegram address sets; they are the OpenWrt equivalent of upstream's
# FORWARD accepts and are not an input-port opening.
_tg_accepts="$(grep -n 'accept' "$_TGCODE" \
    | grep -v 'ct status dnat accept' \
    | grep -vE 'oifname "\$Z2K_TG_UDP_IF"|iifname "\$Z2K_TG_UDP_IF"' || true)"
if [ -z "$_tg_accepts" ]; then
    _t_ok
else
    _t_bad "tg.sh: accept вне scoped guard: [$_tg_accepts]"
fi
# v6 — icmpv6-reject, не redirect и не drop (TCP RST невозможен для IPv6:
# парсер ядра отвергает `reject with tcp reset` в v6-контексте — Stage 8)
assert_contains "tg.sh: IPv6 redirect uses the shared configured port" "$TG" \
    'tcp dport "$_port" ip6 daddr "@$Z2K_TG_SET6" counter redirect to ":$Z2K_TG_PORT"'
assert_not_contains "tg.sh: no legacy IPv6 reject" "$_TGCODE" 'reject with icmpv6'
assert_not_contains "tg.sh: no unscoped TCP/80 redirect" "$_TGCODE" 'tcp dport 80 counter redirect'
# INPUT-guard: scoped accept (порты + dnat) строго до drop; blanket
# `ct status dnat accept` без портов обошёл бы fw4-input для чужого DNAT.
assert_contains "tg.sh: input chain" "$TG" 'type filter hook input priority -1'
assert_contains "tg.sh: guard accept scoped" "$TG" 'tcp dport "$Z2K_TG_PORT" ct status dnat accept'
assert_contains "tg.sh: guard drop" "$TG" 'tcp dport "$Z2K_TG_PORT" drop'
if grep -E 'add rule .* ct status dnat accept' "$_TGCODE" | grep -v 'tcp dport' >/dev/null 2>&1; then
    _t_bad "tg.sh: blanket ct-status accept без портов"
else
    _t_ok
fi

# --- секреты не печатаются ---
assert_not_contains "tg.sh: нет set -x" "$_TGCODE" 'set -x'
assert_not_contains "tg.sh: secret не в echo" "$_TGCODE" 'echo.*SECRET|echo.*tunnel-secret'
assert_not_contains "tg.sh: secret не в logger" "$_TGCODE" 'logger.*SECRET|logger.*secret='

# --- проводка: init / hotplug / schedule / uninstall / full rootfs builder ---
assert_contains "init: tg.sh подключён" "$INIT" 'platform/openwrt/tg.sh'
assert_contains "init: старт зовёт tg 1" "$INIT" 'z2k_ow_tg 1'
assert_contains "init: стоп зовёт tg 0" "$INIT" 'z2k_ow_tg 0'
assert_contains "hotplug: TG reconverge" "$HOTPLUG" 'z2k_ow_tg rules'
assert_contains "schedule: tg-health строка" "$SCHED" 'z2k-tg-health'
assert_contains "schedule: tg-check entrypoint" "$SCHED" 'tg-check.sh check'
assert_contains "schedule: install/remove пара" "$SCHED" 'z2k_ow_tg_cron_install'
assert_contains "schedule: remove пара" "$SCHED" 'z2k_ow_tg_cron_remove'
assert_contains "uninstall: tg cleanup" "$UNINST" 'z2k_ow_tg cleanup'
assert_contains "uninstall: tg cron remove" "$UNINST" 'z2k_ow_tg_cron_remove'
assert_contains "complete builder stages only real OpenWrt runtime dependencies during install" "$REPO/platform/openwrt/release.sh" 'apk add'
assert_not_contains "full payload builder has no component APK recipe" "$BUILDER" 'apk[[:space:]]+(build|add|del)|abuild'
assert_contains "rootfs includes TG implementation" "$BUILDER" 'platform/openwrt/*.sh'
assert_contains "rootfs добавляет Rust-бинарник по архитектуре" "$BUILDER" \
    'usr/lib/z2k/bin/linux-$_arch/tg-ws-proxy'
assert_contains "кандидат собирает встроенный Rust crate" \
    "$REPO/scripts/openwrt/build-release.sh" 'build_tg_ws_proxy.sh'
assert_contains "сборка читает локальный crate" "$REPO/scripts/openwrt/build_tg_ws_proxy.sh" \
    'CRATE="$ROOT/platform/openwrt/tg-proxy"'
assert_contains "сборка использует Cargo.lock" "$REPO/scripts/openwrt/build_tg_ws_proxy.sh" 'cargo "+$_toolchain" build --locked'
assert_not_contains "сборка не клонирует upstream и не применяет patch" \
    "$REPO/scripts/openwrt/build_tg_ws_proxy.sh" 'git clone|git -C .*apply|_patch'
if [ -e "$REPO/platform/openwrt/tg-ws-proxy.pin" ] || \
   [ -e "$REPO/patches/tg-ws-proxy-rs/0001-transparent-openwrt.patch" ]; then
    _t_bad "у локальной сборки остались upstream pin или гигантский patch"
else
    _t_ok
fi
assert_contains "сборка Rust ограничена ARM64 и x86_64" \
    "$REPO/scripts/openwrt/build_tg_ws_proxy.sh" \
    'aarch64-unknown-linux-musl:arm64:arm64-gcc x86_64-unknown-linux-musl:x86_64:host-gcc'
for _workflow in "$REPO/.github/workflows/ci.yml" "$REPO/.github/workflows/release-openwrt.yml"; do
    assert_contains "CI берёт версию Rust из встроенного crate: $_workflow" "$_workflow" \
        'platform/openwrt/tg-proxy/rust-toolchain.toml'
    assert_not_contains "CI больше не читает удалённый upstream pin: $_workflow" "$_workflow" \
        'platform/openwrt/tg-ws-proxy.pin'
done

# --- COMMON_HOOK в au_service_for_binary ---
assert_contains "au: openwrt-ветка" "$AU" 'Z2K_PLATFORM:-keenetic}" = "openwrt"'
assert_contains "firewall: runtime recovery uses unified installer" "$REPO/platform/openwrt/firewall.sh" 'install_release <tag>'
assert_not_contains "firewall: no component APK recovery path" "$REPO/platform/openwrt/firewall.sh" 'z2k-zapret2-runtime'
assert_not_contains "au: старые VPS TG-сервисы удалены" "$AU" '/opt/etc/init.d/S98tg-tunnel /opt/etc/init.d/S97z2k-http-tunnel'

_t_done
