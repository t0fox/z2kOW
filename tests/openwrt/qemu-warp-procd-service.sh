#!/bin/sh
# Проверяет отдельный WARP instance через настоящий procd в OpenWrt QEMU.
set -eu

ROOT="${Z2K_WARP_QEMU_ROOT:-/usr/lib/z2k}"
INIT="${Z2K_WARP_QEMU_INIT:-/etc/init.d/z2k-warp}"
CONTROLLER="${Z2K_WARP_QEMU_CONTROLLER:-$ROOT/platform/openwrt/bin/linux-x86_64/z2k-warp-controller}"
T=/tmp/z2k-warp-procd-qemu
ENGINE="$T/z2k-warpd"
PID_FILE="$T/tmp/runtime/warpd.pid"
START_FILE="$T/engine-starts"
NFT_TABLE=z2k_warp_procd_qemu
REAL_CONTROLLER="$CONTROLLER"
CONTROLLER_CALLS="$T/controller.calls"
MAIN_INIT=/etc/init.d/z2k
MAIN_PID_DIR="$T/main-pids"
_fixture_created=0
_configured=0
_service_started=0
_main_service_started=0
_main_init_created=0
_table_created=0

cleanup() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "$_service_started" = 1 ]; then
        "$INIT" stop >/dev/null 2>&1 || _rc=1
    fi
    if [ "$_main_service_started" = 1 ]; then
        "$MAIN_INIT" stop >/dev/null 2>&1 || _rc=1
    fi
    if [ "$_main_init_created" = 1 ]; then
        rm -f "$MAIN_INIT"
    fi
    if [ "$_configured" = 1 ]; then
        "$CONTROLLER" event cleanup >/dev/null 2>&1 || _rc=1
    fi
    if [ "$_table_created" = 1 ]; then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || _rc=1
    fi
    if [ "$_fixture_created" = 1 ]; then
        rm -rf "$T"
    fi
    exit "$_rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ -x "$INIT" ] && [ -x "$CONTROLLER" ]
[ -x /sbin/procd ] && command -v ubus >/dev/null 2>&1
[ -x /usr/sbin/nft ] && command -v ip >/dev/null 2>&1
ip -Version 2>&1 | grep -Eq 'iproute2|BusyBox' || {
    echo 'QEMU требует рабочий iproute2 или BusyBox ip' >&2
    exit 1
}
[ ! -e "$MAIN_INIT" ] || { echo 'QEMU содержит службу z2k; нужен чистый тестовый образ' >&2; exit 1; }
[ ! -e "$T" ] || { echo 'каталог QEMU procd-теста уже занят' >&2; exit 1; }
_fixture_created=1

mkdir -p "$T/etc/state/warp" "$T/etc/user-lists/warp/games" \
    "$MAIN_PID_DIR" "$T/main-daemons" "$T/legacy" \
    "$T/lists/warp/games" "$T/tmp/warp" "$T/tmp/runtime"
for _proxy in nfqws2 z2k-rt-proxy tg-ws-proxy; do
    cat > "$T/main-daemons/$_proxy" <<EOF_MAIN_PROCESS
#!/bin/sh
printf '%s\\n' "\$\$" > '$MAIN_PID_DIR/$_proxy.pid'
exec /bin/sleep 300
EOF_MAIN_PROCESS
    chmod 0755 "$T/main-daemons/$_proxy"
done
cat > "$T/legacy/z2k-warpd" <<EOF_LEGACY_ENGINE
#!/bin/sh
printf '%s\\n' "\$\$" > '$T/legacy.pid'
trap 'kill "\$_child" 2>/dev/null || true; wait "\$_child" 2>/dev/null || true; exit 0' TERM INT
while :; do
    /bin/sleep 300 &
    _child=\$!
    wait "\$_child" || true
done
EOF_LEGACY_ENGINE
chmod 0755 "$T/legacy/z2k-warpd"
cat > "$MAIN_INIT" <<EOF_MAIN_INIT
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=50
T='$T'
start_service() {
    printf 'start\\n' >> "\$T/main-events"
    for _proxy in nfqws2 z2k-rt-proxy tg-ws-proxy; do
        procd_open_instance "\$_proxy"
        procd_set_param command "\$T/main-daemons/\$_proxy"
        procd_set_param respawn 3600 5 5
        procd_close_instance
    done
    procd_open_instance z2k-warp
    procd_set_param command "\$T/legacy/z2k-warpd"
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
stop_service() {
    printf 'stop\\n' >> "\$T/main-events"
}
EOF_MAIN_INIT
chmod 0755 "$MAIN_INIT"
_main_init_created=1
"$MAIN_INIT" start
_main_service_started=1
_waited=0
while { [ ! -s "$MAIN_PID_DIR/nfqws2.pid" ] \
    || [ ! -s "$MAIN_PID_DIR/z2k-rt-proxy.pid" ] \
    || [ ! -s "$MAIN_PID_DIR/tg-ws-proxy.pid" ] \
    || [ ! -s "$T/legacy.pid" ]; } && [ "$_waited" -lt 15 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
for _proxy in nfqws2 z2k-rt-proxy tg-ws-proxy; do
    _pid="$(cat "$MAIN_PID_DIR/$_proxy.pid")"
    kill -0 "$_pid"
    echo "$_proxy=$_pid"
done > "$T/main-pids.before"
_legacy_pid="$(cat "$T/legacy.pid")"
kill -0 "$_legacy_pid"
grep -Fqx start "$T/main-events"

assert_main_pids_unchanged() {
    for _proxy in nfqws2 z2k-rt-proxy tg-ws-proxy; do
        _pid="$(cat "$MAIN_PID_DIR/$_proxy.pid")"
        kill -0 "$_pid" || {
            echo "процесс $_proxy остановлен при переключении WARP" >&2
            return 1
        }
        echo "$_proxy=$_pid"
    done > "$T/main-pids.current"
    cmp "$T/main-pids.before" "$T/main-pids.current"
    [ "$(grep -cx start "$T/main-events")" = 1 ]
    ! grep -Fqx stop "$T/main-events"
}
cat > "$T/controller" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$CONTROLLER_CALLS'
exec '$REAL_CONTROLLER' "\$@"
EOF
chmod 0755 "$T/controller"
CONTROLLER="$T/controller"
printf 'ENABLED=1\nGAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=h2\n' \
    > "$T/etc/config"
printf '{"qemu":"procd-test"}\n' > "$T/etc/state/warp/device.json"
cat > "$ENGINE" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> '$START_FILE'
exec /bin/sleep 300
EOF
chmod 0755 "$ENGINE"
# service_started пропускает фоновую свёрку только на время этого теста.
printf 'qemu-test\n' > "$T/tmp/warp/op"

export Z2K_ROOT="$ROOT"
export Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp"
export Z2K_LISTS_DIR="$T/lists" CONFIG_FILE="$T/etc/config"
export WARP_LISTS_DIR="$T/etc/user-lists/warp"
export WARP_GAMES_DIR="$T/etc/user-lists/warp/games"
export WARP_DEVICE="$T/etc/state/warp/device.json"
export WARP_CONTROLLER_BIN="$CONTROLLER" WARP_DOMAIN_RUNTIME_BIN="$ENGINE"
export WARP_DOMAIN_HELPER="$T/missing-warp-domain.sh"
export Z2K_WARP_NFT_FAMILY=inet Z2K_WARP_NFT_TABLE="$NFT_TABLE"
export WARP_FW4_FAMILY=inet WARP_FW4_TABLE=fw4 WARP_FW4_CHAIN=forward
export WARP_FW4_RULE_COMMENT='!z2k: WARP forwarded traffic'
export WARP_READY_WAIT=1
# shellcheck disable=SC1091
Z2K_WARP_SOURCE_ONLY=1 . "$ROOT/platform/openwrt/warp.sh"
_configured=1

if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    echo 'таблица QEMU procd-теста уже существует' >&2
    exit 1
fi
nft add table inet "$NFT_TABLE"
_table_created=1

if ubus -S call service list '{"name":"z2k-warp"}' 2>/dev/null \
    | grep -Fq '"main"'; then
    echo 'в QEMU уже зарегистрирована служба z2k-warp' >&2
    exit 1
fi

_service_started=1
"$INIT" start
_waited=0
while { [ ! -s "$PID_FILE" ] || [ ! -s "$START_FILE" ]; } && \
    [ "$_waited" -lt 15 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
if [ ! -s "$PID_FILE" ] || [ ! -s "$START_FILE" ]; then
    echo 'procd не запустил тестовый движок WARP' >&2
    exit 1
fi
_first_pid="$(cat "$PID_FILE")"
kill -0 "$_first_pid"
_waited=0
while kill -0 "$_legacy_pid" 2>/dev/null && [ "$_waited" -lt 10 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
if kill -0 "$_legacy_pid" 2>/dev/null; then
    echo 'старый вложенный z2k-warpd остался после миграции procd' >&2
    exit 1
fi
ubus -S call service list '{"name":"z2k"}' > "$T/registry.main"
grep -Fq '"nfqws2"' "$T/registry.main"
grep -Fq '"z2k-rt-proxy"' "$T/registry.main"
grep -Fq '"tg-ws-proxy"' "$T/registry.main"
if grep -Fq '"z2k-warp"' "$T/registry.main"; then
    echo 'старый WARP instance остался во владельце procd z2k' >&2
    exit 1
fi
ubus -S call service list '{"name":"z2k-warp"}' > "$T/registry.start"
grep -Fq '"main"' "$T/registry.start"
grep -Fq -- '--net-backend=external' "$START_FILE"

# Повторный start не должен создавать второй экземпляр.
"$INIT" start
sleep 1
[ "$(cat "$PID_FILE")" = "$_first_pid" ]
[ "$(wc -l < "$START_FILE" | tr -d ' ')" = 1 ]

# procd должен поднять зарегистрированный процесс после SIGKILL.
kill -9 "$_first_pid"
_waited=0
while { [ "$(wc -l < "$START_FILE" | tr -d ' ')" -lt 2 ] || \
    [ ! -s "$PID_FILE" ] || [ "$(cat "$PID_FILE")" = "$_first_pid" ]; } && \
    [ "$_waited" -lt 15 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
[ "$(wc -l < "$START_FILE" | tr -d ' ')" -ge 2 ] || {
    echo 'procd не восстановил WARP instance после SIGKILL' >&2
    exit 1
}
_recovered_pid="$(cat "$PID_FILE")"
kill -0 "$_recovered_pid"
[ "$_recovered_pid" != "$_first_pid" ]

# Reload службы должен запустить конечное ожидание подтверждённого ready.
rm -f "$T/tmp/warp/op"
: > "$CONTROLLER_CALLS"
"$INIT" reload
_waited=0
while ! grep -Fqx startup-reconcile "$CONTROLLER_CALLS" && \
    [ "$_waited" -lt 10 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
grep -Fqx startup-reconcile "$CONTROLLER_CALLS" || {
    echo 'reload службы не запустил ready reconcile WARP' >&2
    exit 1
}
kill -0 "$_recovered_pid"
[ "$(cat "$PID_FILE")" = "$_recovered_pid" ]

# Перезапуск сети сохраняет procd instance и PID Go-процесса.
/etc/init.d/network restart
_waited=0
while ! ip link show dev br-lan >/dev/null 2>&1 && [ "$_waited" -lt 15 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
ip link show dev br-lan >/dev/null 2>&1
kill -0 "$_recovered_pid"
[ "$(cat "$PID_FILE")" = "$_recovered_pid" ]
ubus -S call service list '{"name":"z2k-warp"}' > "$T/registry.network"
grep -Fq '"main"' "$T/registry.network"
assert_main_pids_unchanged

_enable_rc=0
warp_enable >/dev/null 2>&1 || _enable_rc=$?
[ "$_enable_rc" = 2 ] || {
    echo "enable с неготовым тестовым движком вернул неожиданный код $_enable_rc" >&2
    exit 1
}
assert_main_pids_unchanged
Z2K_WARP_DIAGNOSTICS=1 warp_disable > "$T/disable-timing.log" 2>&1
awk '/stage=pbr_cleanup / { pbr = NR } /stage=nft_cleanup / { nft = NR } /stage=procd_transition / { procd = NR } /stage=process_stop_wait / { wait = NR } END { exit !(pbr > 0 && pbr < nft && nft < procd && procd < wait) }' \
    "$T/disable-timing.log" || {
    echo 'выключение не записало PBR → nft → procd → ожидание процесса' >&2
    cat "$T/disable-timing.log" >&2
    exit 1
}
sed -n 's/.*stage=pbr_cleanup duration_ms=\([0-9][0-9]*\).*/QEMU_TIMING pbr_cleanup_ms=\1/p' \
    "$T/disable-timing.log" | tail -n 1
sed -n 's/.*stage=nft_cleanup duration_ms=\([0-9][0-9]*\).*/QEMU_TIMING nft_cleanup_ms=\1/p' \
    "$T/disable-timing.log" | tail -n 1
sed -n 's/.*stage=procd_transition duration_ms=\([0-9][0-9]*\).*/QEMU_TIMING procd_transition_ms=\1/p' \
    "$T/disable-timing.log" | tail -n 1
sed -n 's/.*stage=process_stop_wait duration_ms=\([0-9][0-9]*\).*/QEMU_TIMING process_stop_wait_ms=\1/p' \
    "$T/disable-timing.log" | tail -n 1
sed -n 's/.*stage=total duration_ms=\([0-9][0-9]*\).*/QEMU_TIMING disable_total_ms=\1/p' \
    "$T/disable-timing.log" | tail -n 1
assert_main_pids_unchanged
_enable_rc=0
warp_enable >/dev/null 2>&1 || _enable_rc=$?
[ "$_enable_rc" = 2 ] || {
    echo "повторный enable с неготовым тестовым движком вернул неожиданный код $_enable_rc" >&2
    exit 1
}
assert_main_pids_unchanged
_restart_rc=0
warp_restart >/dev/null 2>&1 || _restart_rc=$?
[ "$_restart_rc" = 2 ] || {
    echo "restart с неготовым тестовым движком вернул неожиданный код $_restart_rc" >&2
    exit 1
}
assert_main_pids_unchanged
warp_disable >/dev/null 2>&1
assert_main_pids_unchanged

"$INIT" stop
_waited=0
while kill -0 "$_recovered_pid" 2>/dev/null && [ "$_waited" -lt 10 ]; do
    sleep 1
    _waited=$((_waited + 1))
done
if kill -0 "$_recovered_pid" 2>/dev/null; then
    echo 'движок WARP остался активен после stop' >&2
    exit 1
fi
ubus -S call service list '{"name":"z2k-warp"}' > "$T/registry.stop"
if grep -Fq '"main"' "$T/registry.stop"; then
    echo 'procd сохранил активный main instance после stop' >&2
    exit 1
fi

printf 'SUITE[ow-warp-procd-service-openwrt-qemu]: pass\n'
