#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"

grep -qx '/usr/lib/z2k' \
    "$ROOT/platform/openwrt/owned-paths.txt" || {
    echo 'release не владеет каталогом OpenWrt-компонентов' >&2
    exit 1
}
if grep -qx '/usr/lib/z2k/platform/openwrt/warp-ready-event.sh' \
    "$ROOT/platform/openwrt/owned-paths.txt"; then
    echo 'ready-event ошибочно объявлен отдельно внутри владеемого каталога' >&2
    exit 1
fi
[ -f "$ROOT/platform/openwrt/warp-ready-event.sh" ] || {
    echo 'OpenWrt ready-event entrypoint отсутствует' >&2
    exit 1
}

if [ "$#" -ge 1 ] && [ "$1" = --inside ]; then
    T="$2"
    ip link add z2ktun0 type dummy
    ip link set z2ktun0 up
    nft add table inet fw4
    nft add chain inet fw4 forward "{ type filter hook forward priority filter; policy accept; }"
    nft add table inet z2k_warp_shell_test
    trap 'if [ -n "${WARP_PID:-}" ]; then kill -TERM "$WARP_PID" 2>/dev/null || true; fi; nft delete table inet fw4 2>/dev/null || true; nft delete table inet z2k_warp_shell_test 2>/dev/null || true; ip link del z2ktun0 2>/dev/null || true' EXIT HUP INT TERM

    mkdir -p "$T/etc/user-lists/warp" "$T/etc/state/warp" "$T/tmp/z2k/warp" \
        "$T/tmp/z2k/runtime" "$T/lists/warp/games" "$T/proc/101" "$T/mock-bin"
    printf 'ENABLED=1\nGAME_WARP_ENABLED=1\nZ2K_WARP_TRANSPORT=wg\n' > "$T/etc/config"
    printf '{"id":"test-device","addr":"172.16.9.9"}\n' > "$T/etc/state/warp/device.json"
    printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg","pid":101}\n' > "$T/tmp/z2k/warp/status.json"
    printf 'z2k-warpd\n' > "$T/proc/101/comm"
    printf '/usr/bin/z2k-warpd\000run\000' > "$T/proc/101/cmdline"
    : > "$T/etc/user-lists/warp/devices.txt"
    : > "$T/etc/user-lists/warp/.enabled"
    printf '1.1.1.1\n' > "$T/etc/user-lists/warp/smoke.txt"

    WARP_BIN="$T/z2k-warpd"
    cat > "$WARP_BIN" <<'EOF_ENGINE'
#!/bin/sh
exit 0
EOF_ENGINE
    chmod 0755 "$WARP_BIN"
    REAL_IP="$(command -v ip)"
    REAL_NFT="$(command -v nft)"
    # В WSL нет OpenWrt UCI; подаём пустые реальные по формату конфиги,
    # а ip/nft и маршрутизация остаются настоящими внутри network namespace.
    cat > "$T/mock-bin/uci" <<'EOF_UCI'
#!/bin/sh
case "$*" in
    '-d @ show network'|'-d @ show firewall') exit 0 ;;
    *) exit 1 ;;
esac
EOF_UCI
    cat > "$T/mock-bin/ip" <<EOF_IP
#!/bin/sh
printf 'ip:' >> "$T/commands.log"
printf ' %s' "\$@" >> "$T/commands.log"
printf '\n' >> "$T/commands.log"
exec "$REAL_IP" "\$@"
EOF_IP
    cat > "$T/mock-bin/nft" <<EOF_NFT
#!/bin/sh
printf 'nft:' >> "$T/commands.log"
printf ' %s' "\$@" >> "$T/commands.log"
printf '\n' >> "$T/commands.log"
if [ -e "$T/nft-fail-once" ] && [ "\$1" = -f ] && [ "\$2" = - ]; then
    rm -f "$T/nft-fail-once"
    exit 1
fi
exec "$REAL_NFT" "\$@"
EOF_NFT
    chmod 0755 "$T/mock-bin/ip" "$T/mock-bin/nft" "$T/mock-bin/uci"

    export Z2K_ROOT="$ROOT" Z2K_ADAPTER_DIR="$ROOT/platform/openwrt"
    export T
    export Z2K_ETC="$T/etc" Z2K_STATE="$T/etc/state" Z2K_TMP="$T/tmp/z2k"
    export Z2K_LISTS_DIR="$T/lists" Z2K_RUN="$T/tmp/z2k/runtime"
    export Z2K_PROC_ROOT="$T/proc" WARP_INIT="$T/warp-init" Z2K_WARP_INIT="$T/warp-init"
    export CONFIG_FILE="$T/etc/config" WARP_BIN WARP_DOMAIN_RUNTIME_BIN="$WARP_BIN"
    export WARP_DEVICE="$T/etc/state/warp/device.json"
    export WARP_STATUS="$T/tmp/z2k/warp/status.json"
    export WARP_LOG="$T/tmp/z2k/warp/warpd.log"
    export WARP_LOCK_DIR="$T/mutate.lock"
    export WARP_PBR_OWNER="$T/tmp/z2k/warp/pbr.owner"
    export WARP_PROBE_OWNER="$T/tmp/z2k/warp/probe-route.owner"
    export WARP_PROCD_INSTANCE_FILE="$T/tmp/z2k/warp/procd-instance"
    export WARP_PROCD_RECOVERY_FILE="$T/tmp/z2k/warp/procd-recovery"
    export WARP_DOMAIN_RULES="$T/tmp/z2k/warp/domains.v1"
    export WARP_DOMAIN_ERROR="$T/tmp/z2k/warp/domain-error"
    export WARP_LISTS_DIR="$T/etc/user-lists/warp"
    export WARP_GAMES_DIR="$T/lists/warp/games"
    export WARP_ENABLED_FILE="$T/etc/user-lists/warp/.enabled"
    export WARP_DEVICES_FILE="$T/etc/user-lists/warp/devices.txt"
    export Z2K_WARP_NFT_TABLE=z2k_warp_shell_test
    export Z2K_WARP_QUIET=""
    PATH="$T/mock-bin:$PATH"; export PATH

    cat > "$WARP_INIT" <<'EOF_WARP_INIT'
#!/bin/sh
. "$Z2K_ADAPTER_DIR/paths.sh"
. "$Z2K_ADAPTER_DIR/arch.sh"
. "$Z2K_ADAPTER_DIR/env.sh"
Z2K_WARP_SOURCE_ONLY=1
export Z2K_WARP_SOURCE_ONLY
. "$Z2K_ADAPTER_DIR/warp.sh"
procd_open_instance() { printf 'open: %s\n' "$1" >> "$T/procd.log"; }
procd_set_param() {
    printf 'param:' >> "$T/procd.log"
    for _value in "$@"; do printf ' %s' "$_value" >> "$T/procd.log"; done
    printf '\n' >> "$T/procd.log"
}
procd_close_instance() { printf 'close\n' >> "$T/procd.log"; }
case "$1" in
    start)
        _warp_controller procd-legacy-warp-remove || exit $?
        _warp_controller event rules || exit $?
        warp_start_instance
        ;;
    stop) _warp_controller event stop ;;
    *) exit 2 ;;
esac
EOF_WARP_INIT
    chmod 0755 "$WARP_INIT"

    Z2K_WARP_SOURCE_ONLY=1
    export Z2K_WARP_SOURCE_ONLY
    . "$ROOT/platform/openwrt/warp.sh"

    _z2k_ow_warp_lock 1
    [ -f "$WARP_LOCK_DIR/owner" ] || { echo 'Rust lock wrapper не записал владельца' >&2; exit 1; }
    if _z2k_ow_warp_lock 0; then
        echo 'Rust lock wrapper повторно выдал занятую блокировку' >&2
        exit 1
    fi
    _z2k_ow_warp_unlock
    [ ! -e "$WARP_LOCK_DIR" ] || { echo 'Rust lock wrapper не снял принадлежащую блокировку' >&2; exit 1; }

    : > "$T/procd.log"
    procd_open_instance() { printf 'open: %s\n' "$1" >> "$T/procd.log"; }
    procd_set_param() {
        printf 'param:' >> "$T/procd.log"
        for _value in "$@"; do printf ' %s' "$_value" >> "$T/procd.log"; done
        printf '\n' >> "$T/procd.log"
    }
    procd_close_instance() { printf 'close\n' >> "$T/procd.log"; }

    Z2K_WARP_DIAGNOSTICS=1 z2k_ow_warp 1
    grep -q '^open: main$' "$T/procd.log"
    grep -q '^param: command ' "$T/procd.log"
    grep -q ' --net-backend=external' "$T/procd.log"
    grep -q 'Z2K_WARP_TRANSPORT=wg' "$T/procd.log"
    grep -q 'Z2K_WARP_READY_SCRIPT=' "$T/procd.log"
    grep -q 'Z2K_WARP_PROTOCOL_VERSION=1' "$T/procd.log"
    grep -q 'WARP_BIN=' "$T/procd.log"
    grep -q 'Z2K_WARP_DIAGNOSTICS=1' "$T/procd.log"
    grep -q '^param: respawn 3600 5 5$' "$T/procd.log"
    ip -4 rule show | grep -q 'lookup 989'
    ip -4 route show table 989 | grep -q 'default dev z2ktun0'
    nft list table inet z2k_warp_shell_test >/dev/null

    : > "$T/commands.log"
    sh "$ROOT/platform/openwrt/warp-ready-event.sh" 101
    if grep -Eq '^ip: (.* )?(route (add|replace|del)|rule (add|del))([[:space:]]|$)' "$T/commands.log"; then
        echo 'повторное событие ready изменило исправную маршрутизацию' >&2
        exit 1
    fi
    if grep -q '^nft: -f -$' "$T/commands.log"; then
        echo 'повторное событие ready отправило лишнюю nft-транзакцию' >&2
        exit 1
    fi

    # Имитация procd respawn: прежний PID исчезает, новый PID публикует ready.
    rm -rf "$T/proc/101"
    mkdir -p "$T/proc/102"
    printf 'z2k-warpd\n' > "$T/proc/102/comm"
    printf '/usr/bin/z2k-warpd\000run\000' > "$T/proc/102/cmdline"
    printf '{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","transport":"wg","pid":102}\n' > "$T/tmp/z2k/warp/status.json"
    _warp_controller event stop
    if ip -4 rule show | grep -q 'lookup 989'; then
        echo 'подготовка восстановления оставила старый WARP ip rule' >&2
        exit 1
    fi
    : > "$T/commands.log"
    sh "$ROOT/platform/openwrt/warp-ready-event.sh" 101
    if [ -s "$T/commands.log" ]; then
        echo 'позднее событие убитого процесса вызвало сетевые операции' >&2
        cat "$T/commands.log" >&2
        exit 1
    fi
    sh "$ROOT/platform/openwrt/warp-ready-event.sh" 102
    ip -4 rule show | grep -q 'lookup 989'
    ip -4 route show table 989 | grep -q 'default dev z2ktun0'
    nft list table inet z2k_warp_shell_test >/dev/null

    mkdir -p "$T/proc/424242"
    printf 'z2k-warp-controller\n' > "$T/proc/424242/comm"
    printf '424242\n' > "$WARP_OP_FILE"
    : > "$T/commands.log"
    if sh "$ROOT/platform/openwrt/warp-ready-event.sh" 102; then
        echo 'ready-event не отложил восстановление во время lifecycle-операции' >&2
        exit 1
    fi
    ip -4 rule show | grep -q 'lookup 989'
    if grep -Eq '^ip: (.* )?(route (add|replace|del)|rule (add|del))([[:space:]]|$)' "$T/commands.log"; then
        echo 'ready-event мутировал PBR во время lifecycle-операции' >&2
        exit 1
    fi
    rm -rf "$T/proc/424242"
    rm -f "$WARP_OP_FILE"

    cp "$WARP_STATUS" "$T/status-ready.json"
    printf '{"ready":' > "$WARP_STATUS"
    : > "$T/commands.log"
    if sh "$ROOT/platform/openwrt/warp-ready-event.sh" 102; then
        echo 'ready-event принял повреждённый статус за готовность' >&2
        exit 1
    fi
    if [ -s "$T/commands.log" ]; then
        echo 'UNKNOWN readiness вызвал сетевые операции:' >&2
        cat "$T/commands.log" >&2
        exit 1
    fi
    ip -4 rule show | grep -q 'lookup 989'
    mv "$T/status-ready.json" "$WARP_STATUS"

    : > "$T/commands.log"
    z2k_ow_warp rules
    if grep -Eq '^ip: (.* )?(route (add|replace|del)|rule (add|del))([[:space:]]|$)' "$T/commands.log"; then
        echo 'повторная сверка исправного WARP изменила маршрутизацию' >&2
        exit 1
    fi
    if grep -q '^nft: -f -$' "$T/commands.log"; then
        echo 'повторная сверка исправного WARP отправила nft-транзакцию' >&2
        exit 1
    fi

    nft list table inet z2k_warp_shell_test > "$T/nft-before"
    printf '2.2.2.2\n' > "$T/etc/user-lists/warp/smoke.txt"
    : > "$T/nft-fail-once"
    if z2k_ow_warp rules; then
        echo 'отказ nft транзакции был ошибочно принят за успех' >&2
        exit 1
    fi
    if [ -e "$T/nft-fail-once" ]; then
        echo 'контроллер не дошёл до nft транзакции' >&2
        exit 1
    fi
    nft list set inet z2k_warp_shell_test z2k_warp_dst4 \
        > "$T/nft-after-fail"
    grep -q '1.1.1.1' "$T/nft-after-fail"
    if grep -q '2.2.2.2' "$T/nft-after-fail"; then
        echo 'ошибка nft транзакции применила неполный набор' >&2
        exit 1
    fi
    if ip -4 rule show | grep -q 'lookup 989'; then
        echo 'fail-open оставил WARP ip rule после сбоя nft' >&2
        exit 1
    fi
    if ip -4 route show table 989 | grep -q .; then
        echo 'fail-open оставил маршрут WARP после сбоя nft' >&2
        exit 1
    fi

    : > "$T/commands.log"
    z2k_ow_warp rules
    nft list table inet z2k_warp_shell_test >/dev/null
    nft list set inet z2k_warp_shell_test z2k_warp_dst4 \
        | grep -q '2.2.2.2'
    ip -4 rule show | grep -q 'lookup 989'
    ip -4 route show table 989 | grep -q 'default dev z2ktun0'

    _cycle=1
    while [ "$_cycle" -le 3 ]; do
        z2k_ow_warp 0
        if ip -4 rule show | grep -q 'lookup 989'; then
            echo 'повторный disable оставил WARP ip rule' >&2
            exit 1
        fi
        z2k_ow_warp 1
        ip -4 rule show | grep -q 'lookup 989'
        ip -4 route show table 989 | grep -q 'default dev z2ktun0'
        nft list table inet z2k_warp_shell_test >/dev/null
        _cycle=$((_cycle + 1))
    done

    cat > "$T/warpd-fixture.py" <<'EOF_PROCESS'
import ctypes
import time
ctypes.CDLL(None).prctl(15, b"z2k-warpd", 0, 0, 0)
time.sleep(300)
EOF_PROCESS
    python3 "$T/warpd-fixture.py" run &
    WARP_PID=$!
    _attempt=0
    while [ "$(cat "/proc/$WARP_PID/comm" 2>/dev/null || true)" != z2k-warpd ]; do
        _attempt=$((_attempt + 1))
        [ "$_attempt" -lt 50 ] || { echo 'тестовый процесс WARP не зарегистрировал comm' >&2; exit 1; }
        sleep 0.02
    done
    Z2K_PROC_ROOT=/proc; export Z2K_PROC_ROOT

    : > "$T/commands.log"
    WARP_READY_WAIT=1 z2k_ow_warp startup-reconcile
    if grep -Eq '^ip: (.* )?(route (add|replace|del)|rule (add|del))([[:space:]]|$)' "$T/commands.log"; then
        echo 'startup-reconcile изменил исправную маршрутизацию' >&2
        exit 1
    fi
    if grep -q '^nft: -f -$' "$T/commands.log"; then
        echo 'startup-reconcile повторно применил nft транзакцию' >&2
        exit 1
    fi

    "$ROOT/platform/openwrt/warp-proc.sh" stop
    if kill -0 "$WARP_PID" 2>/dev/null; then
        echo 'engine-refresh stop оставил процесс z2k-warpd' >&2
        exit 1
    fi
    wait "$WARP_PID" 2>/dev/null || true
    WARP_PID=
    if ip -4 rule show | grep -q 'lookup 989'; then
        echo 'engine-refresh stop оставил WARP ip rule' >&2
        exit 1
    fi
    Z2K_PROC_ROOT="$T/proc"; export Z2K_PROC_ROOT
    rm -f "$T/proc/102/comm" "$T/proc/102/cmdline"

    # start должен оставаться fail-open, если procd ещё не поднял новый процесс.
    WARP_PROC_WAIT=1 WARP_PROC_STOP_WAIT=1 \
        "$ROOT/platform/openwrt/warp-proc.sh" start
    if ip -4 rule show | grep -q 'lookup 989'; then
        echo 'engine-refresh start создал маршрут без готового процесса' >&2
        exit 1
    fi

    z2k_ow_warp 0
    if ip -4 rule show | grep -q 'lookup 989'; then
        echo 'stop оставил WARP ip rule' >&2
        exit 1
    fi
    if ip -4 route show table 989 | grep -q .; then
        echo 'stop оставил маршрут в таблице WARP' >&2
        exit 1
    fi

    printf 'SUITE[ow-warp-controller-shell-entry-real]: pass=1 fail=0\n'
    exit 0
fi

for tool in cargo unshare ip nft python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "требуется реальный инструмент $tool" >&2; exit 1; }
done
T="$(mktemp -d "/tmp/z2k-warp-controller-shell.XXXXXX")"
_cleanup() {
    _rc=$?
    trap - EXIT HUP INT TERM
    if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ] && [ "$(id -u)" -ne 0 ]; then
        sudo -n rm -rf "$T" || _rc=$?
    else
        rm -rf "$T" || _rc=$?
    fi
    exit "$_rc"
}
trap _cleanup EXIT HUP INT TERM
CARGO_TARGET_DIR="$T/cargo-target" cargo build --offline --locked \
    --manifest-path "$CRATE/Cargo.toml" --bin z2k-warp-controller
export CARGO_TARGET_DIR="$T/cargo-target"
export WARP_CONTROLLER_BIN="$CARGO_TARGET_DIR/debug/z2k-warp-controller"
if [ "${Z2K_WARP_ROOT_NETNS:-0}" = 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        unshare -n sh "$0" --inside "$T"
    else
        sudo -n env WARP_CONTROLLER_BIN="$WARP_CONTROLLER_BIN" \
            unshare -n sh "$0" --inside "$T"
    fi
else
    unshare -Urn sh "$0" --inside "$T"
fi
