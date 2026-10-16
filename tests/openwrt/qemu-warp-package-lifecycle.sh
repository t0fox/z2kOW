#!/bin/sh
# Полный install/update/WARP-remove/uninstall acceptance для OpenWrt QEMU.
set -eu

BASE="${Z2K_WARP_ACCEPTANCE_BASE:-http://10.0.2.2:18084}"
T=/tmp/z2k-warp-package-acceptance
CONTROLLER=/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warp-controller
ENGINE=/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd
DEVICE=/etc/z2k/state/warp/device.json
ACCOUNT=/etc/z2k/state/warp/account.json
LICENSE=/etc/z2k/state/warp/license
USER_LIST=/etc/z2k/user-lists/warp/custom.txt
WARP_LOCK_DIR=/tmp/z2k/warp/mutate.lock
export WARP_LOCK_DIR
_LIST_UPDATER_PID=
_UNINSTALL_PID=

cleanup_background_work() {
    if [ -n "$_UNINSTALL_PID" ]; then
        kill "$_UNINSTALL_PID" 2>/dev/null || true
        wait "$_UNINSTALL_PID" 2>/dev/null || true
    fi
    if [ -n "$_LIST_UPDATER_PID" ]; then
        kill "$_LIST_UPDATER_PID" 2>/dev/null || true
        wait "$_LIST_UPDATER_PID" 2>/dev/null || true
    fi
}
trap cleanup_background_work EXIT HUP INT TERM

mkdir -p "$T"
wget -q "$BASE/acceptance.pub" -O "$T/acceptance.pub"
wget -q "$BASE/current-controller.sha256" -O "$T/controller.sha256"
wget -q "$BASE/install.sh" -O "$T/install.sh"

export Z2KOW_TRUST_KEY="$T/acceptance.pub"
if [ "${SKIP_INITIAL_INSTALL:-0}" = 1 ]; then
    test -x /usr/bin/z2kow
else
    export Z2KOW_MANIFEST_URL="$BASE/UPDATES.json"
    sh "$T/install.sh"
    test -x /usr/bin/z2kow
    test -x "$CONTROLLER"
    test -x /usr/lib/z2k/platform/openwrt/warp-ready-event.sh
    grep -qx GAME_WARP_ENABLED=0 /etc/z2k/config
fi

# Задаём тестовую пользовательскую настройку до обновления и проверяем её сохранение.
if ! grep -qx Z2K_WARP_TRANSPORT=h2 /etc/z2k/config; then
    sed -i '/^Z2K_WARP_TRANSPORT=/d' /etc/z2k/config
    printf 'Z2K_WARP_TRANSPORT=h2\n' >> /etc/z2k/config
fi
mkdir -p "${USER_LIST%/*}"
mkdir -p "${DEVICE%/*}"
if [ ! -s "$DEVICE" ]; then
    (umask 077; printf '{"acceptance_sentinel":"warp-device"}\n' > "$DEVICE")
fi
test -s "$DEVICE"
if [ ! -s "$ACCOUNT" ]; then
    (umask 077; printf '{"acceptance_sentinel":"warp-account"}\n' > "$ACCOUNT")
fi
test -s "$ACCOUNT"
printf 'license sentinel\n' > "$LICENSE"
printf '192.0.2.77\n' > "$USER_LIST"
sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" "$USER_LIST" > "$T/state.before"

export Z2KOW_MANIFEST_URL="$BASE/v2/UPDATES.json"
sh "$T/install.sh"
test -x "$CONTROLLER"
sha256sum "$CONTROLLER" | grep -F "$(cat "$T/controller.sha256")" >/dev/null
grep -qx GAME_WARP_ENABLED=0 /etc/z2k/config
grep -qx Z2K_WARP_TRANSPORT=h2 /etc/z2k/config
sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" "$USER_LIST" > "$T/state.after-first-update"
cmp "$T/state.before" "$T/state.after-first-update"
test ! -e /usr/lib/z2k/WARP_ACCEPTANCE_V2

# Реальный updater держит тот же Rust lock, пока release меняет payload.
Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" \
    "$CONTROLLER" lock-acquire "$$" 30 || {
    echo 'Не удалось получить исходный WARP lock' >&2
    exit 1
}
Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" \
    "$CONTROLLER" lock-release "$$" || {
    echo 'Не удалось освободить исходный WARP lock' >&2
    exit 1
}
[ ! -e "$WARP_LOCK_DIR" ] || {
    echo 'Перед тестом осталась блокировка WARP' >&2
    exit 1
}
mkdir -p "$T/list-root"
cp /usr/lib/z2k/z2k-warp-list-filter.awk "$T/list-root/"
Z2K_WARP_BASE_URL="$BASE/games" \
Z2K_WARP_IPSET_SCRIPT=/usr/lib/z2k/platform/openwrt/warp.sh \
WARP_LOCK_DIR="$WARP_LOCK_DIR" \
ZAPRET2_DIR="$T/list-root" \
Z2K_LISTS_DIR="$T/list-root/lists" \
    sh /usr/lib/z2k/z2k-update-lists.sh warp-games > "$T/list-update.log" 2>&1 &
_LIST_UPDATER_PID=$!
_waited=0
while [ ! -s "$WARP_LOCK_DIR/pid" ] && [ "$_waited" -lt 30 ]; do
    kill -0 "$_LIST_UPDATER_PID" 2>/dev/null || break
    sleep 1
    _waited=$((_waited + 1))
done
[ -s "$WARP_LOCK_DIR/pid" ] || {
    echo 'Updater не взял общий lock WARP' >&2
    cat "$T/list-update.log" >&2
    exit 1
}
_lock_owner="$(cat "$WARP_LOCK_DIR/pid")"
[ "$_lock_owner" != "$$" ] && kill -0 "$_lock_owner" 2>/dev/null || {
    echo 'Updater не удерживает отдельный lease WARP' >&2
    exit 1
}
if Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$CONTROLLER" lock-acquire "$$" 0 >/dev/null 2>&1; then
    Z2K_WARP_LOCK_DIR="$WARP_LOCK_DIR" "$CONTROLLER" lock-release "$$" >/dev/null 2>&1 || true
    echo 'Второй процесс получил занятый lock WARP' >&2
    exit 1
fi

_update_started="$(date +%s)"
export Z2KOW_MANIFEST_URL="$BASE/v3/UPDATES.json"
sh "$T/install.sh"
_update_finished="$(date +%s)"
wait "$_LIST_UPDATER_PID"
_LIST_UPDATER_PID=
[ "$((_update_finished - _update_started))" -ge 5 ] || {
    echo 'Установка не дождалась завершения updater под общим lock' >&2
    exit 1
}
test -s "$T/list-root/lists/warp/games/LockProbe.txt"
grep -qx '8.8.8.8' "$T/list-root/lists/warp/games/LockProbe.txt"
test -s /usr/lib/z2k/WARP_ACCEPTANCE_V2
test -x "$CONTROLLER"
sha256sum "$CONTROLLER" | grep -F "$(cat "$T/controller.sha256")" >/dev/null
grep -qx GAME_WARP_ENABLED=0 /etc/z2k/config
grep -qx Z2K_WARP_TRANSPORT=h2 /etc/z2k/config
sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" "$USER_LIST" > "$T/state.after-update"
cmp "$T/state.after-first-update" "$T/state.after-update"
! pidof z2k-warpd >/dev/null 2>&1
! ip -4 rule show | grep -Eq '(^499:|^500:|lookup 989|fwmark 0x80000000)'
[ -z "$(ip -4 route show table 989)" ]
! nft list ruleset | grep -F 'z2k_warp'

sh /usr/lib/z2k/platform/openwrt/warp.sh remove
[ -x "$ENGINE" ]
[ -x "$CONTROLLER" ]
grep -qx GAME_WARP_ENABLED=0 /etc/z2k/config
! pidof z2k-warpd >/dev/null 2>&1
! ip -4 rule show | grep -Eq '(^499:|^500:|lookup 989|fwmark 0x80000000)'
[ -z "$(ip -4 route show table 989)" ]
! nft list ruleset | grep -F 'z2k_warp'
sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" "$USER_LIST" > "$T/state.after-warp-remove"
cmp "$T/state.before" "$T/state.after-warp-remove"

sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" > "$T/state.before-app-uninstall"
mkdir -p "$T/list-root-uninstall"
cp /usr/lib/z2k/z2k-warp-list-filter.awk "$T/list-root-uninstall/"
Z2K_FETCH_STALL_SECONDS=30 \
Z2K_WARP_BASE_URL="$BASE/games-uninstall" \
Z2K_WARP_IPSET_SCRIPT=/usr/lib/z2k/platform/openwrt/warp.sh \
WARP_LOCK_DIR="$WARP_LOCK_DIR" \
ZAPRET2_DIR="$T/list-root-uninstall" \
Z2K_LISTS_DIR="$T/list-root-uninstall/lists" \
    sh /usr/lib/z2k/z2k-update-lists.sh warp-games \
    > "$T/list-update-uninstall.log" 2>&1 &
_LIST_UPDATER_PID=$!
_waited=0
while [ ! -s "$WARP_LOCK_DIR/pid" ] && [ "$_waited" -lt 30 ]; do
    kill -0 "$_LIST_UPDATER_PID" 2>/dev/null || break
    sleep 1
    _waited=$((_waited + 1))
done
[ -s "$WARP_LOCK_DIR/pid" ] || {
    echo 'Updater не взял общий lock перед uninstall' >&2
    cat "$T/list-update-uninstall.log" >&2
    exit 1
}
_lock_owner="$(cat "$WARP_LOCK_DIR/pid")"
[ "$_lock_owner" != "$$" ] && kill -0 "$_lock_owner" 2>/dev/null || {
    echo 'Updater не удерживает отдельный lease перед uninstall' >&2
    exit 1
}
Z2K_JOB_ID=warpacceptance Z2K_UNINSTALL_CONFIRMED=1 \
    sh /usr/lib/z2k/platform/openwrt/uninstall.sh \
    > "$T/uninstall.log" 2>&1 &
_UNINSTALL_PID=$!
_waited=0
while [ "$_waited" -lt 45 ]; do
    grep -Fq 'mutation lock busy' "$T/uninstall.log" && break
    _uninstall_state="$(awk '{print $3}' "/proc/$_UNINSTALL_PID/stat" 2>/dev/null || true)"
    case "$_uninstall_state" in ''|Z) break ;; esac
    [ -s "$WARP_LOCK_DIR/pid" ] || break
    [ "$(cat "$WARP_LOCK_DIR/pid")" = "$_lock_owner" ] || break
    sleep 1
    _waited=$((_waited + 1))
done
_retry_uninstall=0
if grep -Fq 'mutation lock busy' "$T/uninstall.log"; then
    [ -s "$WARP_LOCK_DIR/pid" ] \
        && [ "$(cat "$WARP_LOCK_DIR/pid")" = "$_lock_owner" ] \
        && kill -0 "$_lock_owner" 2>/dev/null || {
        echo 'Отказ uninstall не совпал с активным updater lease' >&2
        cat "$T/uninstall.log" >&2
        exit 1
    }
    if wait "$_UNINSTALL_PID"; then
        echo 'Uninstall завершился успешно с занятым WARP lock' >&2
        exit 1
    fi
    _UNINSTALL_PID=
    _retry_uninstall=1
    [ -d /usr/lib/z2k ] && [ -x /usr/bin/z2kow ] || {
        echo 'Отказ uninstall удалил часть payload' >&2
        exit 1
    }
    sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" \
        > "$T/state.after-busy-uninstall"
    cmp "$T/state.before-app-uninstall" "$T/state.after-busy-uninstall"
else
    if ! wait "$_UNINSTALL_PID"; then
        cat "$T/uninstall.log" >&2
        exit 1
    fi
    _UNINSTALL_PID=
    if [ -s "$WARP_LOCK_DIR/pid" ] \
        && [ "$(cat "$WARP_LOCK_DIR/pid")" = "$_lock_owner" ]; then
        echo 'Uninstall завершился до освобождения lease updater' >&2
        exit 1
    fi
fi
if ! wait "$_LIST_UPDATER_PID"; then
    cat "$T/list-update-uninstall.log" >&2
    exit 1
fi
_LIST_UPDATER_PID=
test -s "$T/list-root-uninstall/lists/warp/games/LockProbe.txt"
grep -qx '8.8.8.8' \
    "$T/list-root-uninstall/lists/warp/games/LockProbe.txt"
if [ "$_retry_uninstall" = 1 ]; then
    if ! Z2K_JOB_ID=warpacceptance_retry Z2K_UNINSTALL_CONFIRMED=1 \
        sh /usr/lib/z2k/platform/openwrt/uninstall.sh \
        > "$T/uninstall-retry.log" 2>&1; then
        cat "$T/uninstall-retry.log" >&2
        exit 1
    fi
fi
for path in /usr/lib/z2k /usr/bin/z2kow /usr/sbin/install_release \
    /etc/init.d/z2k /etc/init.d/z2k-warp /etc/init.d/z2k-webpanel; do
    [ ! -e "$path" ] && [ ! -L "$path" ]
done
! pidof z2k-warpd >/dev/null 2>&1
! ip -4 rule show | grep -Eq '(^499:|^500:|lookup 989|fwmark 0x80000000)'
[ -z "$(ip -4 route show table 989)" ]
! nft list ruleset | grep -F 'z2k_warp'
sha256sum "$DEVICE" "$ACCOUNT" "$LICENSE" > "$T/state.after-app-uninstall"
cmp "$T/state.before-app-uninstall" "$T/state.after-app-uninstall"
printf 'SUITE[ow-warp-package-lifecycle-qemu]: pass\n'
