#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
if [ "${1:-}" = --inside ]; then
    T="$2"
    ip link add z2ktun0 type dummy
    ip link set z2ktun0 up
    ip route replace default dev z2ktun0 table 989
    ip route del default table 989
    trap 'nft delete table inet fw4 2>/dev/null || true; nft delete table inet "$Z2K_WARP_NFT_TABLE" 2>/dev/null || true; ip link del z2ktun0 2>/dev/null || true' EXIT HUP INT TERM
    export WARP_LOCK_DIR="$T/mutate.lock" WARP_PBR_OWNER="$T/pbr.owner" WARP_PROBE_OWNER="$T/probe.owner"
    export WARP_STATUS="$T/status.json" WARP_DEVICE="$T/device.json" WARP_LOG="$T/warpd.log"
    export WARP_DOMAIN_RULES="$T/domains.v1" WARP_DOMAIN_ERROR="$T/domain-setup-error"
    export Z2K_ROOT="$ROOT" Z2K_ADAPTER_DIR="$ROOT/platform/openwrt" Z2K_ETC="$T/etc"
    export Z2K_STATE="$T/state" Z2K_TMP="$T/tmp" Z2K_LISTS_DIR="$T/lists"
    export Z2K_PROC_ROOT="$T/proc"
    export Z2K_WARP_SOURCE_ONLY=1
    export Z2K_WARP_QUIET=""
    export Z2K_WARP_NFT_TABLE=z2k_warp_shell_test
    export WARP_LISTS_DIR="$T/etc/user-lists/warp" WARP_GAMES_DIR="$T/lists/warp/games"
    export WARP_ENABLED_FILE="$T/etc/user-lists/warp/.enabled" WARP_DEVICES_FILE="$T/etc/user-lists/warp/devices.txt"
    printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9"}\n' > "$WARP_STATUS"
    mkdir -p "$Z2K_PROC_ROOT/101"
    printf 'z2k-warpd\n' > "$Z2K_PROC_ROOT/101/comm"
    printf '/usr/bin/z2k-warpd\000run\000' > "$Z2K_PROC_ROOT/101/cmdline"
    . "$ROOT/platform/openwrt/warp.sh"
    mkdir -p "$T/mock-bin"
    cat > "$T/mock-bin/ubus" <<'EOF_UBUS'
#!/bin/sh
case "${Z2K_TEST_UBUS_MODE:-active}" in
    active) printf '{"z2k":{}}\n' ;;
    inactive) printf '{"network":{}}\n' ;;
    *) exit 1 ;;
esac
EOF_UBUS
    chmod 0755 "$T/mock-bin/ubus"
    _saved_path="$PATH"
    PATH="$T/mock-bin:$PATH"; export PATH
    Z2K_TEST_UBUS_MODE=active; export Z2K_TEST_UBUS_MODE
    _z2k_ow_service_running || {
        echo 'ubus подтвердил активную службу, но helper отказал' >&2
        exit 1
    }
    Z2K_TEST_UBUS_MODE=inactive
    if _z2k_ow_service_running; then
        echo 'ubus подтвердил отсутствие службы, но helper сообщил active' >&2
        exit 1
    else
        _ubus_rc=$?
    fi
    [ "$_ubus_rc" = 1 ] || {
        echo 'известная остановленная служба получила неверный код' >&2
        exit 1
    }
    Z2K_TEST_UBUS_MODE=unreadable
    if _z2k_ow_service_running; then
        echo 'ошибка ubus принята за активную службу' >&2
        exit 1
    else
        _ubus_rc=$?
    fi
    [ "$_ubus_rc" = 2 ] || {
        echo 'ошибка ubus ошибочно принята за выключенную службу' >&2
        exit 1
    }
    PATH="$_saved_path"; export PATH
    unset Z2K_TEST_UBUS_MODE
    _real_controller="$WARP_CONTROLLER_BIN"
    cat > "$T/controller" <<EOF_CONTROLLER
#!/bin/sh
printf '%s\\n' "\$*" >> "$T/controller.log"
if [ "\$1" = nft-tun-verify ] && [ "\${WARP_TEST_FAIL_TUN_NFT:-0}" = 1 ]; then
    PATH="$T/no-nft" exec "$_real_controller" "\$@"
fi
if [ "\$1" = health-plan ] && [ "\${WARP_TEST_DEFER_HEALTH:-0}" = 1 ]; then
    printf 'defer\\n'
    exit 0
fi
exec "$_real_controller" "\$@"
EOF_CONTROLLER
    chmod 0755 "$T/controller"
    WARP_CONTROLLER_BIN="$T/controller"; export WARP_CONTROLLER_BIN
    _saved_reg_stamp="$WARP_REG_STAMP"
    WARP_REG_STAMP="$T/register-attempt"; export WARP_REG_STAMP
    warp_register_due || {
        echo 'отсутствующая метка регистрации должна разрешать первую попытку' >&2
        exit 1
    }
    date +%s > "$WARP_REG_STAMP"
    if warp_register_due; then
        echo 'свежая метка регистрации ошибочно признана просроченной' >&2
        exit 1
    else
        _register_rc=$?
    fi
    [ "$_register_rc" = 1 ] || {
        echo 'свежая метка регистрации не вернула ожидание' >&2
        exit 1
    }
    mkdir "$T/register-unreadable"
    WARP_REG_STAMP="$T/register-unreadable"
    if warp_register_due; then
        echo 'ошибка чтения метки регистрации разрешила новую попытку' >&2
        exit 1
    else
        _register_rc=$?
    fi
    [ "$_register_rc" = 2 ] || {
        echo 'ошибка чтения метки регистрации не отложила попытку' >&2
        exit 1
    }
    grep -q '^register-due ' "$T/controller.log"
    WARP_REG_STAMP="$_saved_reg_stamp"; export WARP_REG_STAMP
    : > "$T/service-actions"
    _z2k_ow_service_running() {
        case "${Z2K_TEST_SERVICE_ACTIVE:-0}" in
            1) return 0 ;;
            unreadable) return 2 ;;
            *) return 1 ;;
        esac
    }
    _z2k_ow_warp_service_reload() { printf 'reload\n' >> "$T/service-actions"; }
    _z2k_ow_warp_service_rebuild() { printf 'rebuild\n' >> "$T/service-actions"; }
    Z2K_TEST_SERVICE_ACTIVE=1
    _warp_service_transition enable 0 1
    _warp_service_transition enable 1 1
    _warp_service_transition disable 0 1
    _warp_service_transition disable 0 0
    _warp_service_transition restart 1 0
    Z2K_TEST_SERVICE_ACTIVE=0
    _warp_service_transition enable 0 0
    Z2K_TEST_SERVICE_ACTIVE=unreadable
    if _warp_service_transition enable 0 0; then
        echo 'ошибка чтения ubus пропущена как выключенная служба' >&2
        exit 1
    else
        _service_rc=$?
    fi
    [ "$_service_rc" = 2 ] || {
        echo 'нечитаемое состояние службы не отложило переход' >&2
        exit 1
    }
    [ "$(cat "$T/service-actions")" = "$(printf 'rebuild\nreload\nrebuild\nreload\nrebuild')" ]
    grep -q '^service-plan enable 0 1 1$' "$T/controller.log"
    grep -q '^service-plan enable 1 1 1$' "$T/controller.log"
    grep -q '^service-plan disable 0 1 1$' "$T/controller.log"
    grep -q '^service-plan disable 0 1 0$' "$T/controller.log"
    grep -q '^service-plan restart 1 1 0$' "$T/controller.log"
    grep -q '^service-plan enable 0 0 0$' "$T/controller.log"
    grep -q '^service-plan enable 0 unreadable 0$' "$T/controller.log"
    if ! _warp_process_check; then
        echo 'Rust-контроллер не подтвердил зарегистрированный процесс WARP' >&2
        exit 1
    fi
    grep -q '^process-observe ' "$T/controller.log"
    warp_domain_error_set nft-observer-unavailable
    [ "$(cat "$WARP_DOMAIN_ERROR")" = nft-observer-unavailable ]
    grep -q "^domains-error $WARP_DOMAIN_ERROR nft-observer-unavailable$" \
        "$T/controller.log"
    warp_domain_error_set ""
    [ ! -e "$WARP_DOMAIN_ERROR" ]
    WARP_ROUTE_ERROR_FILE="$T/route-error"; export WARP_ROUTE_ERROR_FILE
    _warp_route_error_set pbr-apply-failed
    grep -Eq '^pbr-apply-failed [0-9]+$' "$WARP_ROUTE_ERROR_FILE"
    _warp_route_error_set tun-apply-failed
    grep -Eq '^pbr-apply-failed [0-9]+$' "$WARP_ROUTE_ERROR_FILE"
    grep -q "^route-error-set $WARP_ROUTE_ERROR_FILE pbr-apply-failed$" "$T/controller.log"
    _warp_route_error_clear
    [ ! -e "$WARP_ROUTE_ERROR_FILE" ]
    grep -q "^route-error-clear $WARP_ROUTE_ERROR_FILE$" "$T/controller.log"
    WARP_OP_FILE="$T/warp-operation"; export WARP_OP_FILE
    warp_op_begin
    [ "$(cat "$WARP_OP_FILE")" = "$$" ]
    [ "$(warp_op_current && echo current)" = current ]
    grep -q "^op-begin $WARP_OP_FILE $$" "$T/controller.log"
    _warp_user_probe() { warp_op_current; }
    _warp_user_locked _warp_user_probe
    [ ! -e "$WARP_OP_FILE" ]
    grep -q "^op-clear $WARP_OP_FILE $$" "$T/controller.log"
    _warp_user_probe_superseded() { printf '999999\n' > "$WARP_OP_FILE"; }
    _warp_user_locked _warp_user_probe_superseded
    [ "$(cat "$WARP_OP_FILE")" = 999999 ]
    rm -f "$WARP_OP_FILE"
    WARP_PROCD_RECOVERY_FILE="$T/procd-recovery-attempt"; export WARP_PROCD_RECOVERY_FILE
    _warp_procd_recovery_claim 12345
    [ "$(cat "$WARP_PROCD_RECOVERY_FILE")" = 'attempted 12345' ]
    if _warp_procd_recovery_claim 67890; then
        echo 'Rust разрешил повторное восстановление procd в том же цикле' >&2
        exit 1
    fi
    [ "$(cat "$WARP_PROCD_RECOVERY_FILE")" = 'attempted 12345' ]
    _warp_procd_recovery_clear
    [ ! -e "$WARP_PROCD_RECOVERY_FILE" ]
    grep -q "^procd-recovery-claim $WARP_PROCD_RECOVERY_FILE 12345$" "$T/controller.log"
    grep -q "^procd-recovery-claim $WARP_PROCD_RECOVERY_FILE 67890$" "$T/controller.log"
    grep -q "^procd-recovery-clear $WARP_PROCD_RECOVERY_FILE$" "$T/controller.log"
    : > "$T/controller.log"
    : > "$T/procd-recovery-rebuild-count"
    WARP_PROCD_INSTANCE_FILE="$T/procd-instance"; export WARP_PROCD_INSTANCE_FILE
    warp_note_death() { :; }
    _warp_route_error_set() { :; }
    _warp_converge_off() { return 0; }
    _z2k_ow_warp_procd_instance_registered() { return 1; }
    _z2k_ow_service_running() { return 0; }
    _z2k_ow_warp_service_rebuild() {
        printf x >> "$T/procd-recovery-rebuild-count"
        : > "$WARP_PROCD_INSTANCE_FILE"
    }
    _warp_wait_and_pbr() { return 0; }
    if _warp_health_process_absent; then :; else exit 1; fi
    if _warp_health_process_absent; then :; else exit 1; fi
    [ "$(wc -c < "$T/procd-recovery-rebuild-count")" -eq 1 ]
    grep -Eq "^procd-recovery-claim $WARP_PROCD_RECOVERY_FILE [0-9]+$" "$T/controller.log"
    rm -f "$WARP_PROCD_RECOVERY_FILE" "$WARP_PROCD_INSTANCE_FILE"
    mkdir -p "$T/openwrt-bin"
    cat > "$T/openwrt-bin/uci" <<'EOF_UCI'
#!/bin/sh
case "$*" in
    '-d @ show firewall')
        printf '%s\n' \
            'firewall.@zone[0]=zone' \
            "firewall.@zone[0].name='lan'" \
            "firewall.@zone[0].network='lan'@'guest'" \
            "firewall.@zone[0].device='br-extra'"
        ;;
    '-d @ show network')
        printf '%s\n' \
            'network.lan=interface' "network.lan.device='br-config'" \
            'network.guest=interface' "network.guest.ifname='wlan-guest'"
        ;;
    *) exit 1 ;;
esac
EOF_UCI
    cat > "$T/openwrt-bin/ubus" <<'EOF_UBUS'
#!/bin/sh
if [ "$*" = 'call network.interface.lan status' ]; then
    printf '{"device":"br-runtime"}\n'
    exit 0
fi
exit 1
EOF_UBUS
    chmod 0755 "$T/openwrt-bin/uci" "$T/openwrt-bin/ubus"
    PATH="$T/openwrt-bin:$PATH"; export PATH
    unset Z2K_WARP_DOMAIN_LAN_DEVICES
    [ "$(warp_domain_lan_devices)" = "$(printf 'br-extra\nbr-runtime\nwlan-guest')" ]
    grep -q '^interfaces lan$' "$T/controller.log"
    mkdir -p "$WARP_LISTS_DIR" "$WARP_GAMES_DIR"
    printf '8.8.8.8\n' > "$WARP_LISTS_DIR/custom.txt"
    chmod 0600 "$WARP_LISTS_DIR/custom.txt"
    printf 'legacy\n' > "$WARP_LISTS_DIR/game-warp-ips.txt"
    warp_lists_migrate
    [ -f "$WARP_LISTS_DIR/.legacy-aggregate-purged" ]
    [ ! -e "$WARP_LISTS_DIR/game-warp-ips.txt" ]
    [ "$(stat -c %a "$WARP_LISTS_DIR/custom.txt")" = 644 ]
    grep -q '^list-migrate ' "$T/controller.log"
    printf 'GAME_WARP_ENABLED=1\n' > "$Z2K_ETC/config"
    CONFIG_FILE="$Z2K_ETC/config"; export CONFIG_FILE
    [ "$(warp_flag)" = 1 ]
    [ "$(warp_cfg GAME_WARP_ENABLED none)" = 1 ]
    [ "$(_warp_enabled_config_observe)" = 1 ]
    grep -q "^config-read $CONFIG_FILE GAME_WARP_ENABLED  first$" "$T/controller.log"
    grep -q "^config-read $CONFIG_FILE GAME_WARP_ENABLED none last$" "$T/controller.log"
    grep -q "^config-read $CONFIG_FILE ENABLED 1 last$" "$T/controller.log"
    printf 'GAME_WARP_ENABLED=1\nOTHER_FEATURE=preserve-me\n' > "$CONFIG_FILE"
    warp_set_flag 0
    [ "$(cat "$CONFIG_FILE")" = "$(printf 'GAME_WARP_ENABLED=0\nOTHER_FEATURE=preserve-me')" ]
    grep -q "^warp-flag-set $CONFIG_FILE 0$" "$T/controller.log"
    mkdir "$CONFIG_FILE.z2k-flaglock"
    if warp_set_flag 1 >/dev/null 2>&1; then
        echo 'Rust config writer changed WARP intent while the shared config lock was busy' >&2
        exit 1
    fi
    grep -q '^GAME_WARP_ENABLED=0$' "$CONFIG_FILE"
    rm -r "$CONFIG_FILE.z2k-flaglock"
    printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$CONFIG_FILE"
    WARP_BIN="$T/boot-engine" WARP_DEVICE="$T/boot-device"; export WARP_BIN WARP_DEVICE
    printf '#!/bin/sh\n' > "$WARP_BIN"
    chmod 0755 "$WARP_BIN"
    printf 'registered\n' > "$WARP_DEVICE"
    warp_wanted_boot
    grep -q "^boot-plan $CONFIG_FILE $WARP_BIN $WARP_DEVICE$" "$T/controller.log"
    [ "$(warp_scope)" = lists ]
    printf 'new user file\n' > "$WARP_LISTS_DIR/game-warp-ips.txt"
    warp_lists_migrate
    [ -f "$WARP_LISTS_DIR/game-warp-ips.txt" ]
    mv "$WARP_LISTS_DIR/custom.txt" "$T/custom.txt"
    printf 'game-warp-ips\n' > "$WARP_LISTS_DIR/.disabled"
    printf 'aa:bb:cc:dd:ee:ff\n' > "$WARP_DEVICES_FILE"
    [ "$(warp_scope)" = devices ]
    printf '192.168.1.8\n8.8.8.8\n' > "$WARP_DEVICES_FILE"
    [ "$(warp_devices_ips)" = '192.168.1.8' ]
    grep -q "^device-ips $WARP_DEVICES_FILE $WARP_DHCP_LEASES$" "$T/controller.log"
    [ "$("$_real_controller" policy-scope "$WARP_LISTS_DIR" "$WARP_GAMES_DIR" \
        "$WARP_ENABLED_FILE" "$WARP_DEVICES_FILE")" = full ]
    grep -q '^policy-scope ' "$T/controller.log"
    _z2k_ow_warp_lock 0
    [ "$(cat "$WARP_LOCK_DIR/pid")" = "$$" ]
    grep -q "^lock-acquire $$ 0$" "$T/controller.log"
    _z2k_ow_warp_unlock
    [ ! -e "$WARP_LOCK_DIR" ]
    grep -q "^lock-release $$$" "$T/controller.log"
    mv "$T/custom.txt" "$WARP_LISTS_DIR/custom.txt"
    rm -f "$WARP_LISTS_DIR/.disabled"
    rm -f "$WARP_DEVICES_FILE"
    nft add table inet "$Z2K_WARP_NFT_TABLE"
    nft add set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_dst4 '{ type ipv4_addr; flags interval; }'
    nft add set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_src4 '{ type ipv4_addr; flags interval; }'
    warp_devices_selected() { return 1; }
    warp_full_device_mode() { return 1; }
    warp_all_traffic_mode() { return 1; }
    warp_list_routes_active() { return 1; }
    warp_wdtt_routes_active() { return 1; }
    warp_validated_domains() { return 0; }
    warp_wireguard_server_devices() { return 0; }
    warp_wireguard_client_devices() { return 0; }
    warp_nft_rules_apply
    nft list chain inet "$Z2K_WARP_NFT_TABLE" z2k_warp_mark | grep -F 'ip daddr @z2k_warp_dst4 meta mark set'
    nft delete table inet "$Z2K_WARP_NFT_TABLE"
    warp_probe_route_up
    warp_probe_route_up
    ip rule show | grep -q '499:.*from 172.16.9.9.*lookup 989'
    ip route show table 989 | grep -q '^default dev z2ktun0'
    nft add table inet "$Z2K_WARP_NFT_TABLE"
    nft add set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_dst4 '{ type ipv4_addr; flags interval; }'
    nft add set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_src4 '{ type ipv4_addr; flags interval; }'
    nft add table inet fw4
    nft add chain inet fw4 forward '{ type filter hook forward priority filter; policy accept; }'
    warp_nft_rules_apply
    warp_nft_tun_apply z2ktun0
    warp_nft_tun_verify z2ktun0
    warp_nft_rules_verify
    grep -q '^nft-mark-verify ' "$T/controller.log"
    grep -q '^nft-tun-verify ' "$T/controller.log"
    grep -q '^nft-fw4-forward-apply inet fw4 forward z2ktun0 0x80000000 0x80000000 ' \
        "$T/controller.log"
    grep -q '^nft-fw4-forward-verify inet fw4 forward z2ktun0 0x80000000 0x80000000 ' \
        "$T/controller.log"
    nft -a list chain inet fw4 forward > "$T/fw4.before-idempotent-apply"
    _warp_fw4_forward_apply z2ktun0
    nft -a list chain inet fw4 forward > "$T/fw4.after-idempotent-apply"
    cmp "$T/fw4.before-idempotent-apply" "$T/fw4.after-idempotent-apply"
    printf '%s\n' \
        'add rule inet fw4 forward meta mark & 0x80000000 == 0x80000000 oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"' \
        | nft -f -
    "$WARP_CONTROLLER_BIN" nft-fw4-forward-apply inet fw4 forward \
        z2ktun1 0x80000000 0x80000000 '!z2k: WARP forwarded traffic'
    _warp_fw4_forward_remove_runtime
    nft list chain inet fw4 forward | grep -F 'oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"'
    if nft list chain inet fw4 forward | grep -E 'oifname "z2ktun[0-9]+"'; then
        echo 'временные fw4 fallback-правила WARP остались после очистки' >&2
        exit 1
    fi
    _warp_fw4_forward_apply z2ktun0

    mkdir -p "$T/etc" "$T/state/warp"
    printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$T/etc/config"
    printf '{"addr_v4":"172.16.9.9"}\n' > "$T/device.json"
    printf '#!/bin/sh\nexit 0\n' > "$T/z2k-warpd"
    chmod 0755 "$T/z2k-warpd"
    WARP_BIN="$T/z2k-warpd" WARP_DEVICE="$T/device.json"; export WARP_BIN WARP_DEVICE
    if ! _warp_proven_ready; then
        echo 'Rust-контроллер не подтвердил готовый WARP-процесс' >&2
        exit 1
    fi
    warp_running() { touch "$WARP_STATUS"; return 0; }
    warp_probe_route_up() { return 0; }
    if ! _warp_wait_ready 2; then
        echo 'Rust-контроллер не подтвердил свежий status через реальный iproute2' >&2
        exit 1
    fi
    [ "$("$_real_controller" health-plan "$CONFIG_FILE" "$WARP_BIN" \
        "$WARP_DEVICE" "$WARP_STATUS" "$Z2K_PROC_ROOT")" = 'ready z2ktun0' ]
    grep -q "^runtime-observe $WARP_STATUS $Z2K_PROC_ROOT$" "$T/controller.log"
    grep -Eq "^ready-observe-since $WARP_STATUS $Z2K_PROC_ROOT [0-9]+$" \
        "$T/controller.log"
    : > "$T/controller.log"
    mv "$Z2K_PROC_ROOT/101" "$T/101.ready-wait"
    date() { return 1; }
    sleep() { :; }
    if _warp_wait_ready 1; then
        echo 'неизвестное время было принято как подтверждение готовности' >&2
        exit 1
    else
        _ready_wait_rc=$?
    fi
    [ "$_ready_wait_rc" = 1 ]
    grep -q "^ready-observe-since $WARP_STATUS $Z2K_PROC_ROOT 0$" \
        "$T/controller.log"
    if grep -q '^route-apply ' "$T/controller.log"; then
        echo 'PBR изменён при неизвестном времени начала ожидания' >&2
        exit 1
    fi
    unset -f date sleep
    mv "$T/101.ready-wait" "$Z2K_PROC_ROOT/101"
    unset Z2K_PROC_ROOT
    WARP_TEST_DEFER_HEALTH=1; export WARP_TEST_DEFER_HEALTH
    z2k_ow_warp_check
    grep -q "^health-plan $CONFIG_FILE $WARP_BIN $WARP_DEVICE $WARP_STATUS /proc$" \
        "$T/controller.log"
    unset WARP_TEST_DEFER_HEALTH
    Z2K_PROC_ROOT="$T/proc"; export Z2K_PROC_ROOT
    warp_running() { return 0; }
    warp_pbr_up
    grep -q '^route-apply z2ktun0 172.16.9.9 989 500 499 0x80000000 0x80000000 ' \
        "$T/controller.log"
    warp_pbr_verify
    grep -q '^route-verify ' "$T/controller.log"
    ip -4 rule show > "$T/rules.route-reconcile.before"
    ip -4 route show table 989 > "$T/routes.route-reconcile.before"
    z2k_ow_warp_check
    grep -q '^route-reconcile z2ktun0 172.16.9.9 989 500 499 0x80000000 0x80000000 ' \
        "$T/controller.log"
    ip -4 rule show > "$T/rules.route-reconcile.after"
    ip -4 route show table 989 > "$T/routes.route-reconcile.after"
    cmp "$T/rules.route-reconcile.before" "$T/rules.route-reconcile.after"
    cmp "$T/routes.route-reconcile.before" "$T/routes.route-reconcile.after"
    mv "$CONFIG_FILE" "$T/config.boot-plan"
    mkdir "$CONFIG_FILE"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.boot-plan.before"
    ip -4 rule show > "$T/rules.boot-plan.before"
    ip -4 route show table 989 > "$T/routes.boot-plan.before"
    if _z2k_ow_warp_dispatch rules; then :; else exit 1; fi
    [ "$_WARP_BOOT_PLAN" = defer ]
    grep -q "^boot-plan $CONFIG_FILE $WARP_BIN $WARP_DEVICE$" "$T/controller.log"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.boot-plan.after"
    ip -4 rule show > "$T/rules.boot-plan.after"
    ip -4 route show table 989 > "$T/routes.boot-plan.after"
    cmp "$T/nft.boot-plan.before" "$T/nft.boot-plan.after"
    cmp "$T/rules.boot-plan.before" "$T/rules.boot-plan.after"
    cmp "$T/routes.boot-plan.before" "$T/routes.boot-plan.after"
    rmdir "$CONFIG_FILE"
    mv "$T/config.boot-plan" "$CONFIG_FILE"
    ip -4 rule show > "$T/rules.policy-plan.before"
    ip -4 route show table 989 > "$T/routes.policy-plan.before"
    _warp_policy_plan enabled ready present
    [ "$_WARP_POLICY_ACTION" = noop ]
    grep -q '^policy-plan enabled ready present$' "$T/controller.log"
    ip -4 rule show > "$T/rules.policy-plan.after"
    ip -4 route show table 989 > "$T/routes.policy-plan.after"
    cmp "$T/rules.policy-plan.before" "$T/rules.policy-plan.after"
    cmp "$T/routes.policy-plan.before" "$T/routes.policy-plan.after"

    mkdir -p "$T/no-nft"
    warp_validated_dst() { return 97; }
    warp_devices_ips() { return 97; }
    warp_validated_domains() { return 97; }
    warp_nft_sets_load
    nft list set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_dst4 | grep -qF '8.8.8.8'
    . "$ROOT/platform/openwrt/warp.sh"
    warp_validated_dst() { printf '9.9.9.9\n'; }
    warp_nft_sets_verify
    grep -q '^nft-sets-verify ' "$T/controller.log"
    . "$ROOT/platform/openwrt/warp.sh"
    ip -4 rule show > "$T/rules.tun-read-failure.before"
    ip -4 route show table 989 > "$T/routes.tun-read-failure.before"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.tun-read-failure.before"
    WARP_TEST_FAIL_TUN_NFT=1; export WARP_TEST_FAIL_TUN_NFT
    z2k_ow_warp_check || {
        unset WARP_TEST_FAIL_TUN_NFT
        echo 'временная ошибка чтения TUN nft повредила проверку' >&2
        exit 1
    }
    grep -q "^health-plan $CONFIG_FILE $WARP_BIN $WARP_DEVICE $WARP_STATUS $Z2K_PROC_ROOT$" \
        "$T/controller.log"
    unset WARP_TEST_FAIL_TUN_NFT
    ip -4 rule show > "$T/rules.tun-read-failure.after"
    ip -4 route show table 989 > "$T/routes.tun-read-failure.after"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.tun-read-failure.after"
    cmp "$T/rules.tun-read-failure.before" "$T/rules.tun-read-failure.after"
    cmp "$T/routes.tun-read-failure.before" "$T/routes.tun-read-failure.after"
    diff -u "$T/nft.tun-read-failure.before" "$T/nft.tun-read-failure.after" || {
        echo 'изменение nft при ошибке чтения TUN:' >&2
        exit 1
    }
    grep -q '^nft-tun-verify ' "$T/controller.log"

    _saved_status="$T/status.saved"
    mv "$WARP_STATUS" "$_saved_status"
    z2k_ow_warp_check
    ip rule show | grep -q '500:.*fwmark 0x80000000/0x80000000 lookup 989'
    ip route show table 989 | grep -q '^default dev z2ktun0'
    [ -s "$WARP_PBR_OWNER" ]
    mv "$_saved_status" "$WARP_STATUS"

    _real_ip="$(command -v ip)"
    mkdir -p "$T/failbin"
    cat > "$T/failbin/ip" <<EOF_IP
#!/bin/sh
if [ "\$1" = rule ] && [ "\$2" = show ]; then exit 1; fi
exec "$_real_ip" "\$@"
EOF_IP
    chmod 0755 "$T/failbin/ip"
    _saved_path="$PATH"
    "$_real_ip" -4 rule show > "$T/rules.read-failure.before"
    "$_real_ip" -4 route show table 989 > "$T/routes.read-failure.before"
    PATH="$T/failbin:$_saved_path"; export PATH
    z2k_ow_warp_check || { PATH="$_saved_path"; export PATH; exit 1; }
    PATH="$_saved_path"; export PATH
    "$_real_ip" -4 rule show > "$T/rules.read-failure.after"
    "$_real_ip" -4 route show table 989 > "$T/routes.read-failure.after"
    cmp "$T/rules.read-failure.before" "$T/rules.read-failure.after"
    cmp "$T/routes.read-failure.before" "$T/routes.read-failure.after"

    mkdir -p "$T/config-read-error"
    _saved_config_file="$CONFIG_FILE"
    CONFIG_FILE="$T/config-read-error"; export CONFIG_FILE
    "$_real_ip" -4 rule show > "$T/rules.config-read-failure.before"
    "$_real_ip" -4 route show table 989 > "$T/routes.config-read-failure.before"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.config-read-failure.before"
    z2k_ow_warp_check || { PATH="$_saved_path"; export PATH; exit 1; }
    CONFIG_FILE="$_saved_config_file"; export CONFIG_FILE
    "$_real_ip" -4 rule show > "$T/rules.config-read-failure.after"
    "$_real_ip" -4 route show table 989 > "$T/routes.config-read-failure.after"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.config-read-failure.after"
    cmp "$T/rules.config-read-failure.before" "$T/rules.config-read-failure.after"
    cmp "$T/routes.config-read-failure.before" "$T/routes.config-read-failure.after"
    cmp "$T/nft.config-read-failure.before" "$T/nft.config-read-failure.after"

    printf 'не procfs\n' > "$T/proc-root-file"
    Z2K_PROC_ROOT="$T/proc-root-file"; export Z2K_PROC_ROOT
    "$_real_ip" -4 rule show > "$T/rules.proc-read-failure.before"
    "$_real_ip" -4 route show table 989 > "$T/routes.proc-read-failure.before"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.proc-read-failure.before"
    z2k_ow_warp_check || { Z2K_PROC_ROOT="$T/proc"; export Z2K_PROC_ROOT; exit 1; }
    Z2K_PROC_ROOT="$T/proc"; export Z2K_PROC_ROOT
    "$_real_ip" -4 rule show > "$T/rules.proc-read-failure.after"
    "$_real_ip" -4 route show table 989 > "$T/routes.proc-read-failure.after"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.proc-read-failure.after"
    cmp "$T/rules.proc-read-failure.before" "$T/rules.proc-read-failure.after"
    cmp "$T/routes.proc-read-failure.before" "$T/routes.proc-read-failure.after"
    cmp "$T/nft.proc-read-failure.before" "$T/nft.proc-read-failure.after"

    mkdir -p "$WARP_LISTS_DIR" "$WARP_GAMES_DIR"
    printf 'Example.com\n' > "$WARP_LISTS_DIR/custom.txt"
    warp_validated_domains() {
        _warp_controller domains-list "$WARP_LISTS_DIR" "$WARP_GAMES_DIR" "$WARP_ENABLED_FILE"
    }
    warp_domain_rules_load
    printf 'v1\nexample.com\n' > "$T/domains.expected"
    cmp "$T/domains.expected" "$WARP_DOMAIN_RULES"
    warp_domain_set_ensure
    Z2K_WARP_DOMAIN_LAN_DEVICES=br-lan; export Z2K_WARP_DOMAIN_LAN_DEVICES
    warp_domain_observer_rules_apply
    warp_domain_backend_ready
    grep -q '^domains-list ' "$T/controller.log"
    grep -q '^domains-sync ' "$T/controller.log"
    grep -q '^nft-domain-set-ensure ' "$T/controller.log"
    grep -q '^nft-domain-observer-apply ' "$T/controller.log"
    grep -q '^nft-domain-verify ' "$T/controller.log"
    WARP_DOMAIN_NFLOG_GROUP=190
    if warp_domain_backend_ready; then
        echo 'неверная NFLOG group принята за готовый backend' >&2
        exit 1
    fi
    WARP_DOMAIN_NFLOG_GROUP=189

    warp_nft_sets_load
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.reload-noop.before"
    warp_nft_sets_reload_if_changed
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.reload-noop.after"
    cmp "$T/nft.reload-noop.before" "$T/nft.reload-noop.after"
    printf '1.2.3.4\n' > "$WARP_LISTS_DIR/custom.txt"
    warp_nft_sets_reload_if_changed
    nft list set inet "$Z2K_WARP_NFT_TABLE" z2k_warp_dst4 | grep -qF '1.2.3.4'
    grep -q '^nft-sets-verify ' "$T/controller.log"
    grep -q '^nft-sync ' "$T/controller.log"
    _real_nft="$(command -v nft)"
    cat > "$T/failbin/nft" <<EOF_NFT
#!/bin/sh
if [ "\$1" = list ] && { [ "\$2" = tables ] || [ "\$2" = table ]; }; then exit 1; fi
exec "$_real_nft" "\$@"
EOF_NFT
    chmod 0755 "$T/failbin/nft"
    PATH="$T/failbin:$_saved_path"; export PATH
    if warp_nft_sets_verify; then
        PATH="$_saved_path"; export PATH
        echo 'ошибка чтения nft ошибочно подтверждена для sets' >&2
        exit 1
    else
        _verify_rc=$?
        [ "$_verify_rc" = 2 ] || { PATH="$_saved_path"; export PATH; exit 1; }
    fi
    PATH="$_saved_path"; export PATH
    "$_real_ip" -4 rule show > "$T/rules.nft-read-failure.before"
    "$_real_ip" -4 route show table 989 > "$T/routes.nft-read-failure.before"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.nft-read-failure.before"
    PATH="$T/failbin:$_saved_path"; export PATH
    z2k_ow_warp_check || { PATH="$_saved_path"; export PATH; exit 1; }
    PATH="$_saved_path"; export PATH
    "$_real_ip" -4 rule show > "$T/rules.nft-read-failure.after"
    "$_real_ip" -4 route show table 989 > "$T/routes.nft-read-failure.after"
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/nft.nft-read-failure.after"
    cmp "$T/rules.nft-read-failure.before" "$T/rules.nft-read-failure.after"
    cmp "$T/routes.nft-read-failure.before" "$T/routes.nft-read-failure.after"
    cmp "$T/nft.nft-read-failure.before" "$T/nft.nft-read-failure.after"
    grep -q '^nft-mark-verify ' "$T/controller.log"

    PATH="$T/failbin:$_saved_path"; export PATH
    if warp_domain_backend_ready; then
        PATH="$_saved_path"; export PATH
        echo 'ошибка чтения nft принята за готовый backend' >&2
        exit 1
    fi
    PATH="$_saved_path"; export PATH

    nft add chain inet "$Z2K_WARP_NFT_TABLE" z2k_shell_foreign
    nft add rule inet "$Z2K_WARP_NFT_TABLE" z2k_shell_foreign counter
    _warp_tun_clear
    ! nft list chain inet "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_MSS" | grep -q 'tcp option maxseg'
    ! nft list chain inet "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_FWD" | grep -q 'oifname'
    ! nft list chain inet "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_NAT" | grep -q 'masquerade'
    _warp_mark_clear
    ! nft list chain inet "$Z2K_WARP_NFT_TABLE" "$WARP_CHAIN_MARK" | grep -q 'meta mark set'
    nft list chain inet "$Z2K_WARP_NFT_TABLE" z2k_shell_foreign | grep -F 'counter'
    grep -q "^nft-chain-clear inet $Z2K_WARP_NFT_TABLE $WARP_CHAIN_MSS" "$T/controller.log"
    grep -q "^nft-chain-clear inet $Z2K_WARP_NFT_TABLE $WARP_CHAIN_MARK$" "$T/controller.log"

    warp_pbr_down
    grep -q '^route-remove-owned z2ktun0 172.16.9.9 989 500 499 0x80000000 0x80000000 ' \
        "$T/controller.log"
    ! ip rule show | grep -q '499:.*from 172.16.9.9.*lookup 989'
    [ -z "$(ip route show table 989 2>/dev/null)" ]
    warp_nft_remove full
    grep -q "^nft-warp-remove $Z2K_WARP_NFT_FAMILY $Z2K_WARP_NFT_TABLE 1 " \
        "$T/controller.log"
    if nft list set inet "$Z2K_WARP_NFT_TABLE" "$WARP_SET" >/dev/null 2>&1; then
        echo 'полная Shell-очистка оставила WARP-набор' >&2
        exit 1
    fi
    nft list chain inet "$Z2K_WARP_NFT_TABLE" z2k_shell_foreign | grep -F 'counter'
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/remove.before-repeat"
    warp_nft_remove full
    nft -a list table inet "$Z2K_WARP_NFT_TABLE" > "$T/remove.after-repeat"
    cmp "$T/remove.before-repeat" "$T/remove.after-repeat"

    # Обновление upstream-списков держит тот же реальный Rust lock, что и CLI.
    ZAPRET2_DIR="$T/list-updater"; export ZAPRET2_DIR
    CONFIG_FILE="$T/etc/config"; export CONFIG_FILE
    LOG_FILE="$T/list-updater.log"; export LOG_FILE
    Z2K_WARP_IPSET_SCRIPT="$ROOT/platform/openwrt/warp.sh"; export Z2K_WARP_IPSET_SCRIPT
    mkdir -p "$ZAPRET2_DIR/lists/warp/games" "$T/etc"
    cp "$ROOT/files/z2k-warp-list-filter.awk" "$ZAPRET2_DIR/z2k-warp-list-filter.awk"
    printf 'GAME_WARP_ENABLED=0\n' > "$CONFIG_FILE"
    printf '{"game_map":{"LockProbe":["hint"]}}\n' > "$T/list-index.json"
    Z2K_UL_SOURCE_ONLY=1
    . "$ROOT/files/z2k-update-lists.sh"
    unset Z2K_UL_SOURCE_ONLY
    z2k_fetch() { cp "$T/list-index.json" "$2"; }
    update_list() {
        sleep 30 &
        _lock_probe_pid=$!
        if [ "$(cat "$WARP_LOCK_DIR/pid")" != "$$" ]; then
            kill "$_lock_probe_pid" 2>/dev/null || true
            wait "$_lock_probe_pid" 2>/dev/null || true
            return 1
        fi
        if Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$_real_controller" \
            lock-acquire "$_lock_probe_pid" 0 >/dev/null 2>&1; then
            Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$_real_controller" \
                lock-release "$_lock_probe_pid" >/dev/null 2>&1 || true
            kill "$_lock_probe_pid" 2>/dev/null || true
            wait "$_lock_probe_pid" 2>/dev/null || true
            return 1
        fi
        kill "$_lock_probe_pid" 2>/dev/null || true
        wait "$_lock_probe_pid" 2>/dev/null || true
        printf '8.8.8.8\n' > "$3"
        return 2
    }
    update_warp_game_list
    grep -q "^lock-acquire $$ 30$" "$T/controller.log"
    grep -q "^lock-release $$" "$T/controller.log"
    [ ! -e "$WARP_LOCK_DIR" ]
    grep -qx '8.8.8.8' "$ZAPRET2_DIR/lists/warp/games/LockProbe.txt"
    Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$_real_controller" lock-acquire "$$" 0
    Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$_real_controller" lock-release "$$"
    [ ! -e "$WARP_LOCK_DIR" ]

    printf 'SUITE[ow-warp-controller-shell-entry-real]: pass\n'
    exit 0
fi

for tool in cargo unshare ip nft; do
    command -v "$tool" >/dev/null 2>&1 || { echo "требуется реальный инструмент $tool" >&2; exit 1; }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-controller-shell.XXXXXX")"
_cleanup_temp() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
        sudo -n rm -rf "$T" || _rc=$?
    else
        rm -rf "$T" || _rc=$?
    fi
    exit "$_rc"
}
trap _cleanup_temp EXIT HUP INT TERM
CARGO_TARGET_DIR="$T/cargo-target" cargo build --manifest-path "$CRATE/Cargo.toml" --bin z2k-warp-controller
export CARGO_TARGET_DIR="$T/cargo-target"
export WARP_CONTROLLER_BIN="$CARGO_TARGET_DIR/debug/z2k-warp-controller"
if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        unshare -n "$0" --inside "$T"
    else
        sudo -n env HOME="$HOME" PATH="$PATH" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
            RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
            WARP_CONTROLLER_BIN="$WARP_CONTROLLER_BIN" unshare -n "$0" --inside "$T"
    fi
else
    unshare -Urn "$0" --inside "$T"
fi
