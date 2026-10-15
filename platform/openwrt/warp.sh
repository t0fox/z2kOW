#!/bin/sh
# platform/openwrt/warp.sh - Game WARP glue (Stage 5).
#
# Upstream contract: docs/openwrt-warp-contract.md (+mark allocation).
# Optional feature: бинаря нет = фичи нет. procd instance "z2k-warp",
# nft sets/chains в runtime-таблице, PBR (mark + table 989) ТОЛЬКО при
# доказанной ready. Fail open всегда: нет ready = нет маршрута.
#
# CLI самостоятельно загружает paths/env перед общим updater-кодом.
# Lifecycle-вызовы из адаптера уже приходят с выставленными paths/env.
# Использование:
#   CLI (будущая панель просто вызывает):
#     install reload-lists status selfheal migrate
#     enable disable remove
#   lifecycle (init/hotplug/cron/updater):
#     1 (boot converge: sets + instance, PBR только если proven ready)
#     0 (full stop), rules (hotplug), proc-bounce, cleanup, check
#
# Разделение stop_proxy/stop (upstream S96): proc-bounce (только процесс)
# vs 0 (полный teardown). Рестарт демона НИКОГДА не снимает PBR-желание,
# а снятие PBR идёт ПЕРВЫМ при любом переходе в не-ready.
# Mutation log (§31 RT-стиль): DNS нет; NFT_CREATED:/NFT_REMOVED:/
# PROCESS_ACTION:/PBR_UP:/PBR_DOWN: на stdout (тихо при Z2K_WARP_QUIET=1).

CONFIG_FILE="${CONFIG_FILE:-${Z2K_ETC:-/etc/z2k}/config}"
_warp_adapter="${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}"
_warp_root="${Z2K_ROOT:-/usr/lib/z2k}"
if [ -z "${WARP_DOMAIN_RUNTIME_BIN:-}" ]; then
    # Each architecture's engine ships inside the one complete release tree.
    # A missing architecture fails closed and is repaired by install_release.
    [ -r "$_warp_adapter/arch.sh" ] && . "$_warp_adapter/arch.sh"
    if command -v z2k_ow_warp_bin_path >/dev/null 2>&1; then
        WARP_DOMAIN_RUNTIME_BIN="$(z2k_ow_warp_bin_path "$_warp_adapter")" || \
            WARP_DOMAIN_RUNTIME_BIN="$_warp_adapter/bin/linux-unsupported/z2k-warpd"
    else
        WARP_DOMAIN_RUNTIME_BIN="$_warp_adapter/bin/linux-unsupported/z2k-warpd"
    fi
fi
WARP_BIN="${WARP_BIN:-$WARP_DOMAIN_RUNTIME_BIN}"
if [ -z "${WARP_CONTROLLER_BIN:-}" ]; then
    WARP_CONTROLLER_BIN="$(z2k_ow_arch_bin_path "$_warp_adapter/bin" z2k-warp-controller 2>/dev/null)" || \
        WARP_CONTROLLER_BIN="$_warp_adapter/bin/linux-unsupported/z2k-warp-controller"
fi
WARP_DEVICE="${WARP_DEVICE:-${Z2K_STATE:-/etc/z2k/state}/warp/device.json}"
WARP_STATUS="${WARP_STATUS:-${Z2K_TMP:-/tmp/z2k}/warp/status.json}"
WARP_LOG="${WARP_LOG:-${Z2K_TMP:-/tmp/z2k}/warp/warpd.log}"
WARP_ROUTE_ERROR_FILE="${WARP_ROUTE_ERROR_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/route-error}"
WARP_REG_RETRY="${WARP_REG_RETRY:-600}"
WARP_REG_STAMP="${WARP_REG_STAMP:-${Z2K_TMP:-/tmp/z2k}/warp/register.stamp}"
# Runtime ownership record PBR (defect 5): пишется успешным pbr_up, читается
# pbr_down для proof route-ownership; убирается после teardown. Tmpfs —
# после reboot записи нет, и это корректно (PBR тоже нет).
WARP_PBR_OWNER="${WARP_PBR_OWNER:-${Z2K_TMP:-/tmp/z2k}/warp/pbr.owner}"
WARP_PROBE_OWNER="${WARP_PROBE_OWNER:-${Z2K_TMP:-/tmp/z2k}/warp/probe-route.owner}"
WARP_PROCD_INSTANCE_FILE="${WARP_PROCD_INSTANCE_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/procd-instance}"
WARP_PROCD_RECOVERY_FILE="${WARP_PROCD_RECOVERY_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/procd-recovery-attempt}"
WARP_PROCD_REBUILD_FILE="${WARP_PROCD_REBUILD_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/procd-rebuild-in-progress}"
WARP_LISTS_DIR="${WARP_LISTS_DIR:-${Z2K_ETC:-/etc/z2k}/user-lists/warp}"
# The updater owns the per-game tree under the shipped WARP namespace.  Keep
# the runtime default aligned with z2k-update-lists.sh and the package layout;
# tests may still override WARP_GAMES_DIR for isolated fixtures.
WARP_GAMES_DIR="${WARP_GAMES_DIR:-${Z2K_LISTS_DIR}/warp/games}"
WARP_ENABLED_FILE="${WARP_ENABLED_FILE:-$WARP_LISTS_DIR/.enabled}"
WARP_DEVICES_FILE="${WARP_DEVICES_FILE:-$WARP_LISTS_DIR/devices.txt}"
WARP_DHCP_LEASES="${WARP_DHCP_LEASES:-/tmp/dhcp.leases}"
WARP_ENDPOINTS="${WARP_ENDPOINTS:-${Z2K_LISTS_DIR:-/usr/lib/z2k/lists}/warp-endpoints.txt}"
WARP_SCAN_POOLS="${WARP_SCAN_POOLS:-${Z2K_LISTS_DIR:-/usr/lib/z2k/lists}/warp-scan-pools.txt}"
WARP_SET="${WARP_SET:-z2k_warp_dst4}"
WARP_SET_SRC="${WARP_SET_SRC:-z2k_warp_src4}"
WARP_TABLE="${WARP_TABLE:-989}"
WARP_MARK="${WARP_MARK:-0x80000000}"
WARP_MASK="${WARP_MASK:-0x80000000}"
WARP_RULE_PREF="${WARP_RULE_PREF:-500}"
# Local z2k-warpd probes are bound to z2ktun0 but otherwise unmarked.  The
# external OpenWrt backend keeps the tunnel route in the mark-selected table,
# so give that one source address its own exact rule before readiness can be
# proven.  This is separate from user-traffic marking and is fail-open removed.
WARP_PROBE_RULE_PREF="${WARP_PROBE_RULE_PREF:-499}"
WARP_READY_WAIT="${WARP_READY_WAIT:-120}"
WARP_CHAIN_MARK="${WARP_CHAIN_MARK:-z2k_warp_mark}"
WARP_CHAIN_MSS="${WARP_CHAIN_MSS:-z2k_warp_mss}"
WARP_CHAIN_FWD="${WARP_CHAIN_FWD:-z2k_warp_fwd}"
WARP_CHAIN_NAT="${WARP_CHAIN_NAT:-z2k_warp_nat}"
Z2K_WARP_NFT_FAMILY="${Z2K_WARP_NFT_FAMILY:-inet}"
# Дефолт таблицы — как у TG (см. tg.sh): дефолт pinned runtime.
Z2K_WARP_NFT_TABLE="${Z2K_WARP_NFT_TABLE:-zapret2}"
# fw4 владеет итоговой forward policy. Пакет устанавливает узкое правило
# chain-pre, а Rust-контроллер поддерживает runtime-правило для зарезервированной
# метки и выхода через интерфейс z2ktun*.
WARP_FW4_FAMILY="${WARP_FW4_FAMILY:-inet}"
WARP_FW4_TABLE="${WARP_FW4_TABLE:-fw4}"
WARP_FW4_CHAIN="${WARP_FW4_CHAIN:-forward}"
WARP_FW4_RULE_COMMENT="${WARP_FW4_RULE_COMMENT:-!z2k: WARP forwarded traffic}"
WARP_DOMAIN_HELPER="${WARP_DOMAIN_HELPER:-${Z2K_ADAPTER_DIR:-${Z2K_ROOT:-/usr/lib/z2k}/platform/openwrt}/warp-domain.sh}"
WARP_LOCK_DIR="${WARP_LOCK_DIR:-${Z2K_TMP:-/tmp/z2k}/warp/mutate.lock}"
WARP_LOCK_STALE_SECS="${WARP_LOCK_STALE_SECS:-300}"
WARP_OP_FILE="${WARP_OP_FILE:-${Z2K_TMP:-/tmp/z2k}/warp/op}"
Z2K_PROC_ROOT="${Z2K_PROC_ROOT:-/proc}"
[ -r "$WARP_DOMAIN_HELPER" ] && . "$WARP_DOMAIN_HELPER"

# Controller runtime contract v1; the Go process still receives only its
# existing explicit procd arguments and environment block.
export Z2K_WARP_PROTOCOL_VERSION=1
export CONFIG_FILE WARP_BIN WARP_DOMAIN_RUNTIME_BIN WARP_DEVICE WARP_STATUS WARP_LOG WARP_ROUTE_ERROR_FILE
export WARP_REG_RETRY WARP_REG_STAMP WARP_PBR_OWNER WARP_PROBE_OWNER
export WARP_PROCD_INSTANCE_FILE WARP_PROCD_RECOVERY_FILE WARP_PROCD_REBUILD_FILE
export WARP_LISTS_DIR WARP_GAMES_DIR WARP_ENABLED_FILE WARP_DEVICES_FILE WARP_DHCP_LEASES
export WARP_ENDPOINTS WARP_SCAN_POOLS WARP_SET WARP_SET_SRC WARP_TABLE WARP_MARK WARP_MASK
export WARP_RULE_PREF WARP_PROBE_RULE_PREF WARP_READY_WAIT WARP_CHAIN_MARK WARP_CHAIN_MSS
export WARP_CHAIN_FWD WARP_CHAIN_NAT Z2K_WARP_NFT_FAMILY Z2K_WARP_NFT_TABLE
export WARP_FW4_FAMILY WARP_FW4_TABLE WARP_FW4_CHAIN WARP_FW4_RULE_COMMENT
export WARP_DOMAIN_SET WARP_DOMAIN_RULES WARP_DOMAIN_SNAPSHOT WARP_DOMAIN_STATUS WARP_DOMAIN_ERROR
export WARP_DOMAIN_NFT_FAMILY WARP_DOMAIN_NFT_TABLE WARP_DOMAIN_NFT_OUT WARP_DOMAIN_NFT_FWD
export WARP_DOMAIN_NFLOG_GROUP WARP_LOCK_DIR WARP_LOCK_STALE_SECS WARP_OP_FILE Z2K_PROC_ROOT

_warp_controller() {
    [ -x "${WARP_CONTROLLER_BIN:-}" ] || {
        _wlog "бинарник Rust-контроллера WARP отсутствует; восстановите полный выпуск через install_release <тег>"
        return 127
    }
    Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$WARP_CONTROLLER_BIN" "$@"
}

_z2k_ow_warp_lock() {
    local _wait="${1:-30}"
    _warp_controller lock-acquire "$$" "$_wait"
}

_z2k_ow_warp_unlock() {
    _warp_controller lock-release "$$"
}

_wlog() {
    if [ -n "${Z2K_JOB_ID:-}" ]; then
        local _epoch
        _epoch=$(date +%s 2>/dev/null) || _epoch=
        case "$_epoch" in
            ''|*[!0-9]*) printf 'WARP: %s\n' "$*" >&2 ;;
            *) printf '@z2k-ts:%s|WARP: %s\n' "$_epoch" "$*" >&2 ;;
        esac
    else
        echo "[z2k-warp] $*" >&2
    fi
}
_z2k_ow_warp_mut() { [ -n "$Z2K_WARP_QUIET" ] || printf '%s\n' "$1"; }

warp_cfg() {
    _warp_controller config-read "$CONFIG_FILE" "$1" "$2" last
}
# Настроенный оператором proxy допустим, но сохранённая настройка старого VPS
# не должна вернуть отключённую зависимость после обновления OpenWrt.
warp_external_proxy() {
    local _proxy _authority _host
    _proxy="$(warp_cfg Z2K_WARP_VPS_PROXY "")"
    [ -n "$_proxy" ] || return 0
    case "$_proxy" in
        *://*)
            _authority="${_proxy#*://}"
            _authority="${_authority%%/*}"
            _authority="${_authority##*@}"
            _host="${_authority%%:*}"
            _host=$(printf '%s' "$_host" | LC_ALL=C tr 'A-Z' 'a-z')
            _host="${_host%.}"
            case "$_host" in
                213.176.74.63|213.176.74.63.nip.io|79.137.196.7) return 0 ;;
            esac
            ;;
    esac
    printf '%s' "$_proxy"
}
# Транспорт движка (p-84.18 parity: auto|wg|h2). Источник — конфиг
# (Z2K_WARP_TRANSPORT пишет панель; генератор его сохраняет при regen).
# Движок читает ту же переменную из env (см. merged main.go: default =
# os.Getenv) — procd instance экспортирует её ниже. Мусор = auto (та же
# нормализация, что у статус-эндпоинта панели в /warp/status).
warp_transport() {
    local _m=""
    _m="$(warp_cfg Z2K_WARP_TRANSPORT auto)"
    case "$_m" in wg|h2) printf '%s' "$_m" ;; *) printf 'auto' ;; esac
}

warp_wanted_boot() {
    local _plan
    _plan="$(_warp_controller boot-plan "$CONFIG_FILE" "$WARP_BIN" "$WARP_DEVICE")" || _plan=defer
    _WARP_BOOT_PLAN="$_plan"
    case "$_plan" in
        wanted) return 0 ;;
        unwanted) return 1 ;;
        *) _WARP_BOOT_PLAN=defer; return 2 ;;
    esac
}

warp_with_argv() {
    local _cb="$1"
    shift
    set -- "$WARP_BIN" run \
        --device "$WARP_DEVICE" \
        --status "$WARP_STATUS" \
        --log "$WARP_LOG" \
        --endpoints "$WARP_ENDPOINTS" \
        --scan-pools "$WARP_SCAN_POOLS" \
        --net-backend=external
    "$_cb" "$@"
}

_z2k_ow_warp_procd_command() { procd_set_param command "$@"; }

# --- procd ---

warp_start_instance() {
    command -v procd_open_instance >/dev/null 2>&1 || {
        echo "z2k-openwrt: warp: нет procd-контекста (только из start_service)" >&2
        return 1
    }
    local _proxy _regtmp _domain_state
    _proxy="$(warp_external_proxy)"
    procd_open_instance "z2k-warp"
    warp_with_argv _z2k_ow_warp_procd_command
    # procd_set_param env публикует весь параметр одним блоком: повторный
    # вызов заменяет предыдущий набор на BusyBox/OpenWrt, поэтому GODEBUG,
    # выбранный транспорт и пользовательский proxy должны попасть в одну запись. Транспорт
    # остаётся env-параметром: старое бинарное не знает --transport и упадёт
    # на разборе такого флага.
    set -- \
        GODEBUG=asyncpreemptoff=1 \
        Z2K_WARP_PROBE_SOURCE=1 \
        Z2K_WARP_OPENWRT=1 \
        "Z2K_WARP_TRANSPORT=$(warp_transport)" \
        "Z2K_WARP_DOMAIN_RULES=$WARP_DOMAIN_RULES" \
        "Z2K_WARP_DOMAIN_SNAPSHOT=$WARP_DOMAIN_SNAPSHOT" \
        "Z2K_WARP_DOMAIN_STATUS=$WARP_DOMAIN_STATUS"
    [ -z "$_proxy" ] || set -- "$@" "Z2K_WARP_VPS_PROXY=$_proxy"
    if command -v warp_domain_observer_procd_ready >/dev/null 2>&1 &&
        _domain_state="$(warp_domain_observer_procd_ready 2>/dev/null)"; then
        set -- "$@" \
            Z2K_WARP_DOMAIN_NFT=nft \
            "Z2K_WARP_DOMAIN_NFT_FAMILY=$Z2K_WARP_NFT_FAMILY" \
            "Z2K_WARP_DOMAIN_NFT_TABLE=$Z2K_WARP_NFT_TABLE" \
            "Z2K_WARP_DOMAIN_NFT_SET=$WARP_DOMAIN_SET"
        [ "$_domain_state" = active ] || set -- "$@" Z2K_WARP_DOMAIN_NFT_LAZY=1
    else
        set -- "$@" Z2K_WARP_DOMAIN_DISABLED=1
    fi
    procd_set_param env "$@"
    procd_set_param pidfile "${Z2K_RUN:-/tmp/z2k/runtime}/warpd.pid"
    # Bounded respawn как TG/RT (доказательство: procd/service/instance.c):
    # threshold 3600 / timeout 5 / retry 5; crash-loop halt'ится, не штормит.
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    # Remember that this boot registered the optional procd instance. If the
    # startup mutation lock prevented this call, the existing WARP tick can
    # distinguish that case from a process crash (which procd respawns itself).
    _regtmp="${WARP_PROCD_INSTANCE_FILE}.new.$$"
    if mkdir -p "$(dirname "$WARP_PROCD_INSTANCE_FILE")" 2>/dev/null &&
        printf 'registered\n' > "$_regtmp" 2>/dev/null &&
        mv -f "$_regtmp" "$WARP_PROCD_INSTANCE_FILE" 2>/dev/null; then
        _warp_controller procd-recovery-clear "$WARP_PROCD_RECOVERY_FILE" || \
            _wlog "не удалось очистить маркер восстановления procd WARP"
    else
        rm -f "$_regtmp" 2>/dev/null
        _wlog "не удалось записать маркер регистрации procd WARP"
    fi
    _z2k_ow_warp_mut "PROCESS_ACTION: instance z2k-warp opened"
    return 0
}

warp_install() { _warp_controller install; }
warp_enable() { _warp_controller lifecycle enable; }
warp_disable() { _warp_controller lifecycle disable; }
warp_restart() { _warp_controller lifecycle restart; }
warp_license() { _warp_controller license; }
warp_remove() { _warp_controller lifecycle remove; }
warp_reload_lists() { _warp_controller reload-lists; }
warp_ipset() {
    if [ "$#" -gt 0 ]; then
        _warp_controller ipset "$1"
    else
        _warp_controller ipset
    fi
}
warp_migrate() { _warp_controller migrate; }
warp_selfheal() { _warp_controller health-check; }
warp_status() { _warp_controller status; }

z2k_ow_warp() { _z2k_ow_warp_dispatch "$@"; }

_z2k_ow_warp_dispatch() {
    case "${1:-}" in
        1)
            if warp_wanted_boot; then
                _warp_controller event rules || {
                    _wlog "не удалось применить состояние WARP перед запуском procd"
                    return 1
                }
                warp_start_instance || {
                    _wlog "procd не принял instance WARP"
                    return 1
                }
            else
                _boot_rc=$?
                if [ "$_boot_rc" = 2 ]; then
                    _wlog "состояние WARP при запуске не подтверждено; запуск отложен без изменений"
                    return 0
                fi
                _warp_controller event stop
            fi
            ;;
        0)
            # WARP опционален: остановка z2k не зависит от отсутствующего
            # Rust-компонента, когда WARP не установлен для этой системы.
            [ -x "${WARP_CONTROLLER_BIN:-}" ] || return 0
            _warp_controller event stop
            ;;
        rules)
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            _warp_controller event rules
            ;;
        proc-bounce) _warp_controller event proc-bounce ;;
        cleanup)
            [ -x "${WARP_CONTROLLER_BIN:-}" ] || return 0
            _warp_controller event cleanup
            ;;
        check|selfheal)
            if command -v z2k_ow_core_ready >/dev/null 2>&1; then
                z2k_ow_core_ready || return 0
            fi
            _warp_controller health-check
            ;;
        install) warp_install ;;
        enable) warp_enable ;;
        disable) warp_disable ;;
        remove) warp_remove ;;
        restart) warp_restart ;;
        license) warp_license ;;
        status) warp_status ;;
        reload-lists) warp_reload_lists ;;
        ipset) shift; warp_ipset "$@" ;;
        migrate) warp_migrate ;;
        *)
            echo "использование: z2k_ow_warp {1|0|rules|proc-bounce|cleanup|check|install|enable|disable|remove|restart|license|status|selfheal|reload-lists|ipset|migrate}" >&2
            return 1
            ;;
    esac
}

# Проверку готовности и восстановление выполняет только Rust.
z2k_ow_warp_check() { _warp_controller health-check; }

# Sourced by OpenWrt init/procd and tests; CLI calls continue below.
[ -n "${Z2K_WARP_SOURCE_ONLY:-}" ] && return 0 2>/dev/null || true

case "${1:-}" in
    install) warp_install ;;
    enable) warp_enable ;;
    disable) warp_disable ;;
    remove) warp_remove ;;
    restart) warp_restart ;;
    license) warp_license ;;
    status) warp_status ;;
    selfheal|check) z2k_ow_warp "$1" ;;
    reload-lists) warp_reload_lists ;;
    ipset) shift; warp_ipset "$@" ;;
    migrate) warp_migrate ;;
    *)
        echo "использование: $0 {install|enable|disable|remove|restart|license|status|selfheal|reload-lists|ipset|migrate}" >&2
        exit 1
        ;;
esac
