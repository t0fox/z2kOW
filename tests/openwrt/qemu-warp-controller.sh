#!/bin/sh
# Реальные nftables и iproute2 внутри OpenWrt QEMU; не использовать host mocks.
set -eu

BIN=/tmp/z2k-warp-controller
TABLE=inet
WARP_TABLE=z2k_warp_qemu
DNS_TABLE=z2k_warp_dns_qemu
FW4_TABLE=z2k_warp_fw4_qemu
T=/tmp/z2k-warp-qemu-domains
NFT_BIN="$(command -v nft)"
_lan_device_changed=0

cleanup() {
    chmod 755 "$NFT_BIN" >/dev/null 2>&1 || true
    uci -q revert firewall.z2k_warp_test_zone >/dev/null 2>&1 || true
    uci -q revert network.z2k_warp_test_lan >/dev/null 2>&1 || true
    uci -q revert network.z2k_warp_test_server >/dev/null 2>&1 || true
    uci -q revert network.z2k_warp_test_client >/dev/null 2>&1 || true
    uci -q revert network.wgfb0 >/dev/null 2>&1 || true
    uci -q revert network.z2k_warp_test_invalid >/dev/null 2>&1 || true
    [ "$_lan_device_changed" = 0 ] || \
        uci -q revert network.lan.device >/dev/null 2>&1 || true
    "$BIN" nft-domain-remove "$TABLE" "$DNS_TABLE" "$TABLE" \
        "$WARP_TABLE" z2k_domain 1 >/dev/null 2>&1 || true
    nft delete table "$TABLE" "$FW4_TABLE" >/dev/null 2>&1 || true
    nft delete table "$TABLE" "$WARP_TABLE" >/dev/null 2>&1 || true
    rm -rf "$T"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$T/users" "$T/games"
_mark_config="$T/warp-config"
printf 'Z2K_WARP_WDTT=0\n' > "$_mark_config"
mark_apply() {
    _mark_users="$1" _mark_games="$2" _mark_config_path="$3"
    _mark_lan="$4" _mark_servers="$5" _mark_clients="$6"
    "$BIN" nft-mark-apply "$TABLE" "$WARP_TABLE" z2k_mark \
        z2k_dst z2k_src z2k_domain \
        "$_mark_users" "$_mark_games" "$_mark_users/.enabled" \
        "$_mark_users/devices.txt" "$_mark_config_path" \
        "$_mark_lan" "$_mark_servers" "$_mark_clients"
}
mark_verify() {
    _mark_users="$1" _mark_games="$2" _mark_config_path="$3"
    _mark_lan="$4" _mark_servers="$5" _mark_clients="$6"
    "$BIN" nft-mark-verify "$TABLE" "$WARP_TABLE" z2k_mark \
        z2k_dst z2k_src z2k_domain \
        "$_mark_users" "$_mark_games" "$_mark_users/.enabled" \
        "$_mark_users/devices.txt" "$_mark_config_path" \
        "$_mark_lan" "$_mark_servers" "$_mark_clients"
}

# Shell lifecycle calls hand ownership to Rust; the PID lease survives the CLI.
Z2K_WARP_LOCK_DIR="$T/shell-owner.lock" "$BIN" lock-acquire "$$" 0
[ "$(cat "$T/shell-owner.lock/pid")" = "$$" ]
if Z2K_WARP_LOCK_DIR="$T/shell-owner.lock" "$BIN" lock-release 4294967294; then
    echo 'Rust снял lock, принадлежащий другому процессу' >&2
    exit 1
fi
[ -d "$T/shell-owner.lock" ]
Z2K_WARP_LOCK_DIR="$T/shell-owner.lock" "$BIN" lock-release "$$"
[ ! -e "$T/shell-owner.lock" ]

# SIGKILL оставляет pid/start-token, который следующий acquire снимает точно.
sleep 30 &
_lock_worker=$!
Z2K_WARP_LOCK_DIR="$T/killed-owner.lock" "$BIN" lock-acquire "$_lock_worker" 0
kill -9 "$_lock_worker"
wait "$_lock_worker" 2>/dev/null || true
Z2K_WARP_LOCK_DIR="$T/killed-owner.lock" "$BIN" lock-acquire "$$" 0
Z2K_WARP_LOCK_DIR="$T/killed-owner.lock" "$BIN" lock-release "$$"
[ ! -e "$T/killed-owner.lock" ]

# Health state is observed from real OpenWrt files, /proc and iproute2.
_health="$T/health"
mkdir -p "$_health"
[ "$("$BIN" service-plan enable 0 1 1)" = rebuild ]
[ "$("$BIN" service-plan enable 1 1 1)" = reload ]
[ "$("$BIN" service-plan enable 1 1 0)" = rebuild ]
[ "$("$BIN" service-plan disable 1 1 1)" = rebuild ]
[ "$("$BIN" service-plan disable 1 1 0)" = reload ]
[ "$("$BIN" service-plan disable 1 0 1)" = none ]
[ "$("$BIN" service-plan restart 1 1 0)" = rebuild ]
[ "$("$BIN" service-plan restart 0 1 1)" = none ]
_config="$_health/config"
_engine="$_health/z2k-warpd"
_device="$_health/device.json"
_status="$_health/status.json"
printf 'ENABLED=0\nGAME_WARP_ENABLED=1\n' > "$_config"
[ "$("$BIN" health-plan "$_config" "$_health/missing" "$_device" "$_status" /proc)" = disabled ]
printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$_config"
printf 'registered\n' > "$_device"
[ "$("$BIN" health-plan "$_config" "$_health/missing" "$_device" "$_status" /proc)" = binary-missing ]
printf '#!/bin/sh\nexit 0\n' > "$_engine"
chmod 0755 "$_engine"
rm -f "$_device"
[ "$("$BIN" health-plan "$_config" "$_engine" "$_device" "$_status" /proc)" = device-missing ]
printf 'registered\n' > "$_device"
[ "$("$BIN" health-plan "$_config" "$_engine" "$_device" "$_status" /proc)" = process-absent ]
printf '{"ready":true,"iface":"z2ktun0"}\n' > "$_status"
[ "$("$BIN" ready-observe-since "$_status" /proc "$(date +%s)")" = not-ready ]
if "$BIN" ready-observe-since "$_status" /proc 0; then
    echo 'нулевой epoch подтвердил готовность в OpenWrt QEMU' >&2
    exit 1
fi
rm -f "$_config"
mkdir "$_config"
[ "$("$BIN" health-plan "$_config" "$_engine" "$_device" "$_status" /proc)" = defer ]
rmdir "$_config"
printf 'ENABLED=1\nGAME_WARP_ENABLED=1\n' > "$_config"
[ "$("$BIN" health-plan "$_config" "$_engine" "$_device" "$_status" "$_health/missing-proc")" = defer ]
[ "$("$BIN" boot-plan "$_config" "$_engine" "$_device")" = wanted ]
_unreadable_config="$_health/unreadable-config"
mkdir "$_unreadable_config"
[ "$("$BIN" boot-plan "$_unreadable_config" "$_engine" "$_device")" = defer ]
[ "$("$BIN" boot-plan "$_config" "$_health/missing-engine" "$_device")" = unwanted ]

_flag_config="$_health/flag-config"
printf 'GAME_WARP_ENABLED=1\nOTHER_FEATURE=keep\n' > "$_flag_config"
"$BIN" warp-flag-set "$_flag_config" 0
grep -q '^GAME_WARP_ENABLED=0$' "$_flag_config"
grep -q '^OTHER_FEATURE=keep$' "$_flag_config"
mkdir "$_flag_config.z2k-flaglock"
if "$BIN" warp-flag-set "$_flag_config" 1; then
    echo 'WARP config обновлён при занятом общем lock' >&2
    exit 1
fi
grep -q '^GAME_WARP_ENABLED=0$' "$_flag_config"
rmdir "$_flag_config.z2k-flaglock"

_domain_error="$_health/domain-setup-error"
"$BIN" domains-error "$_domain_error" nft-observer-unavailable
[ "$(cat "$_domain_error")" = nft-observer-unavailable ]
[ "$(ls -ld "$_domain_error" | cut -c1-10)" = '-rw-------' ]
_domain_error_inode="$(ls -i "$_domain_error" | awk 'NR == 1 { print $1 }')"
"$BIN" domains-error "$_domain_error" nft-observer-unavailable
_domain_error_inode_after="$(ls -i "$_domain_error" | awk 'NR == 1 { print $1 }')"
[ "$_domain_error_inode_after" = "$_domain_error_inode" ]
"$BIN" domains-error "$_domain_error" ''
[ ! -e "$_domain_error" ]

_route_error="$_health/route-error"
"$BIN" route-error-set "$_route_error" pbr-apply-failed
grep -Eq '^pbr-apply-failed [0-9]+$' "$_route_error"
[ "$(ls -ld "$_route_error" | cut -c1-10)" = '-rw-------' ]
_route_error_inode="$(ls -i "$_route_error" | awk 'NR == 1 { print $1 }')"
"$BIN" route-error-set "$_route_error" tun-apply-failed
[ "$(ls -i "$_route_error" | awk 'NR == 1 { print $1 }')" = "$_route_error_inode" ]
grep -Eq '^pbr-apply-failed [0-9]+$' "$_route_error"
printf stale > "$_route_error.new.stale"
"$BIN" route-error-clear "$_route_error"
[ ! -e "$_route_error" ] && [ ! -e "$_route_error.new.stale" ]

_operation="$_health/op"
[ "$("$BIN" op-current "$_operation" 101)" = current ]
"$BIN" op-begin "$_operation" 101
[ "$(cat "$_operation")" = 101 ]
[ "$("$BIN" op-current "$_operation" 101)" = current ]
[ "$("$BIN" op-current "$_operation" 202)" = superseded ]
"$BIN" op-clear "$_operation" 202
[ "$(cat "$_operation")" = 101 ]
"$BIN" op-clear "$_operation" 101
[ ! -e "$_operation" ]

_recovery="$_health/procd-recovery-attempt"
[ "$("$BIN" procd-recovery-claim "$_recovery" 12345)" = claimed ]
[ "$(cat "$_recovery")" = 'attempted 12345' ]
_recovery_inode="$(ls -i "$_recovery" | awk 'NR == 1 { print $1 }')"
[ "$("$BIN" procd-recovery-claim "$_recovery" 67890)" = exists ]
[ "$(ls -i "$_recovery" | awk 'NR == 1 { print $1 }')" = "$_recovery_inode" ]
[ "$(cat "$_recovery")" = 'attempted 12345' ]
"$BIN" procd-recovery-clear "$_recovery"
[ ! -e "$_recovery" ]
[ ! -e "$_health/.procd-recovery-attempt.mutate.lock" ]

mkdir -p "$T/scope-users" "$T/scope-games"
scope() {
    "$BIN" policy-scope "$T/scope-users" "$T/scope-games" \
        "$T/scope-users/.enabled" "$T/scope-users/devices.txt"
}
[ "$(scope)" = all ]
printf '# offline\n' > "$T/scope-users/devices.txt"
[ "$(scope)" = all ]
printf 'aa:bb:cc:dd:ee:ff\n' > "$T/scope-users/devices.txt"
[ "$(scope)" = full ]
touch "$T/scope-users/empty.txt"
[ "$(scope)" = devices ]
rm "$T/scope-users/devices.txt" "$T/scope-users/empty.txt"
printf 'missing-game\n' > "$T/scope-users/.enabled"
[ "$(scope)" = lists ]
rm "$T/scope-users/.enabled"
mkdir "$T/scope-users/devices.txt"
if scope >/dev/null 2>&1; then
    echo 'ошибка чтения списка устройств WARP принята за область all' >&2
    exit 1
fi
rmdir "$T/scope-users/devices.txt"

# В госте используется настоящий JSON-вывод iproute2 и таблица соседей ядра.
_neighbor="$(ip -4 neigh show | awk '/lladdr/ { print $1, $5; exit }')"
set -- $_neighbor
[ "$#" -eq 2 ] || { echo 'QEMU не предоставил IPv4 neighbor для проверки' >&2; exit 1; }
_neighbor_ip="$1"
_neighbor_mac="$2"
printf '%s\n' "$2" > "$T/selected-devices.txt"
"$BIN" device-ips "$T/selected-devices.txt" "$T/no-dhcp-leases" > "$T/device-ips"
grep -qx "$1" "$T/device-ips"

# A live netifd device wins over a stale configured device name.
[ -z "$(uci changes)" ] || {
    echo 'QEMU UCI уже содержит staged changes; тест не меняет network.lan' >&2
    exit 1
}
_lan_device="$(uci -q get network.lan.device)"
_runtime_lan_device="$(ubus call network.interface.lan status | jsonfilter -e '@.device')"
[ -n "$_lan_device" ] && [ -n "$_runtime_lan_device" ]
_lan_device_changed=1
uci set network.lan.device=z2k-warp-stale-device
"$BIN" interfaces lan > "$T/lan-runtime"
grep -qx "$_runtime_lan_device" "$T/lan-runtime"
if grep -qx z2k-warp-stale-device "$T/lan-runtime"; then
    echo 'Rust использовал stale UCI device вместо runtime netifd device' >&2
    exit 1
fi
uci -q revert network.lan.device
_lan_device_changed=0
[ "$(uci -q get network.lan.device)" = "$_lan_device" ]

uci -q revert firewall.z2k_warp_test_zone >/dev/null 2>&1 || true
uci -q revert network.z2k_warp_test_lan >/dev/null 2>&1 || true
uci -q revert network.z2k_warp_test_server >/dev/null 2>&1 || true
uci -q revert network.z2k_warp_test_client >/dev/null 2>&1 || true
uci -q revert network.wgfb0 >/dev/null 2>&1 || true
uci -q revert network.z2k_warp_test_invalid >/dev/null 2>&1 || true
uci set firewall.z2k_warp_test_zone=zone
uci set firewall.z2k_warp_test_zone.name=lan
uci add_list firewall.z2k_warp_test_zone.network=z2k_warp_test_lan
uci set network.z2k_warp_test_lan=interface
uci set network.z2k_warp_test_lan.device=z2kfake0
"$BIN" interfaces lan > "$T/lan-interfaces"
grep -qx z2kfake0 "$T/lan-interfaces"
uci set network.z2k_warp_test_server=interface
uci set network.z2k_warp_test_server.proto=wireguard
uci set network.z2k_warp_test_server.listen_port=51820
uci set network.z2k_warp_test_server.device=z2kserver0
"$BIN" interfaces wireguard-servers > "$T/wg-servers"
grep -qx z2kserver0 "$T/wg-servers"
uci set network.z2k_warp_test_client=interface
uci set network.z2k_warp_test_client.proto=wireguard
uci set network.z2k_warp_test_client.device=z2kclient0
uci set network.wgfb0=interface
uci set network.wgfb0.proto=wireguard
uci set network.z2k_warp_test_invalid=interface
uci set network.z2k_warp_test_invalid.proto=wireguard
uci set network.z2k_warp_test_invalid.listen_port=invalid
uci set network.z2k_warp_test_invalid.device=z2kinvalid0
"$BIN" interfaces wireguard-clients > "$T/wg-clients"
grep -qx z2kclient0 "$T/wg-clients"
grep -qx wgfb0 "$T/wg-clients"
if grep -qx z2kinvalid0 "$T/wg-clients"; then
    echo 'невалидный listen_port ошибочно выбран как WG client' >&2
    exit 1
fi

nft add table "$TABLE" "$FW4_TABLE"
nft add chain "$TABLE" "$FW4_TABLE" forward \
    '{ type filter hook forward priority filter; policy accept; }'
"$BIN" nft-fw4-forward-apply "$TABLE" "$FW4_TABLE" forward \
    z2ktun0 0x80000000 0x80000000 '!z2k: WARP forwarded traffic'
_fw4_ready=$("$BIN" nft-fw4-forward-verify "$TABLE" "$FW4_TABLE" \
    forward z2ktun0 0x80000000 0x80000000 '!z2k: WARP forwarded traffic')
[ "$_fw4_ready" = ready=1 ]
nft -a list chain "$TABLE" "$FW4_TABLE" forward > "$T/fw4.before"
nft add chain "$TABLE" "$FW4_TABLE" conflict
nft add rule "$TABLE" "$FW4_TABLE" conflict oifname eth0 accept \
    comment '"!z2k: WARP forwarded traffic"'
nft -a list chain "$TABLE" "$FW4_TABLE" conflict > "$T/fw4.conflict.before"
if "$BIN" nft-fw4-forward-apply "$TABLE" "$FW4_TABLE" conflict \
    z2ktun0 0x80000000 0x80000000 '!z2k: WARP forwarded traffic'; then
    echo 'QEMU принял чужое fw4 правило за правило WARP' >&2
    exit 1
fi
nft -a list chain "$TABLE" "$FW4_TABLE" conflict > "$T/fw4.conflict.after"
cmp "$T/fw4.conflict.before" "$T/fw4.conflict.after"
"$BIN" nft-fw4-forward-apply "$TABLE" "$FW4_TABLE" forward \
    z2ktun0 0x80000000 0x80000000 '!z2k: WARP forwarded traffic'
nft -a list chain "$TABLE" "$FW4_TABLE" forward > "$T/fw4.after"
cmp "$T/fw4.before" "$T/fw4.after"
printf '%s\n' \
    "add rule $TABLE $FW4_TABLE forward meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun12\" accept comment \"!z2k: WARP forwarded traffic\"" \
    "add rule $TABLE $FW4_TABLE forward meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun*\" accept comment \"!z2k: WARP forwarded traffic\"" \
    | nft -f -
"$BIN" nft-fw4-forward-remove "$TABLE" "$FW4_TABLE" forward \
    '!z2k: WARP forwarded traffic'
nft list chain "$TABLE" "$FW4_TABLE" forward > "$T/fw4.after-remove"
grep -F 'oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"' \
    "$T/fw4.after-remove"
if grep -E 'oifname "z2ktun(0|12)"' "$T/fw4.after-remove"; then
    echo 'QEMU fw4 cleanup оставил runtime WARP rule' >&2
    exit 1
fi
printf 'Example.com\n' > "$T/users/custom.txt"
printf '1.2.3.4\n' > "$T/users/ips.txt"
printf 'game.example\n' > "$T/games/game.txt"
printf 'game\n' > "$T/users/.enabled"
: > "$T/users/devices.txt"

mkdir -p "$T/migrate-users" "$T/migrate-games"
printf '8.8.8.8\n' > "$T/migrate-users/custom.txt"
chmod 600 "$T/migrate-users/custom.txt"
for legacy in game-warp-ips.txt .game-warp-ips.base \
    .game-warp-ips.upstream .game-warp-ips.removed .game-warp-ips.san; do
    printf 'legacy\n' > "$T/migrate-users/$legacy"
done
Z2K_WARP_LOCK_DIR="$T/migrate.lock" "$BIN" list-migrate \
    "$T/migrate-users" "$T/migrate-games"
[ -f "$T/migrate-users/.legacy-aggregate-purged" ]
[ ! -e "$T/migrate-users/game-warp-ips.txt" ]
[ ! -e "$T/migrate-users/.game-warp-ips.base" ]
[ ! -e "$T/migrate-users/.game-warp-ips.upstream" ]
[ ! -e "$T/migrate-users/.game-warp-ips.removed" ]
[ ! -e "$T/migrate-users/.game-warp-ips.san" ]
[ ! -e "$T/migrate.lock" ]
printf 'пользователь\n' > "$T/migrate-users/game-warp-ips.txt"
Z2K_WARP_LOCK_DIR="$T/migrate.lock" "$BIN" list-migrate \
    "$T/migrate-users" "$T/migrate-games"
grep -qx 'пользователь' "$T/migrate-users/game-warp-ips.txt"

"$BIN" domains-sync "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/domains.v1" "$T/domains.error"
printf 'v1\nexample.com\ngame.example\n' > "$T/expected"
cmp "$T/expected" "$T/domains.v1"
printf 'Example.com\n' > "$T/users/custom.txt"
mode="$(ls -ld "$T/domains.v1" | awk '{print $1}')"
[ "$mode" = '-rw-------' ]
before_inode="$(ls -id "$T/domains.v1" | awk '{print $1}')"
"$BIN" domains-sync "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/domains.v1" "$T/domains.error"
[ "$before_inode" = "$(ls -id "$T/domains.v1" | awk '{print $1}')" ]

printf '\377' > "$T/users/custom.txt"
if "$BIN" domains-sync "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/domains.v1" "$T/domains.error"; then
    echo 'ошибка чтения списка доменов принята за пустой список' >&2
    exit 1
fi
cmp "$T/expected" "$T/domains.v1"

printf 'Example.com\n' > "$T/users/custom.txt"

mkdir -p "$T/kill-users"
printf 'v1\nlast-good.example\n' > "$T/kill-rules"
cp "$T/kill-rules" "$T/kill-rules.before"
echo 'SIGKILL: начинаю обработку большого списка'
awk 'BEGIN { for (i = 0; i < 500000; i++) print "slow.example" }' \
    > "$T/kill-users/slow.txt"
Z2K_WARP_LOCK_DIR="$T/mutate.lock" "$BIN" domains-sync \
    "$T/kill-users" "$T/games" "$T/kill-users/.enabled" \
    "$T/kill-rules" "$T/kill-error" &
worker=$!
attempt=0
while [ ! -f "$T/mutate.lock/pid" ] && [ "$attempt" -lt 1000000 ]; do
    if ! kill -0 "$worker" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
done
if [ ! -f "$T/mutate.lock/pid" ]; then
    echo 'controller не успел создать lock для SIGKILL-сценария' >&2
    exit 1
fi
echo 'SIGKILL: lock создан; завершаю процесс'
kill -9 "$worker"
wait "$worker" 2>/dev/null || true
[ -d "$T/mutate.lock" ]
cmp "$T/kill-rules.before" "$T/kill-rules"
printf 'slow.example\n' > "$T/kill-users/slow.txt"
echo 'SIGKILL: last-good сохранён; проверяю восстановление lock'
Z2K_WARP_LOCK_DIR="$T/mutate.lock" "$BIN" domains-sync \
    "$T/kill-users" "$T/games" "$T/kill-users/.enabled" \
    "$T/kill-rules" "$T/kill-error"
[ ! -e "$T/mutate.lock" ]
grep -F 'slow.example' "$T/kill-rules"
echo 'SIGKILL: восстановление прошло'

nft add table "$TABLE" "$WARP_TABLE"
"$BIN" nft-sync "$T/users" "$T/games" "$T/users/.enabled" \
    "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
_sets_ready=$("$BIN" nft-sets-verify "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src)
[ "$_sets_ready" = ready=1 ]
mkdir -p "$T/neighbor-users" "$T/neighbor-games"
printf '1.2.3.4\n' > "$T/neighbor-users/custom.txt"
printf '%s\n' "$_neighbor_mac" > "$T/neighbor-users/devices.txt"
"$BIN" nft-sync "$T/neighbor-users" "$T/neighbor-games" \
    "$T/neighbor-users/.enabled" "$T/neighbor-users/devices.txt" \
    "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
nft list set "$TABLE" "$WARP_TABLE" z2k_src | grep -F "$_neighbor_ip"
"$BIN" nft-sync "$T/users" "$T/games" "$T/users/.enabled" \
    "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
nft delete element "$TABLE" "$WARP_TABLE" z2k_dst '{ 1.2.3.4 }'
_sets_ready=$("$BIN" nft-sets-verify "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src)
[ "$_sets_ready" = ready=0 ]
"$BIN" nft-sync "$T/users" "$T/games" "$T/users/.enabled" \
    "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
_sets_ready=$("$BIN" nft-sets-verify "$T/users" "$T/games" \
    "$T/users/.enabled" "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src)
[ "$_sets_ready" = ready=1 ]
mkdir -p "$T/domain-only-users" "$T/domain-only-games"
printf 'only.example\n' > "$T/domain-only-users/custom.txt"
: > "$T/domain-only-users/devices.txt"
"$BIN" nft-sync "$T/domain-only-users" "$T/domain-only-games" \
    "$T/domain-only-users/.enabled" "$T/domain-only-users/devices.txt" \
    "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
! nft list set "$TABLE" "$WARP_TABLE" z2k_dst | grep -F '1.2.3.4'
_sets_ready=$("$BIN" nft-sets-verify "$T/domain-only-users" \
    "$T/domain-only-games" "$T/domain-only-users/.enabled" \
    "$T/domain-only-users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src)
[ "$_sets_ready" = ready=1 ]
"$BIN" nft-sync "$T/users" "$T/games" "$T/users/.enabled" \
    "$T/users/devices.txt" "$TABLE" "$WARP_TABLE" z2k_dst z2k_src
"$BIN" nft-domain-set-ensure "$TABLE" "$WARP_TABLE" z2k_domain
nft add element "$TABLE" "$WARP_TABLE" z2k_domain \
    '{ 192.0.2.9 . 203.0.113.9 timeout 10m }'
mark_apply "$T/users" "$T/games" "$_mark_config" '' '' ''
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark \
    | grep -F 'ip saddr . ip daddr @z2k_domain meta mark set'
_mark_ready=$(mark_verify "$T/users" "$T/games" "$_mark_config" '' '' '')
[ "$_mark_ready" = ready=1 ]
nft -a list chain "$TABLE" "$WARP_TABLE" z2k_mark > "$T/mark.before"
mark_apply "$T/users" "$T/games" "$_mark_config" '' '' ''
nft -a list chain "$TABLE" "$WARP_TABLE" z2k_mark > "$T/mark.after"
cmp "$T/mark.before" "$T/mark.after"
nft add rule "$TABLE" "$WARP_TABLE" z2k_mark counter
_mark_ready=$(mark_verify "$T/users" "$T/games" "$_mark_config" '' '' '')
[ "$_mark_ready" = ready=0 ]
mark_apply "$T/users" "$T/games" "$_mark_config" '' '' ''
_mark_ready=$(mark_verify "$T/users" "$T/games" "$_mark_config" '' '' '')
[ "$_mark_ready" = ready=1 ]

mkdir -p "$T/all-users"
_all_config="$T/all-config"
printf 'Z2K_WARP_WDTT=1\n' > "$_all_config"
mark_apply "$T/all-users" "$T/games" "$_all_config" 'br-lan,wlan0' wgserver0 ''
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'ip daddr 192.168.0.0/16 return'
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'iifname "br-lan" meta mark set'
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'iifname "wlan0" meta mark set'

printf '192.168.1.9\n' > "$T/users/devices.txt"
mark_apply "$T/users" "$T/games" "$_all_config" '' wgserver0 wgclient0
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'ip saddr @z2k_src ip daddr @z2k_dst meta mark set'
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'iifname "wgclient0" ip saddr 192.168.0.0/16 ip daddr @z2k_dst'

mkdir -p "$T/full-users"
printf '192.168.1.9\n' > "$T/full-users/devices.txt"
mark_apply "$T/full-users" "$T/games" "$_mark_config" '' wgserver0 ''
nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -F 'ip daddr != 192.168.0.0/16'

"$BIN" nft-tun-apply "$TABLE" "$WARP_TABLE" \
    z2k_mss z2k_fwd z2k_nat z2ktun0
nft add chain "$TABLE" "$WARP_TABLE" z2k_foreign
nft add rule "$TABLE" "$WARP_TABLE" z2k_foreign counter
"$BIN" nft-chain-clear "$TABLE" "$WARP_TABLE" \
    z2k_mark z2k_mss z2k_fwd z2k_nat
! nft list chain "$TABLE" "$WARP_TABLE" z2k_mark | grep -q 'meta mark set'
! nft list chain "$TABLE" "$WARP_TABLE" z2k_fwd | grep -q 'oifname'
nft list chain "$TABLE" "$WARP_TABLE" z2k_foreign | grep -F 'counter'
for chain in z2k_mark z2k_mss z2k_fwd z2k_nat z2k_foreign; do
    nft -a list chain "$TABLE" "$WARP_TABLE" "$chain"
done > "$T/clear.before"
"$BIN" nft-chain-clear "$TABLE" "$WARP_TABLE" \
    z2k_mark z2k_mss z2k_fwd z2k_nat
for chain in z2k_mark z2k_mss z2k_fwd z2k_nat z2k_foreign; do
    nft -a list chain "$TABLE" "$WARP_TABLE" "$chain"
done > "$T/clear.after"
cmp "$T/clear.before" "$T/clear.after"
"$BIN" nft-warp-remove "$TABLE" "$WARP_TABLE" 0 \
    z2k_mark z2k_mss z2k_fwd z2k_nat z2k_dst z2k_src
if nft list chain "$TABLE" "$WARP_TABLE" z2k_mark >/dev/null 2>&1; then
    echo 'QEMU обычная очистка оставила MARK-цепочку WARP' >&2
    exit 1
fi
nft list set "$TABLE" "$WARP_TABLE" z2k_dst >/dev/null
nft list chain "$TABLE" "$WARP_TABLE" z2k_foreign | grep -F 'counter'
mkdir -p "$T/no-nft"
if PATH="$T/no-nft" "$BIN" nft-chain-clear "$TABLE" "$WARP_TABLE" \
    z2k_mark >/dev/null 2>&1; then
    echo 'ошибка чтения nft скрыта при очистке цепочек' >&2
    exit 1
fi

chmod 000 "$NFT_BIN"
if "$BIN" nft-domain-observer-apply "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189 lo; then
    echo 'observer успешно прочитал nft при недоступном бинарнике' >&2
    exit 1
fi
chmod 755 "$NFT_BIN"

"$BIN" nft-domain-observer-apply "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189 lo
_domain_ready=$("$BIN" nft-domain-verify "$TABLE" "$WARP_TABLE" \
    z2k_domain "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189)
[ "$_domain_ready" = ready=1 ]
before="$(nft -a list table "$TABLE" "$DNS_TABLE")"
"$BIN" nft-domain-observer-apply "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189 lo
after="$(nft -a list table "$TABLE" "$DNS_TABLE")"
[ "$before" = "$after" ]
nft list table "$TABLE" "$DNS_TABLE" \
    | grep -F 'comment "z2k WARP passive DNS observer"'
nft list chain "$TABLE" "$DNS_TABLE" z2k_dns_output \
    | grep -F 'log group 189'
nft -a list table "$TABLE" "$DNS_TABLE" > "$T/nft.before"
"$BIN" nft-domain-observer-apply "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189 lo
nft -a list table "$TABLE" "$DNS_TABLE" > "$T/nft.after"
cmp "$T/nft.before" "$T/nft.after"

"$BIN" nft-domain-remove "$TABLE" "$DNS_TABLE" "$TABLE" \
    "$WARP_TABLE" z2k_domain 0
_domain_ready=$("$BIN" nft-domain-verify "$TABLE" "$WARP_TABLE" \
    z2k_domain "$TABLE" "$DNS_TABLE" \
    z2k_dns_output z2k_dns_forward 189)
[ "$_domain_ready" = ready=0 ]
if nft list table "$TABLE" "$DNS_TABLE" >/dev/null 2>&1; then
    echo 'observer table сохранилась после удаления' >&2
    exit 1
fi
nft list set "$TABLE" "$WARP_TABLE" z2k_domain \
    | grep -F 'comment "z2k WARP DNS pairs"'
"$BIN" nft-domain-remove "$TABLE" "$DNS_TABLE" "$TABLE" \
    "$WARP_TABLE" z2k_domain 1
if nft list set "$TABLE" "$WARP_TABLE" z2k_domain >/dev/null 2>&1; then
    echo 'доменный набор сохранился после полного удаления' >&2
    exit 1
fi
nft list set "$TABLE" "$WARP_TABLE" z2k_dst >/dev/null
"$BIN" nft-warp-remove "$TABLE" "$WARP_TABLE" 1 \
    z2k_mark z2k_mss z2k_fwd z2k_nat z2k_dst z2k_src
if nft list set "$TABLE" "$WARP_TABLE" z2k_dst >/dev/null 2>&1; then
    echo 'QEMU полная очистка оставила набор WARP' >&2
    exit 1
fi
nft list chain "$TABLE" "$WARP_TABLE" z2k_foreign | grep -F 'counter'

printf 'SUITE[ow-warp-controller-openwrt-qemu]: pass\n'
